#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && -s "$1" ]] || fail 'usage: verify-android-signer.sh APK (APK must exist and be non-empty)'
apk="$1"

expected="${SIMPASTIL_EXPECTED_CERT_SHA256:-}"
if [[ -z "$expected" ]]; then
  properties_path="${SIMPASTIL_SIGNING_PROPERTIES:-$ROOT/flutter_app/android/signing.properties}"
  if [[ "$properties_path" != /* ]]; then
    properties_path="$ROOT/flutter_app/android/$properties_path"
  fi
  if [[ -f "$properties_path" ]]; then
    expected="$(sed -nE 's/^[[:space:]]*SIMPASTIL_EXPECTED_CERT_SHA256[[:space:]]*=[[:space:]]*([^#[:space:]]+).*$/\1/p' "$properties_path" | head -n 1)"
  fi
fi
expected="$(printf '%s' "$expected" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
[[ "$expected" =~ ^[A-F0-9]{64}$ ]] || fail 'expected SHA-256 signing fingerprint is missing or malformed'

apksigner_path="${APKSIGNER:-}"
if [[ -z "$apksigner_path" ]]; then
  apksigner_path="$(command -v apksigner || true)"
fi
if [[ -z "$apksigner_path" ]]; then
  sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]]; then
    apksigner_path="$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner -print 2>/dev/null | sort -V | tail -n 1)"
  fi
fi
[[ -x "$apksigner_path" ]] || fail 'Android build-tools apksigner is required'

report="$(mktemp "${TMPDIR:-/tmp}/simpastil-apksigner.XXXXXX")"
trap 'rm -f -- "$report"' EXIT
if ! "$apksigner_path" verify --print-certs "$apk" >"$report" 2>&1; then
  fail 'apksigner rejected the APK'
fi
if tr '[:upper:]' '[:lower:]' < "$report" | grep -Eq 'certificate dn:.*android[[:space:]]+debug'; then
  fail 'debug signing certificate is not permitted'
fi
signer_digests=()
while IFS= read -r digest; do
  normalized="$(printf '%s' "$digest" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
  [[ "$normalized" =~ ^[A-F0-9]{64}$ ]] ||
    fail 'apksigner did not report a valid SHA-256 certificate fingerprint'
  signer_digests+=("$normalized")
done < <(
  sed -nE \
    -e 's/^Signer #[0-9]+ certificate SHA-256 digest:[[:space:]]*([A-Fa-f0-9:]+).*$/\1/p' \
    -e 's/^V[0-9]+([.][0-9]+)? Signer( #[0-9]+)?: certificate SHA-256 digest:[[:space:]]*([A-Fa-f0-9:]+).*$/\3/p' \
    "$report"
)
[[ ${#signer_digests[@]} -gt 0 ]] ||
  fail 'apksigner did not report an APK signing certificate'
unique_digests="$(printf '%s\n' "${signer_digests[@]}" | LC_ALL=C sort -u)"
unique_count="$(printf '%s\n' "$unique_digests" | wc -l | tr -d '[:space:]')"
[[ "$unique_count" == 1 ]] || fail 'exactly one APK signing certificate is required'
actual="${signer_digests[0]}"
[[ "$actual" == "$expected" ]] || fail 'APK certificate fingerprint does not match the configured release identity'

printf 'certificate_sha256=%s\n' "$actual"
