import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/network/spki_fingerprint.dart';

import '../../helpers/tls_test_server.dart';

// Expected values are the output of the command in DEPLOYMENT.md
// ("Certificate fingerprint"), run on each fixture:
//   openssl x509 -in <cert>.pem -pubkey -noout | openssl pkey -pubin -outform der
//     | openssl dgst -sha256 -binary | xxd -p -c 32 | tr a-f A-F
//     | sed 's/../&:/g; s/:$//'
const _expected = {
  'ec_self.pem':
      '1E:9A:8D:B1:8B:2F:9A:4C:A6:BC:D3:B7:EB:DF:E2:96:1E:B6:A6:3A:90:8C:73:96:6A:6D:5F:C2:8A:E4:5B:F6',
  'rsa_self.pem':
      'C4:04:AD:88:A3:31:2E:D4:8C:28:24:68:4C:35:9F:FF:44:07:3E:D1:08:77:48:B5:06:95:AB:BF:E0:02:6B:39',
  'other_self.pem':
      'CE:61:C0:6C:07:3D:9A:2C:32:BC:CE:B0:43:07:2C:D4:4B:BB:B2:F4:98:76:08:5A:C6:F3:D4:9F:85:11:2F:74',
  'ca_signed.pem':
      '75:F7:B3:C0:0D:EF:78:E0:B7:AA:C4:6A:15:7C:7F:64:B7:B2:4E:7F:80:1C:EE:CE:15:77:EF:28:F7:CD:75:D5',
  'ca_signed_other.pem':
      '1C:86:80:E8:48:D6:F6:2D:35:2C:D1:ED:01:88:75:07:AD:16:B5:7E:4D:88:BE:5C:49:71:C5:49:DF:DB:42:EF',
  'ca_wrong_name.pem':
      '51:26:D7:3B:94:F4:9B:78:98:3A:0B:B6:36:1C:FA:C4:C8:E2:57:CF:ED:42:00:ED:19:BE:60:8D:9A:AD:09:0C',
};

void main() {
  group('SPKI fingerprint', () {
    for (final entry in _expected.entries) {
      test('${entry.key} equals the documented openssl command', () {
        final fingerprint = spkiFingerprintOfCertificate(
          certificateDerOf(entry.key),
        );
        expect(fingerprint, entry.value);
        expect(fingerprint, hasLength(95));
        expect(isWellFormedFingerprint(fingerprint), isTrue);
      });
    }

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
        _expected['ec_self.pem'],
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
      expect(isWellFormedFingerprint(_expected['ec_self.pem']!), isTrue);
      expect(
        isWellFormedFingerprint(_expected['ec_self.pem']!.toLowerCase()),
        isFalse,
      );
      expect(isWellFormedFingerprint('AA:BB'), isFalse);
      expect(
        isWellFormedFingerprint(_expected['ec_self.pem']!.replaceAll(':', '')),
        isFalse,
      );
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
