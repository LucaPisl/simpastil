import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/network/http_clients.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/core/network/spki_fingerprint.dart';

import '../../helpers/tls_test_server.dart';

String _fp(String fixture) =>
    spkiFingerprintOfCertificate(certificateDerOf(fixture));

Dio _client(
  TlsTestServer server,
  ServerPinStore pins, {
  SecurityContext? trust,
}) => createServerDio(
  options: BaseOptions(
    baseUrl: server.baseUrl,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    validateStatus: (_) => true,
  ),
  pins: pins,
  unpinnedContext: trust,
);

Future<Response<dynamic>> _login(Dio dio) => dio.post<dynamic>(
  '/api/v1/auth/login',
  data: {'email': 'someone@example.test', 'password': 'a-secret-password'},
  options: Options(headers: {'X-Api-Key': 'secret-installation-key'}),
);

Future<Object> _failure(Future<Object?> request) async {
  try {
    await request;
  } on Object catch (error) {
    return error;
  }
  fail('the request was expected to fail');
}

void main() {
  late SecureServerPinStore pins;
  late ServerAuthority authority;
  final servers = <TlsTestServer>[];

  setUp(() {
    pins = SecureServerPinStore(MemorySlots());
    ServerPinEvents.resetRejections();
  });

  tearDown(() async {
    for (final server in servers) {
      await server.close();
    }
    servers.clear();
  });

  Future<TlsTestServer> serve(String cert, {List<String>? chain}) async {
    final server = await TlsTestServer.start(
      chainFiles: chain ?? [cert],
      keyFile: cert.replaceFirst('.pem', '.key.pem'),
    );
    servers.add(server);
    authority = ServerAuthority('127.0.0.1', server.port);
    return server;
  }

  group('pinned host', () {
    test('a matching leaf key is accepted, for EC and for RSA', () async {
      for (final cert in ['ec_self.pem', 'rsa_self.pem']) {
        final server = await serve(cert);
        await pins.save(authority, _fp(cert));
        final response = await _login(_client(server, pins));
        expect(response.statusCode, 200, reason: cert);
        expect(server.requests, 1);
        // The credentials were sent only because the key matched.
        expect(server.headersSeen.single, contains('secret-installation-key'));
      }
    });

    test('a different key is refused and the server gets zero bytes', () async {
      final server = await serve('other_self.pem');
      await pins.save(authority, _fp('ec_self.pem'));
      final error = await _failure(_login(_client(server, pins)));
      final mismatch = pinMismatchOf(error);
      expect(mismatch, isNotNull);
      expect(mismatch!.pinned, _fp('ec_self.pem'));
      expect(mismatch.presented, _fp('other_self.pem'));
      expect(mismatch.host, '127.0.0.1');
      expect(mismatch.port, server.port);
      // Give a late byte every chance to arrive before asserting none did.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.bytesReceived, 0);
      expect(server.requests, 0);
    });

    test('the mismatch is recorded for the next app start', () async {
      final server = await serve('other_self.pem');
      await pins.save(authority, _fp('ec_self.pem'));
      await _failure(_login(_client(server, pins)));
      final pin = await pins.read(authority);
      expect(pin!.fingerprint, _fp('ec_self.pem'));
      expect(pin.mismatch!.presented, _fp('other_self.pem'));
    });

    test('the foreground is told about a mismatch', () async {
      final server = await serve('other_self.pem');
      await pins.save(authority, _fp('ec_self.pem'));
      final seen = ServerPinEvents.mismatches.first;
      await _failure(_login(_client(server, pins)));
      expect((await seen).presented, _fp('other_self.pem'));
    });

    test('a server that sends its own leaf followed by the pinned certificate '
        'is refused', () async {
      // The attacker holds other_self's key and appends the victim's public,
      // self-signed certificate. A pin check on the certificate where chain
      // verification failed would see the victim's certificate; the leaf is
      // the attacker's.
      final server = await serve(
        'other_self.pem',
        chain: ['other_self.pem', 'ec_self.pem'],
      );
      await pins.save(authority, _fp('ec_self.pem'));
      final error = await _failure(_login(_client(server, pins)));
      expect(pinMismatchOf(error)?.presented, _fp('other_self.pem'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.bytesReceived, 0);
    });

    test(
      'the reverse order (pinned leaf, attacker certificate after it) cannot '
      'complete a handshake the attacker has no key for',
      () async {
        // Leaf is the victim's public certificate but the server holds the
        // attacker's key: the TLS stack refuses to start such a server, so
        // there is nothing for a client to be fooled by.
        expect(
          () => TlsTestServer.start(
            chainFiles: ['ec_self.pem', 'other_self.pem'],
            keyFile: 'other_self.key.pem',
          ),
          throwsA(isA<TlsException>()),
        );
      },
    );

    test(
      'a CA-valid certificate with a different key is still refused',
      () async {
        final server = await serve('ca_signed_other.pem');
        await pins.save(authority, _fp('ca_signed.pem'));
        // Control: without the pin the same certificate passes ordinary checks
        // against the trust store holding the fixture CA.
        final unpinned = SecureServerPinStore(MemorySlots());
        final control = await _login(
          _client(server, unpinned, trust: fixtureCaContext()),
        );
        expect(control.statusCode, 200);
        final bytesBefore = server.bytesReceived;

        final error = await _failure(
          _login(_client(server, pins, trust: fixtureCaContext())),
        );
        expect(pinMismatchOf(error)?.presented, _fp('ca_signed_other.pem'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(server.bytesReceived, bytesBefore);
      },
    );

    test('a pinned self-signed key works without any trusted root', () async {
      final server = await serve('ec_self.pem');
      await pins.save(authority, _fp('ec_self.pem'));
      // Even with an explicit empty trust store handed to the client.
      final dio = _client(
        server,
        pins,
        trust: SecurityContext(withTrustedRoots: false),
      );
      expect((await _login(dio)).statusCode, 200);
    });

    test('an unreadable pin refuses the connection (fails closed)', () async {
      final server = await serve('ec_self.pem');
      final slots = MemorySlots()
        ..values[SecureServerPinStore.keyFor(authority)] = 'not json';
      final broken = SecureServerPinStore(slots);
      final error = await _failure(_login(_client(server, broken)));
      expect(error, isA<DioException>());
      expect(server.connections, 0);
      expect(server.bytesReceived, 0);
    });

    test(
      'closing connections after a pin change drops the reused socket',
      () async {
        final server = await serve('ec_self.pem');
        await pins.save(authority, _fp('ec_self.pem'));
        final dio = _client(server, pins);
        await _login(dio);
        await _login(dio);
        expect(server.connections, 1, reason: 'keep-alive reuses the socket');
        PinningConnector.closeConnectionsTo(authority);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await _login(dio);
        expect(server.connections, 2);
      },
    );

    test(
      'a cancelled connection attempt cannot yield a usable socket',
      () async {
        final server = await serve('ec_self.pem');
        await pins.save(authority, _fp('ec_self.pem'));
        final connector = PinningConnector(pins: pins);
        final task = await connector.connect(
          Uri.parse('${server.baseUrl}/x'),
          null,
          null,
        );
        task.cancel();
        await expectLater(task.socket, throwsA(isA<SocketException>()));
      },
    );
  });

  group('unpinned host', () {
    test(
      'a self-signed certificate is rejected by the strict client',
      () async {
        final server = await serve('ec_self.pem');
        final error = await _failure(_login(_client(server, pins)));
        expect(error, isA<DioException>());
        expect(pinMismatchOf(error), isNull);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(server.bytesReceived, 0);
        expect(server.requests, 0);
      },
    );

    test('a CA-signed certificate with the wrong name is rejected', () async {
      final server = await serve('ca_wrong_name.pem');
      final error = await _failure(
        _login(_client(server, pins, trust: fixtureCaContext())),
      );
      expect(error, isA<DioException>());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.bytesReceived, 0);
    });

    test('a CA-signed certificate passes ordinary checking', () async {
      final server = await serve('ca_signed.pem');
      final response = await _login(
        _client(server, pins, trust: fixtureCaContext()),
      );
      expect(response.statusCode, 200);
    });

    test(
      'a rejected certificate is noted, announced and still refused',
      () async {
        final server = await serve('ec_self.pem');
        final announced = <ServerAuthority>[];
        final subscription = ServerPinEvents.rejections.listen(announced.add);
        addTearDown(subscription.cancel);
        expect(ServerPinEvents.isRejected(authority), isFalse);

        final error = await _failure(_login(_client(server, pins)));

        expect(isCertificateRejection(error), isTrue);
        expect(ServerPinEvents.isRejected(authority), isTrue);
        expect(announced, [authority]);
        // Noting it trusts nothing: nothing was sent and nothing was pinned.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(server.bytesReceived, 0);
        expect(await pins.read(authority), isNull);
        // The person's decision clears the note.
        ServerPinEvents.forgetRejection(authority);
        expect(ServerPinEvents.isRejected(authority), isFalse);
      },
    );

    test('a later valid connection clears the note', () async {
      final server = await serve('ca_signed.pem');
      // A rejection recorded earlier for this very server (the certificate
      // has since been replaced by a valid one).
      final announced = <ServerAuthority>[];
      final subscription = ServerPinEvents.rejections.listen(announced.add);
      addTearDown(subscription.cancel);
      final rejected = await _failure(_login(_client(server, pins)));
      expect(isCertificateRejection(rejected), isTrue);
      expect(ServerPinEvents.isRejected(authority), isTrue);

      final response = await _login(
        _client(server, pins, trust: fixtureCaContext()),
      );
      expect(response.statusCode, 200);
      expect(ServerPinEvents.isRejected(authority), isFalse);
      expect(announced, [authority, authority]);
    });

    test('a pinned connection is never noted as a rejection', () async {
      final server = await serve('ec_self.pem');
      await pins.save(authority, _fp('ec_self.pem'));
      await _login(_client(server, pins));
      await pins.save(authority, _fp('rsa_self.pem'));
      await _failure(_login(_client(server, pins)));
      expect(ServerPinEvents.isRejected(authority), isFalse);
    });

    test('unrelated errors are not certificate rejections', () {
      expect(isCertificateRejection(null), isFalse);
      expect(isCertificateRejection(const SocketException('down')), isFalse);
      expect(
        isCertificateRejection(const HandshakeException('wrong version')),
        isFalse,
      );
      expect(
        isCertificateRejection(
          DioException(
            requestOptions: RequestOptions(),
            error: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          ),
        ),
        isTrue,
      );
    });

    test('plain http is refused', () async {
      final dio = createServerDio(
        options: BaseOptions(baseUrl: 'http://127.0.0.1:9'),
        pins: pins,
      );
      expect(await _failure(dio.get<dynamic>('/x')), isA<DioException>());
    });
  });

  group('probe', () {
    test(
      'reports the leaf fingerprint and an invalid chain for self-signed',
      () async {
        final server = await serve('ec_self.pem');
        final probe = await probeServerCertificate(authority);
        expect(probe.fingerprint, _fp('ec_self.pem'));
        expect(probe.chainValid, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(server.bytesReceived, 0, reason: 'a probe sends nothing');
      },
    );

    test('reports a valid chain for a certificate the store trusts', () async {
      final server = await serve('ca_signed.pem');
      final probe = await probeServerCertificate(
        authority,
        context: fixtureCaContext(),
      );
      expect(probe.fingerprint, _fp('ca_signed.pem'));
      expect(probe.chainValid, isTrue);
      expect(server.bytesReceived, 0);
    });

    test(
      'the same CA-signed certificate is not valid without the CA',
      () async {
        await serve('ca_signed.pem');
        expect((await probeServerCertificate(authority)).chainValid, isFalse);
      },
    );

    test('a certificate for another name is not valid', () async {
      await serve('ca_wrong_name.pem');
      final probe = await probeServerCertificate(
        authority,
        context: fixtureCaContext(),
      );
      expect(probe.chainValid, isFalse);
      expect(probe.fingerprint, _fp('ca_wrong_name.pem'));
    });

    test('reports the leaf, not a later chain certificate', () async {
      await serve('other_self.pem', chain: ['other_self.pem', 'ec_self.pem']);
      final probe = await probeServerCertificate(authority);
      expect(probe.fingerprint, _fp('other_self.pem'));
    });
  });
}
