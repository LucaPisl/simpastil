# Certificate Pinning Assets

Place your server's TLS certificate here as `server.pem` before building.

## How to export the certificate

```bash
# Export the leaf certificate from your live server
openssl s_client -connect <your-host>:443 </dev/null 2>/dev/null \
  | openssl x509 -out server.pem

# Verify the fingerprint (SHA-256 of DER-encoded cert)
openssl x509 -in server.pem -outform DER | openssl dgst -sha256
```

## For SPKI pinning (survives cert renewal, pins the public key)

```bash
openssl x509 -in server.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | base64
```

## IMPORTANT

- Do NOT commit a real production certificate to version control.
- Add `assets/certs/server.pem` to `.gitignore` for production deployments.
- A self-signed placeholder cert is fine for local development.
- In CI/CD, inject the cert from a secret manager at build time.
