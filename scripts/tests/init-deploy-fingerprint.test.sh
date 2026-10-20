#!/usr/bin/env bash
# Checks that scripts/init-deploy.sh prints the certificate fingerprint the
# Android app shows (SHA-256 of the DER SubjectPublicKeyInfo of the leaf, as
# colon-separated uppercase hex), and that it matches the command in
# DEPLOYMENT.md and an independent computation. Runs against throwaway
# self-signed certificates in a copy of the scripts; nothing leaves the temp dir.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-init-fingerprint.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || fail 'openssl is required'

# init-deploy.sh derives the checkout from its own location, so run a copy.
fixture="$TMP/checkout"
mkdir -p "$fixture/scripts"
cp "$ROOT/scripts/init-deploy.sh" "$ROOT/scripts/generate-keys.sh" "$fixture/scripts/"

make_cert() { # name, then the -newkey arguments
  local name=$1; shift
  openssl req -x509 -newkey "$@" -nodes -days 2 -subj "/CN=$name.test" \
    -keyout "$TMP/$name.key" -out "$TMP/$name.pem" 2>/dev/null
}
make_cert ec ec -pkeyopt ec_paramgen_curve:P-256
make_cert rsa rsa:2048
make_cert intermediate ec -pkeyopt ec_paramgen_curve:P-256
cat "$TMP/ec.pem" "$TMP/intermediate.pem" > "$TMP/chain.pem"

# The documented one-liner, taken from DEPLOYMENT.md with the example path swapped.
doc_command=$(grep -m1 '^openssl x509 -in nginx/certs/cert.pem -pubkey -noout' "$ROOT/DEPLOYMENT.md") \
  || fail 'DEPLOYMENT.md must carry the fingerprint command'
doc_fingerprint() { # certificate file, optional hex dumper replacing xxd
  local command=${doc_command//nginx\/certs\/cert.pem/$1}
  [[ -z "${2:-}" ]] || command=${command//xxd -p -c 32/$2}
  bash -c "set -o pipefail; $command"
}

expected_fingerprint() {
  node -e '
    const { createHash, X509Certificate } = require("node:crypto");
    const { readFileSync } = require("node:fs");
    const cert = new X509Certificate(readFileSync(process.argv[1]));
    const spki = cert.publicKey.export({ format: "der", type: "spki" });
    const hex = createHash("sha256").update(spki).digest("hex").toUpperCase();
    process.stdout.write(hex.match(/../g).join(":") + "\n");
  ' "$1"
}

run_init() { # case name, then init-deploy.sh options
  local name=$1; shift
  bash "$fixture/scripts/init-deploy.sh" --domain pills.example.test --smtp-host smtp.example.test \
    --secrets-dir "$TMP/$name/secrets" --backup-dir "$TMP/$name/backups" "$@"
}

check_case() { # case name, certificate the install serves, init-deploy.sh options
  local name=$1 cert=$2; shift 2
  rm -rf -- "$fixture/nginx"
  local output expected printed
  output=$(run_init "$name" "$@") || fail "$name: init-deploy.sh failed: $output"
  expected=$(expected_fingerprint "$cert")
  [[ "$expected" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] || fail "$name: independent fingerprint has the wrong shape: $expected"
  printed=$(grep -E '^  ([0-9A-F]{2}:){31}[0-9A-F]{2}$' <<<"$output" | tr -d ' ') || fail "$name: no fingerprint printed: $output"
  [[ "$printed" == "$expected" ]] || fail "$name: printed $printed, expected $expected"
  [[ ${#printed} -eq 95 ]] || fail "$name: fingerprint must be 95 characters"
  if [[ $have_xxd == yes ]]; then
    [[ "$(doc_fingerprint "$cert")" == "$expected" ]] || fail "$name: the DEPLOYMENT.md xxd command disagrees"
  fi
  [[ "$(doc_fingerprint "$cert" "od -An -tx1 -v | tr -d ' \\n'")" == "$expected" ]] \
    || fail "$name: the DEPLOYMENT.md od fallback disagrees"
  printf 'PASS: %s prints %s\n' "$name" "$printed"
}

have_xxd=yes
command -v xxd >/dev/null || { have_xxd=no; printf 'NOTE: xxd is not installed; the DEPLOYMENT.md xxd command was not exercised\n'; }

check_case ec-provided "$TMP/ec.pem" --tls provided --cert "$TMP/ec.pem" --key "$TMP/ec.key"
check_case rsa-provided "$TMP/rsa.pem" --tls provided --cert "$TMP/rsa.pem" --key "$TMP/rsa.key"
# A chain file: only the first certificate, the leaf, is fingerprinted.
check_case chain-provided "$TMP/ec.pem" --tls provided --cert "$TMP/chain.pem" --key "$TMP/ec.key"
check_case host-proxy "$TMP/rsa.pem" --tls host-proxy --cert "$TMP/rsa.pem"
# The self-signed mode generates its own certificate, so compare with what it installed.
rm -rf -- "$fixture/nginx"
output=$(run_init self-signed --tls self-signed) || fail "self-signed: init-deploy.sh failed: $output"
printed=$(grep -E '^  ([0-9A-F]{2}:){31}[0-9A-F]{2}$' <<<"$output" | tr -d ' ') || fail "self-signed: no fingerprint printed"
[[ "$printed" == "$(expected_fingerprint "$fixture/nginx/certs/cert.pem")" ]] \
  || fail 'self-signed: printed fingerprint does not match the installed certificate'
printf 'PASS: self-signed prints %s\n' "$printed"
