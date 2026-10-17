#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-signer-output.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

printf 'disposable APK fixture\n' > "$TMP/fixture.apk"
export APKSIGNER="$ROOT/scripts/tests/fixtures/apksigner-output.sh"
export SIMPASTIL_EXPECTED_CERT_SHA256=8E4B0042E9E21CD57CFDD1800651FAFB8B318E453EA9406EBB25D57BFB87313E
export SIMPASTIL_TEST_APKSIGNER_DIGEST=8e4b0042e9e21cd57cfdd1800651fafb8b318e453ea9406ebb25d57bfb87313e

for mode in modern-single modern-multi-scheme legacy-single; do
  export SIMPASTIL_TEST_APKSIGNER_MODE="$mode"
  output="$("$ROOT/scripts/verify-android-signer.sh" "$TMP/fixture.apk")" ||
    fail "a single release identity was rejected for apksigner output format $mode"
  [[ "$output" == "certificate_sha256=$SIMPASTIL_EXPECTED_CERT_SHA256" ]] ||
    fail "the verified fingerprint was not normalized for output format $mode"
done

export SIMPASTIL_TEST_APKSIGNER_MODE=modern-multiple-certificates
if "$ROOT/scripts/verify-android-signer.sh" "$TMP/fixture.apk" > "$TMP/multiple.log" 2>&1; then
  fail 'multiple distinct APK signing certificates were accepted'
fi
grep -Fq 'exactly one APK signing certificate is required' "$TMP/multiple.log" ||
  fail 'multiple certificates failed without the expected safe diagnostic'

printf 'PASS: old and current apksigner reports enforce one configured certificate identity\n'
