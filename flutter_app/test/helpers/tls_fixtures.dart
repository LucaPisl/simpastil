import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// TLS fixtures for the certificate pinning tests, generated with the
/// `openssl` command line at test time.
///
/// Nothing here is committed: the repository holds no private keys, not even
/// throwaway test ones. The first call in a test process creates a private
/// temporary directory and fills it with the set described in
/// `test/fixtures/tls/README.txt`. Every process (each test file runs in its
/// own) makes its own directory, so parallel runs never share a path.
///
/// Without `openssl` on the PATH every test that needs a fixture fails with
/// [_missingOpenssl]. Nothing is skipped.
const _missingOpenssl =
    'openssl is required for the TLS pinning tests. Install the openssl '
    'command line tool and make sure it is on the PATH.';

const _validityDays = '36500';
const _leafNames = ['ec_self', 'rsa_self', 'other_self'];

Directory? _directory;

/// Absolute path of the fixture [name] (for example `ec_self.pem` or
/// `ec_self.key.pem`), generating the whole set on first use.
String tlsFixture(String name) => '${_ensureFixtures().path}/$name';

/// Deletes the generated directory. Registered once per test file by
/// `test/flutter_test_config.dart`; safe to call when nothing was generated.
void deleteTlsFixtures() {
  final directory = _directory;
  _directory = null;
  if (directory != null && directory.existsSync()) {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort: the OS clears the temp directory eventually.
    }
  }
}

/// DER bytes of the first certificate in a PEM fixture.
Uint8List certificateDerOf(String fixtureName) {
  final pem = File(tlsFixture(fixtureName)).readAsStringSync();
  final body = pem
      .split('-----BEGIN CERTIFICATE-----')[1]
      .split('-----END CERTIFICATE-----')[0]
      .replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(base64.decode(body));
}

/// The fingerprint of a certificate fixture as the documented operator command
/// computes it (DEPLOYMENT.md, "Certificate fingerprint"):
///
///     openssl x509 -in cert.pem -pubkey -noout
///       | openssl pkey -pubin -outform der
///       | openssl dgst -sha256 -binary
///       | xxd -p -c 32 | tr a-f A-F | sed 's/../&:/g; s/:$//'
///
/// The three openssl stages run one after another with their output staged in
/// files (no shell, no pipe), and the hex formatting is done here instead of
/// by `xxd`, `tr` and `sed`. Independent of the app's own implementation.
String documentedFingerprintOf(String fixtureName) {
  final directory = Directory.systemTemp.createTempSync('tls-fingerprint');
  try {
    final publicKeyPem = '${directory.path}/public.pem';
    final publicKeyDer = '${directory.path}/public.der';
    File(publicKeyPem).writeAsStringSync(
      _openssl([
            'x509',
            '-in',
            tlsFixture(fixtureName),
            '-pubkey',
            '-noout',
          ]).stdout
          as String,
    );
    File(publicKeyDer).writeAsBytesSync(
      _openssl([
            'pkey',
            '-pubin',
            '-in',
            publicKeyPem,
            '-outform',
            'der',
          ], binaryOutput: true).stdout
          as List<int>,
    );
    final digest =
        _openssl([
              'dgst',
              '-sha256',
              '-binary',
              publicKeyDer,
            ], binaryOutput: true).stdout
            as List<int>;
    return digest
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Directory _ensureFixtures() {
  final existing = _directory;
  if (existing != null) return existing;
  final directory = Directory.systemTemp.createTempSync('simpastil-tls-');
  try {
    _generate(directory.path);
  } catch (_) {
    directory.deleteSync(recursive: true);
    rethrow;
  }
  return _directory = directory;
}

void _generate(String dir) {
  String p(String name) => '$dir/$name';
  const san = 'subjectAltName=DNS:localhost,IP:127.0.0.1';

  // Self-signed leaves: EC P-256, RSA 2048, and a second EC key.
  for (final name in _leafNames) {
    _openssl([
      'req',
      '-x509',
      '-newkey',
      name == 'rsa_self' ? 'rsa:2048' : 'ec',
      if (name != 'rsa_self') ...['-pkeyopt', 'ec_paramgen_curve:P-256'],
      '-nodes',
      '-keyout',
      p('$name.key.pem'),
      '-out',
      p('$name.pem'),
      '-days',
      _validityDays,
      '-subj',
      '/CN=localhost',
      '-addext',
      san,
    ]);
  }

  // The test CA. Its key stays in the temporary directory only.
  _openssl([
    'req',
    '-x509',
    '-newkey',
    'ec',
    '-pkeyopt',
    'ec_paramgen_curve:P-256',
    '-nodes',
    '-keyout',
    p('ca.key.pem'),
    '-out',
    p('ca.pem'),
    '-days',
    _validityDays,
    '-subj',
    '/CN=Simpastil TLS test CA',
    '-addext',
    'basicConstraints=critical,CA:TRUE',
    '-addext',
    'keyUsage=critical,keyCertSign,cRLSign',
  ]);

  // Leaves issued by the CA, each with its own key.
  void issue(String name, String subjectAltName) {
    final extensions = p('$name.ext');
    File(extensions).writeAsStringSync(
      'basicConstraints=CA:FALSE\n'
      'keyUsage=critical,digitalSignature\n'
      'extendedKeyUsage=serverAuth\n'
      '$subjectAltName\n',
    );
    _openssl([
      'req',
      '-new',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-nodes',
      '-keyout',
      p('$name.key.pem'),
      '-out',
      p('$name.csr'),
      '-subj',
      '/CN=localhost',
    ]);
    _openssl([
      'x509',
      '-req',
      '-in',
      p('$name.csr'),
      '-CA',
      p('ca.pem'),
      '-CAkey',
      p('ca.key.pem'),
      '-CAcreateserial',
      '-out',
      p('$name.pem'),
      '-days',
      _validityDays,
      '-extfile',
      extensions,
    ]);
  }

  issue('ca_signed', san);
  issue('ca_signed_other', san);
  issue('ca_wrong_name', 'subjectAltName=DNS:other.example.test');
}

ProcessResult _openssl(List<String> arguments, {bool binaryOutput = false}) {
  final ProcessResult result;
  try {
    result = Process.runSync(
      'openssl',
      arguments,
      stdoutEncoding: binaryOutput ? null : utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException catch (error) {
    throw StateError('$_missingOpenssl (${error.message})');
  }
  if (result.exitCode != 0) {
    throw StateError(
      'openssl ${arguments.first} failed with exit code ${result.exitCode}: '
      '${result.stderr}',
    );
  }
  return result;
}
