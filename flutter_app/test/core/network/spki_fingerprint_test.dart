import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/network/spki_fingerprint.dart';

import '../../helpers/tls_test_server.dart';

// The fixtures are generated at test time (see helpers/tls_fixtures.dart), so
// nothing here is a hard-coded key or fingerprint. The expected value is
// computed by running the command in DEPLOYMENT.md ("Certificate fingerprint")
// on the generated certificate, which also proves that command and the app
// agree.
const _fixtures = [
  'ec_self.pem',
  'rsa_self.pem',
  'other_self.pem',
  'ca_signed.pem',
  'ca_signed_other.pem',
  'ca_wrong_name.pem',
];

void main() {
  group('SPKI fingerprint', () {
    for (final fixture in _fixtures) {
      test('$fixture equals the documented openssl command', () {
        final fingerprint = spkiFingerprintOfCertificate(
          certificateDerOf(fixture),
        );
        expect(fingerprint, documentedFingerprintOf(fixture));
        expect(fingerprint, hasLength(95));
        expect(isWellFormedFingerprint(fingerprint), isTrue);
      });
    }

    test('every fixture has its own key', () {
      final fingerprints = {
        for (final fixture in _fixtures) documentedFingerprintOf(fixture),
      };
      expect(fingerprints, hasLength(_fixtures.length));
    });

    test('EC and RSA keys are both covered', () {
      // P-256 keys have a 91-byte SPKI, RSA-2048 keys a 294-byte one.
      expect(
        subjectPublicKeyInfoOf(certificateDerOf('ec_self.pem')).length,
        91,
      );
      expect(
        subjectPublicKeyInfoOf(certificateDerOf('rsa_self.pem')).length,
        294,
      );
    });

    test('a certificate without the optional version field still parses', () {
      // Swap the leading [0] version for nothing: rebuild the TBS minus it.
      final der = certificateDerOf('ec_self.pem');
      final versionless = _dropVersion(der);
      expect(
        spkiFingerprintOfCertificate(versionless),
        documentedFingerprintOf('ec_self.pem'),
      );
    });

    test('malformed input is refused, never mis-parsed', () {
      final der = certificateDerOf('ec_self.pem');
      expect(
        () => spkiFingerprintOfCertificate(Uint8List(0)),
        throwsFormatException,
      );
      expect(
        () => spkiFingerprintOfCertificate(Uint8List.fromList([0x30, 0x00])),
        throwsFormatException,
      );
      expect(
        () => spkiFingerprintOfCertificate(
          Uint8List.sublistView(der, 0, der.length - 1),
        ),
        throwsFormatException,
      );
      expect(
        () => spkiFingerprintOfCertificate(Uint8List.fromList([...der, 0x00])),
        throwsFormatException,
      );
      // Indefinite length.
      expect(
        () => spkiFingerprintOfCertificate(
          Uint8List.fromList([0x30, 0x80, 0x00, 0x00]),
        ),
        throwsFormatException,
      );
      // Not a SEQUENCE.
      expect(
        () => spkiFingerprintOfCertificate(
          Uint8List.fromList([0x31, ...der.sublist(1)]),
        ),
        throwsFormatException,
      );
      // Every truncation point fails cleanly instead of reading out of range.
      for (var length = 0; length < der.length; length += 7) {
        expect(
          () => spkiFingerprintOfCertificate(
            Uint8List.sublistView(der, 0, length),
          ),
          throwsFormatException,
          reason: 'truncated to $length bytes',
        );
      }
    });

    test('canonical format check', () {
      final fingerprint = documentedFingerprintOf('ec_self.pem');
      expect(isWellFormedFingerprint(fingerprint), isTrue);
      expect(isWellFormedFingerprint(fingerprint.toLowerCase()), isFalse);
      expect(isWellFormedFingerprint('AA:BB'), isFalse);
      expect(isWellFormedFingerprint(fingerprint.replaceAll(':', '')), isFalse);
    });
  });
}

/// Removes the explicit `[0] version` from the TBSCertificate, which the
/// optional-field branch of the walker must tolerate. The signature no longer
/// verifies; the walker never checks it.
Uint8List _dropVersion(Uint8List der) {
  // Certificate SEQUENCE header is 4 bytes (0x30 0x82 hh ll) for these
  // fixtures, then the TBS SEQUENCE header is 4 bytes, then A0 03 02 01 02.
  expect(der[0], 0x30);
  expect(der[1], 0x82);
  expect(der[4], 0x30);
  expect(der[5], 0x82);
  expect(der.sublist(8, 13), [0xa0, 0x03, 0x02, 0x01, 0x02]);
  final out = [...der.sublist(0, 8), ...der.sublist(13)];
  void patch(int lengthAt, int delta) {
    final value = ((out[lengthAt] << 8) | out[lengthAt + 1]) - delta;
    out[lengthAt] = value >> 8;
    out[lengthAt + 1] = value & 0xff;
  }

  patch(2, 5);
  patch(6, 5);
  return Uint8List.fromList(out);
}
