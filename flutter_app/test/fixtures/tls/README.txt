The TLS fixtures for the certificate pinning tests are NOT stored here.

They are generated at test time by test/helpers/tls_fixtures.dart, using the
`openssl` command line tool, into a fresh temporary directory per test process
that is deleted when the test file finishes (test/flutter_test_config.dart).
This directory holds only this note.

Why: the fixtures include private keys. Even throwaway test keys do not belong
in Git: this repository is mirrored publicly, secret scanners cannot tell a test
key from a real one, and the project rule is no keys in version control. The
root .gitignore also excludes *.pem. Generating them keeps every checkout and CI
run reproducible without committing any key.

`openssl` must be on the PATH. If it is missing, the pinning tests FAIL with
"openssl is required for the TLS pinning tests"; they are never skipped.

The generated set (tlsFixture('<name>') resolves into the temporary directory):

  ec_self / rsa_self / other_self   self-signed leaves (EC P-256, RSA 2048, EC P-256)
  ca.pem                            test CA certificate (EC P-256)
  ca_signed / ca_signed_other       leaves issued by the test CA for localhost, different keys
  ca_wrong_name                     leaf issued by the test CA for other.example.test only

Each certificate has a matching <name>.key.pem. All are valid for 100 years
(-days 36500), with SAN DNS:localhost and IP:127.0.0.1 unless noted.

No fingerprint is hard-coded anywhere. The expected values come from running the
documented command (DEPLOYMENT.md, "Certificate fingerprint") on the generated
certificate and are compared with the app's own implementation:

  openssl x509 -in <cert>.pem -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | xxd -p -c 32 | tr a-f A-F | sed 's/../&:/g; s/:$//'
