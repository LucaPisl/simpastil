import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server/server_config_notifier.dart';
import 'pinned_connection.dart';
import 'server_pin_providers.dart';
import 'server_pin_store.dart';

/// What the device knows about the pin of the configured server.
class ServerPinState {
  const ServerPinState({this.authority, this.pin, this.unreadable = false});

  /// The configured server, null before one is chosen.
  final ServerAuthority? authority;

  /// The stored pin, null when the server uses ordinary checking.
  final ServerPin? pin;

  /// A pin exists but cannot be read, so the server stays blocked.
  final bool unreadable;

  bool get isPinned => pin != null || unreadable;

  /// A connection (foreground or background) met a different key and the
  /// problem has not been resolved yet.
  bool get hasMismatch => pin?.mismatch != null;
}

/// Pin state of the configured server, plus the only operations that change
/// a pin. A pin is never changed implicitly: each method is called from an
/// explicit, confirmed action on screen.
class ServerPinController extends AsyncNotifier<ServerPinState> {
  @override
  Future<ServerPinState> build() async {
    final url = ref.watch(serverConfigProvider);
    final subscription = ServerPinEvents.mismatches.listen((mismatch) {
      final current = state.value?.authority;
      if (current == null || current == mismatch.authority) {
        ref.invalidateSelf();
      }
    });
    ref.onDispose(subscription.cancel);
    if (url == null) return const ServerPinState();
    final ServerAuthority authority;
    try {
      authority = ServerAuthority.parse(url);
    } on ArgumentError {
      return const ServerPinState();
    }
    try {
      final pin = await ref.read(serverPinStoreProvider).read(authority);
      return ServerPinState(authority: authority, pin: pin);
    } on ServerPinUnreadable {
      return ServerPinState(authority: authority, unreadable: true);
    }
  }

  /// Pins [fingerprint] for [authority]. Open connections are dropped so the
  /// new pin applies to the next request.
  Future<void> trust(ServerAuthority authority, String fingerprint) async {
    await ref.read(serverPinStoreProvider).save(authority, fingerprint);
    PinningConnector.closeConnectionsTo(authority);
    ref.invalidateSelf();
  }

  /// Removes the pin: the server goes back to ordinary certificate checking.
  Future<void> useNormalChecking(ServerAuthority authority) async {
    await ref.read(serverPinStoreProvider).remove(authority);
    PinningConnector.closeConnectionsTo(authority);
    ref.invalidateSelf();
  }

  /// Forgets a recorded mismatch and keeps the pin.
  Future<void> dismissMismatch(ServerAuthority authority) async {
    await ref.read(serverPinStoreProvider).clearMismatch(authority);
    ref.invalidateSelf();
  }

  /// Re-reads the pin, for example after a background sync may have recorded
  /// a mismatch while the app was away.
  void refresh() => ref.invalidateSelf();
}

final serverPinControllerProvider =
    AsyncNotifierProvider<ServerPinController, ServerPinState>(
      ServerPinController.new,
    );
