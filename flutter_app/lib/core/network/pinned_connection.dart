import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'server_pin_store.dart';
import 'spki_fingerprint.dart';

/// A pinned server presented a different key. Nothing was sent to it: the
/// connection is destroyed before the HTTP client sees the socket.
class CertificatePinMismatch implements Exception {
  const CertificatePinMismatch({
    required this.host,
    required this.port,
    required this.pinned,
    required this.presented,
  });

  final String host;
  final int port;

  /// The fingerprint the device pinned.
  final String pinned;

  /// The fingerprint the server presented, null when it presented no readable
  /// certificate.
  final String? presented;

  ServerAuthority get authority => ServerAuthority(host, port);

  @override
  String toString() => 'CertificatePinMismatch($host:$port)';
}

/// Finds a [CertificatePinMismatch] behind [error], which is usually a
/// `DioException` whose `error` carries it.
CertificatePinMismatch? pinMismatchOf(Object? error) {
  if (error is CertificatePinMismatch) return error;
  if (error == null) return null;
  try {
    // DioException.error; read dynamically so this file stays free of Dio.
    final inner = (error as dynamic).error;
    if (inner is CertificatePinMismatch) return inner;
  } on Object {
    // Not an exception that wraps another one.
  }
  return null;
}

/// True when [error] is a TLS handshake that failed because the server's
/// certificate does not validate (self-signed, unknown authority, wrong name,
/// expired). [error] is usually a `DioException` wrapping the handshake error.
bool isCertificateRejection(Object? error) {
  if (error == null) return false;
  Object? inner = error;
  try {
    // DioException.error; read dynamically so this file stays free of Dio.
    final wrapped = (error as dynamic).error;
    if (wrapped != null) inner = wrapped;
  } on Object {
    // Not an exception that wraps another one.
  }
  return inner is HandshakeException &&
      inner.toString().contains('CERTIFICATE_VERIFY_FAILED');
}

/// In-process notification that a connection hit a pin mismatch, or that an
/// unpinned server presented a certificate that does not validate. The
/// foreground app listens; background isolates have no listener and rely on
/// the mismatch record written to the [ServerPinStore].
class ServerPinEvents {
  ServerPinEvents._();
  static final StreamController<CertificatePinMismatch> _controller =
      StreamController<CertificatePinMismatch>.broadcast();
  static Stream<CertificatePinMismatch> get mismatches => _controller.stream;
  static void _emit(CertificatePinMismatch mismatch) {
    if (_controller.hasListener) _controller.add(mismatch);
  }

  static final StreamController<ServerAuthority> _rejections =
      StreamController<ServerAuthority>.broadcast();
  static final Set<String> _rejected = {};

  /// An unpinned server presented a certificate that does not validate.
  static Stream<ServerAuthority> get rejections => _rejections.stream;

  /// Whether the last unpinned connection to [authority] in this isolate was
  /// refused for its certificate. A later successful connection clears it.
  static bool isRejected(ServerAuthority authority) =>
      _rejected.contains(authority.key);

  static void _noteRejected(ServerAuthority authority) {
    _rejected.add(authority.key);
    if (_rejections.hasListener) _rejections.add(authority);
  }

  static void _noteAccepted(ServerAuthority authority) {
    if (_rejected.remove(authority.key) && _rejections.hasListener) {
      _rejections.add(authority);
    }
  }

  /// Forgets a rejection once the person has decided what to do about it.
  static void forgetRejection(ServerAuthority authority) =>
      _rejected.remove(authority.key);

  /// Records a rejection without a handshake; tests only.
  @visibleForTesting
  static void noteRejectedForTest(ServerAuthority authority) =>
      _noteRejected(authority);

  /// Forgets every rejection; tests only.
  @visibleForTesting
  static void resetRejections() => _rejected.clear();
}

typedef ServerConnectionFactory =
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?);

/// Opens every connection an `HttpClient` makes to the user's Simpastil
/// server, installed as its `connectionFactory`.
///
/// The pin is checked here, on the TLS socket, before the HTTP client ever
/// sees it, so no request byte, header or credential reaches a server that
/// presents the wrong key.
///
/// * Pinned host: the handshake runs with no trusted roots and accepts any
///   certificate, then the **leaf** (`peerCertificate`, the certificate whose
///   key signed the handshake) is compared with the pin. `badCertificateCallback`
///   is deliberately not used: it receives the certificate at the depth where
///   chain verification failed, which is not the leaf, so a server could send
///   its own leaf followed by the victim's public certificate.
/// * Any other host: an ordinary strict TLS connection against the default
///   trust store, exactly what `HttpClient` does itself.
class PinningConnector {
  PinningConnector({ServerPinStore? pins, SecurityContext? unpinnedContext})
    : _pins = pins,
      _unpinnedContext = unpinnedContext;

  final ServerPinStore? _pins;
  final SecurityContext? _unpinnedContext;

  ServerPinStore get _store => _pins ?? defaultServerPinStore;

  static final Map<String, Set<Socket>> _open = {};

  /// Destroys this isolate's open connections to [authority], so a changed or
  /// removed pin applies to the next request instead of to a reused socket.
  static void closeConnectionsTo(ServerAuthority authority) {
    final sockets = _open.remove(authority.key);
    if (sockets == null) return;
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
  }

  /// The `HttpClient.connectionFactory` signature.
  ServerConnectionFactory get connect => _connect;

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null || proxyPort != null) {
      throw StateError('Server connections never use a proxy');
    }
    if (!uri.isScheme('https')) {
      throw const SocketException('The server connection requires TLS');
    }
    final authority = ServerAuthority.fromUri(uri);
    final pin = await _store.read(authority);
    if (pin == null) {
      final task = await SecureSocket.startConnect(
        authority.host,
        authority.port,
        context: _unpinnedContext,
      );
      // Ordinary strict TLS is unchanged; the outcome is only noted so the
      // app can offer to review the key when the certificate does not validate.
      final noted = task.socket.then<Socket>(
        (socket) {
          ServerPinEvents._noteAccepted(authority);
          return socket;
        },
        onError: (Object error, StackTrace stack) {
          if (isCertificateRejection(error)) {
            ServerPinEvents._noteRejected(authority);
          }
          Error.throwWithStackTrace(error, stack);
        },
      );
      return ConnectionTask.fromSocket<Socket>(noted, task.cancel);
    }
    return _connectPinned(authority, pin.fingerprint);
  }

  Future<ConnectionTask<Socket>> _connectPinned(
    ServerAuthority authority,
    String pinned,
  ) async {
    final task = await SecureSocket.startConnect(
      authority.host,
      authority.port,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (_) => true,
    );
    var cancelled = false;
    final verified = task.socket.then<Socket>((socket) async {
      if (cancelled) {
        socket.destroy();
        throw const SocketException('Connection cancelled');
      }
      String? presented;
      try {
        final leaf = socket.peerCertificate;
        if (leaf != null) presented = spkiFingerprintOfCertificate(leaf.der);
      } on Object {
        presented = null;
      }
      if (presented == null || presented != pinned) {
        socket.destroy();
        final mismatch = CertificatePinMismatch(
          host: authority.host,
          port: authority.port,
          pinned: pinned,
          presented: presented,
        );
        await _noteMismatch(authority, mismatch);
        throw mismatch;
      }
      final sockets = _open.putIfAbsent(authority.key, () => <Socket>{});
      sockets.add(socket);
      unawaited(
        socket.done.then<void>((_) {}, onError: (_) {}).whenComplete(() {
          sockets.remove(socket);
        }),
      );
      return socket;
    });
    return ConnectionTask.fromSocket<Socket>(verified, () {
      cancelled = true;
      task.cancel();
    });
  }

  /// Records the mismatch durably (a background isolate may end right after
  /// the failure) and tells a listening foreground. Never throws.
  Future<void> _noteMismatch(
    ServerAuthority authority,
    CertificatePinMismatch mismatch,
  ) async {
    ServerPinEvents._emit(mismatch);
    try {
      await _store
          .recordMismatch(authority, mismatch.presented)
          .timeout(const Duration(seconds: 3));
    } on Object {
      // The connection stays refused; only the reminder for the UI is lost.
    }
  }
}

/// What a TLS handshake alone reveals about a server.
class ServerCertificateProbe {
  const ServerCertificateProbe({
    required this.fingerprint,
    required this.chainValid,
  });

  /// Fingerprint of the leaf certificate's public key.
  final String fingerprint;

  /// True when the chain verified against the default trust store and matched
  /// the host name, i.e. the server would pass ordinary checking.
  final bool chainValid;
}

/// Connects to [authority], completes the TLS handshake and closes the socket.
/// No HTTP byte, header or credential is sent.
///
/// [context] replaces the default trust store; only tests pass one.
Future<ServerCertificateProbe> probeServerCertificate(
  ServerAuthority authority, {
  Duration timeout = const Duration(seconds: 10),
  SecurityContext? context,
}) async {
  var chainValid = true;
  final socket = await SecureSocket.connect(
    authority.host,
    authority.port,
    context: context,
    timeout: timeout,
    onBadCertificate: (_) {
      chainValid = false;
      return true;
    },
  );
  try {
    final leaf = socket.peerCertificate;
    if (leaf == null) {
      throw const HandshakeException('The server presented no certificate');
    }
    return ServerCertificateProbe(
      fingerprint: spkiFingerprintOfCertificate(leaf.der),
      chainValid: chainValid,
    );
  } finally {
    socket.destroy();
  }
}
