import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simpastil/core/auth/protected_credentials_repository.dart';

/// The TLS fixtures in `test/fixtures/tls` (throwaway, test-only keys).
String tlsFixture(String name) => 'test/fixtures/tls/$name';

/// DER bytes of the first certificate in a PEM fixture.
Uint8List certificateDerOf(String fixtureName) {
  final pem = File(tlsFixture(fixtureName)).readAsStringSync();
  final body = pem
      .split('-----BEGIN CERTIFICATE-----')[1]
      .split('-----END CERTIFICATE-----')[0]
      .replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(base64.decode(body));
}

/// A trust store holding only the fixture CA.
SecurityContext fixtureCaContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(tlsFixture('ca.pem'));

/// A real TLS server that records what the client sends.
///
/// It answers a complete HTTP request with `200 {"ok":true}` and keeps the
/// connection open, so the tests can tell a connection that was refused
/// before any request byte (zero bytes) from one that served a request.
class TlsTestServer {
  TlsTestServer._(this._server);

  /// Binds on loopback with [chainFiles] (leaf first) and [keyFile].
  static Future<TlsTestServer> start({
    required List<String> chainFiles,
    required String keyFile,
  }) async {
    final context = SecurityContext(withTrustedRoots: false);
    final chain = File(
      '${Directory.systemTemp.createTempSync('tls-chain').path}/chain.pem',
    );
    chain.writeAsStringSync(
      chainFiles.map((f) => File(tlsFixture(f)).readAsStringSync()).join('\n'),
    );
    context
      ..useCertificateChain(chain.path)
      ..usePrivateKey(tlsFixture(keyFile));
    chain.parent.deleteSync(recursive: true);
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final instance = TlsTestServer._(server);
    server.listen(
      instance._onConnection,
      onError: (Object _) {},
      cancelOnError: false,
    );
    return instance;
  }

  final SecureServerSocket _server;
  final List<SecureSocket> _sockets = [];

  /// Completed TLS handshakes.
  int connections = 0;

  /// Application bytes received over all connections.
  int bytesReceived = 0;

  /// Complete HTTP requests answered.
  int requests = 0;

  /// `Authorization`-style header values seen, to prove credentials never leak.
  final List<String> headersSeen = [];

  int get port => _server.port;
  String get baseUrl => 'https://127.0.0.1:$port';

  void _onConnection(SecureSocket socket) {
    connections++;
    _sockets.add(socket);
    final buffer = StringBuffer();
    socket.listen(
      (Uint8List data) {
        bytesReceived += data.length;
        buffer.write(latin1.decode(data));
        final text = buffer.toString();
        if (text.contains('\r\n\r\n')) {
          requests++;
          headersSeen.add(text);
          buffer.clear();
          const body = '{"ok":true}';
          socket.add(
            latin1.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: ${body.length}\r\n\r\n$body',
            ),
          );
        }
      },
      onError: (Object _) {},
      onDone: () => socket.destroy(),
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// In-memory stand-in for the Android secure storage.
class MemorySlots implements CredentialSlotStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
