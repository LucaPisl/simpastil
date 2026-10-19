import 'dart:convert';

import '../auth/protected_credentials_repository.dart'
    show CredentialSlotStore, SecureCredentialSlotStore;
import 'spki_fingerprint.dart';

/// The identity a pin is keyed by: lower-cased host and explicit port
/// (443 when the address has none).
class ServerAuthority {
  const ServerAuthority(this.host, this.port);

  factory ServerAuthority.fromUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) throw ArgumentError('Address has no host');
    final port = uri.hasPort && uri.port != 0 ? uri.port : 443;
    return ServerAuthority(host, port);
  }

  factory ServerAuthority.parse(String endpoint) =>
      ServerAuthority.fromUri(Uri.parse(endpoint));

  final String host;
  final int port;

  /// `host:port`, with an IPv6 host in brackets.
  String get key => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is ServerAuthority && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => key;
}

/// A different key was seen on a pinned server.
class PinMismatchRecord {
  const PinMismatchRecord({required this.presented, required this.at});

  /// The fingerprint that was presented, or null when none could be read.
  final String? presented;
  final DateTime at;
}

/// What the device remembers about one pinned server.
class ServerPin {
  const ServerPin({
    required this.fingerprint,
    required this.pinnedAt,
    this.mismatch,
  });

  final String fingerprint;
  final DateTime pinnedAt;

  /// The most recent unresolved mismatch, written by whichever isolate saw it
  /// (foreground or background sync). Cleared only when the person resolves it.
  final PinMismatchRecord? mismatch;
}

/// The stored pin cannot be read. Treated as "do not connect": falling back to
/// ordinary checking would silently drop the pin.
class ServerPinUnreadable implements Exception {
  const ServerPinUnreadable();
  @override
  String toString() => 'ServerPinUnreadable';
}

/// Persistent pins, one per [ServerAuthority].
abstract interface class ServerPinStore {
  /// The pin for [authority], null when it is not pinned. Throws
  /// [ServerPinUnreadable] when a record exists but cannot be trusted.
  Future<ServerPin?> read(ServerAuthority authority);

  /// Pins [fingerprint], replacing any earlier pin and clearing its mismatch.
  Future<void> save(ServerAuthority authority, String fingerprint);

  /// Notes that [presented] was seen instead of the pinned key. A no-op when
  /// the server is not pinned.
  Future<void> recordMismatch(ServerAuthority authority, String? presented);

  /// Forgets a recorded mismatch and keeps the pin.
  Future<void> clearMismatch(ServerAuthority authority);

  /// Removes the pin: the server returns to ordinary certificate checking.
  Future<void> remove(ServerAuthority authority);
}

/// Pins in the same Android Keystore-backed secure storage as sign-in tokens.
/// It needs no database or Riverpod, so WorkManager and notification isolates
/// read it exactly like they read their credentials.
class SecureServerPinStore implements ServerPinStore {
  const SecureServerPinStore([this._slots = const SecureCredentialSlotStore()]);

  final CredentialSlotStore _slots;

  static const keyPrefix = 'simpastil_server_pin_v1.';
  static String keyFor(ServerAuthority authority) =>
      '$keyPrefix${authority.key}';

  @override
  Future<ServerPin?> read(ServerAuthority authority) async {
    final String? raw;
    try {
      raw = await _slots.read(keyFor(authority));
    } on Object {
      throw const ServerPinUnreadable();
    }
    if (raw == null) return null;
    return _decode(raw);
  }

  @override
  Future<void> save(ServerAuthority authority, String fingerprint) async {
    if (!isWellFormedFingerprint(fingerprint)) {
      throw ArgumentError('Malformed fingerprint');
    }
    await _write(
      authority,
      ServerPin(fingerprint: fingerprint, pinnedAt: DateTime.now().toUtc()),
    );
  }

  @override
  Future<void> recordMismatch(
    ServerAuthority authority,
    String? presented,
  ) async {
    final pin = await read(authority);
    if (pin == null) return;
    await _write(
      authority,
      ServerPin(
        fingerprint: pin.fingerprint,
        pinnedAt: pin.pinnedAt,
        mismatch: PinMismatchRecord(
          presented: presented != null && isWellFormedFingerprint(presented)
              ? presented
              : null,
          at: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  @override
  Future<void> clearMismatch(ServerAuthority authority) async {
    final pin = await read(authority);
    if (pin == null || pin.mismatch == null) return;
    await _write(
      authority,
      ServerPin(fingerprint: pin.fingerprint, pinnedAt: pin.pinnedAt),
    );
  }

  @override
  Future<void> remove(ServerAuthority authority) =>
      _slots.delete(keyFor(authority));

  Future<void> _write(ServerAuthority authority, ServerPin pin) {
    final mismatch = pin.mismatch;
    return _slots.write(
      keyFor(authority),
      jsonEncode({
        'version': 1,
        'fingerprint': pin.fingerprint,
        'pinnedAt': pin.pinnedAt.toUtc().toIso8601String(),
        if (mismatch != null)
          'mismatch': {
            'presented': mismatch.presented,
            'at': mismatch.at.toUtc().toIso8601String(),
          },
      }),
    );
  }

  static ServerPin _decode(String raw) {
    try {
      if (raw.length > 2048) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value['version'] != 1) {
        throw const FormatException();
      }
      final fingerprint = value['fingerprint'];
      final pinnedAt = value['pinnedAt'];
      if (fingerprint is! String ||
          !isWellFormedFingerprint(fingerprint) ||
          pinnedAt is! String) {
        throw const FormatException();
      }
      PinMismatchRecord? mismatch;
      final rawMismatch = value['mismatch'];
      if (rawMismatch != null) {
        if (rawMismatch is! Map<String, dynamic>) throw const FormatException();
        final presented = rawMismatch['presented'];
        final at = rawMismatch['at'];
        if ((presented != null &&
                (presented is! String ||
                    !isWellFormedFingerprint(presented))) ||
            at is! String) {
          throw const FormatException();
        }
        mismatch = PinMismatchRecord(
          presented: presented as String?,
          at: DateTime.parse(at),
        );
      }
      return ServerPin(
        fingerprint: fingerprint,
        pinnedAt: DateTime.parse(pinnedAt),
        mismatch: mismatch,
      );
    } on FormatException {
      throw const ServerPinUnreadable();
    }
  }
}

/// The store every client built without an explicit one uses. Tests swap it.
ServerPinStore defaultServerPinStore = const SecureServerPinStore();
