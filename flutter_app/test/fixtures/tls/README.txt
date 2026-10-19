TEST-ONLY TLS fixtures for the certificate pinning tests.

Every private key in this directory (*.key.pem) is a throwaway generated only
for these tests. None protects anything. Do not reuse any of them anywhere,
and do not treat their presence as a leaked secret.

  ec_self / rsa_self / other_self   self-signed leaves (EC P-256, RSA 2048, EC P-256)
  ca.pem                            test CA certificate (its key was discarded)
  ca_signed / ca_signed_other       leaves issued by the test CA for localhost, different keys
  ca_wrong_name                     leaf issued by the test CA for other.example.test only

All valid for 100 years (-days 36500), SAN DNS:localhost and IP:127.0.0.1 unless
noted. The expected fingerprints in test/core/network are the output of the
documented command (DEPLOYMENT.md, "Certificate fingerprint"):

  openssl x509 -in <cert>.pem -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | xxd -p -c 32 | tr a-f A-F | sed 's/../&:/g; s/:$//'
