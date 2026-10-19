import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/pinned_connection.dart';
import '../../../core/network/server_pin_controller.dart';
import '../../../core/network/server_pin_providers.dart';
import '../../../core/network/server_pin_store.dart';
import '../../../core/workspace/workspace_context.dart';
import 'server_key_changed_screen.dart';
import 'server_trust_dialog.dart';

/// Whether the person may go on connecting to a server address.
enum ServerTrustResult {
  /// The server is trusted: pinned and matching, or CA-valid and unpinned.
  proceed,

  /// The person declined, or left the key-changed screen without trusting.
  cancelled,

  /// The TLS handshake did not complete.
  unreachable,

  /// A pin exists but cannot be read, so connecting would drop it.
  unreadable,
}

/// The first-connect check that runs before anything is sent to [url].
///
/// A credential-free handshake reads the server's leaf key. A server that
/// passes ordinary certificate checking and has no pin needs no question; one
/// that does not (typically a self-signed home server) is shown to the person
/// with its fingerprint, and only an explicit "trust" stores the pin. A pinned
/// server that now presents another key goes to the key-changed screen.
Future<ServerTrustResult> ensureServerTrusted(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  final authority = ServerAuthority.parse(canonicalServerEndpoint(url));
  final store = ref.read(serverPinStoreProvider);
  final ServerPin? pin;
  try {
    pin = await store.read(authority);
  } on ServerPinUnreadable {
    return ServerTrustResult.unreadable;
  }
  final ServerCertificateProbe probe;
  try {
    probe = await ref.read(serverCertificateProbeProvider)(authority);
  } on Object {
    return ServerTrustResult.unreachable;
  }
  if (!context.mounted) return ServerTrustResult.cancelled;

  if (pin != null) {
    if (pin.fingerprint == probe.fingerprint) {
      if (pin.mismatch != null) await store.clearMismatch(authority);
      return ServerTrustResult.proceed;
    }
    final outcome = await Navigator.of(context).push<ServerKeyOutcome>(
      MaterialPageRoute(
        builder: (_) => ServerKeyChangedScreen(authority: authority),
      ),
    );
    return outcome == ServerKeyOutcome.trustedNewKey ||
            outcome == ServerKeyOutcome.normalChecking
        ? ServerTrustResult.proceed
        : ServerTrustResult.cancelled;
  }

  if (probe.chainValid) return ServerTrustResult.proceed;

  final trusted = await showServerTrustDialog(
    context,
    host: authority.host,
    fingerprint: probe.fingerprint,
  );
  if (!trusted) return ServerTrustResult.cancelled;
  await ref
      .read(serverPinControllerProvider.notifier)
      .trust(authority, probe.fingerprint);
  return ServerTrustResult.proceed;
}
