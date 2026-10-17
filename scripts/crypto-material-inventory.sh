#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  printf '%s\n' 'Usage: crypto-material-inventory.sh --jwt-public-key FILE --totp-key FILE --outbox-key FILE --tls-cert FILE --output ABSOLUTE_FILE' >&2
  exit 2
}

jwt_public_key=
totp_key=
outbox_key=
tls_cert=
output=
while (($#)); do
  case "$1" in
    --jwt-public-key) (($# >= 2)) || usage; jwt_public_key=$2; shift 2 ;;
    --totp-key) (($# >= 2)) || usage; totp_key=$2; shift 2 ;;
    --outbox-key) (($# >= 2)) || usage; outbox_key=$2; shift 2 ;;
    --tls-cert) (($# >= 2)) || usage; tls_cert=$2; shift 2 ;;
    --output) (($# >= 2)) || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$jwt_public_key" && -n "$totp_key" && -n "$outbox_key" && -n "$tls_cert" && -n "$output" ]] || usage
[[ "$output" == /* && ! -L "$output" && -d "$(dirname -- "$output")" && ! -e "$output" ]] \
  || { printf '%s\n' 'Inventory output must be a new file under an existing directory.' >&2; exit 2; }
for path in "$jwt_public_key" "$totp_key" "$outbox_key" "$tls_cert"; do
  [[ -f "$path" && -r "$path" ]] || { printf '%s\n' 'A required crypto-material input is unavailable.' >&2; exit 2; }
done

node --input-type=module - "$jwt_public_key" "$totp_key" "$outbox_key" "$tls_cert" "$output" <<'NODE'
import { createHash, createPublicKey, X509Certificate } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const [jwtPath, totpPath, outboxPath, tlsPath, outputPath] = process.argv.slice(-5);
const fingerprint = (bytes) => createHash('sha256').update(bytes).digest('hex');
const symmetricKey = (path, label) => {
  const encoded = readFileSync(path, 'utf8').replace(/\r?\n$/, '');
  if (!/^[a-fA-F0-9]{64}$/.test(encoded)) throw new Error(`${label} must contain exactly 32 bytes as 64 hexadecimal characters`);
  return fingerprint(Buffer.from(encoded, 'hex'));
};
const jwtKeyDer = createPublicKey(readFileSync(jwtPath)).export({ format: 'der', type: 'spki' });
const tlsCertificate = new X509Certificate(readFileSync(tlsPath));
const jwtFingerprint = fingerprint(jwtKeyDer);
const totpFingerprint = symmetricKey(totpPath, 'TOTP/API-key encryption key');
const outboxFingerprint = symmetricKey(outboxPath, 'Outbox envelope key');
const tlsFingerprint = fingerprint(tlsCertificate.raw);
const inventory = {
  formatVersion: 1,
  materials: {
    jwtVerificationKey: { keyId: `sha256:${jwtFingerprint}`, sha256: jwtFingerprint },
    totpAndApiKeyEncryption: { keyId: `sha256:${totpFingerprint}`, sha256: totpFingerprint },
    outboxEnvelopeEncryption: { keyId: `sha256:${outboxFingerprint}`, sha256: outboxFingerprint },
    tlsLeafCertificate: { keyId: `sha256:${tlsFingerprint}`, sha256: tlsFingerprint },
  },
};
writeFileSync(outputPath, `${JSON.stringify(inventory, null, 2)}\n`, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
NODE
