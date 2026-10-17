#!/usr/bin/env bash
set -euo pipefail

[[ $# == 3 && "$1" == verify && "$2" == --print-certs && -s "$3" ]] || exit 64
digest="${SIMPASTIL_TEST_APKSIGNER_DIGEST:?missing test fingerprint}"
second_digest="${SIMPASTIL_TEST_APKSIGNER_SECOND_DIGEST:-0000000000000000000000000000000000000000000000000000000000000000}"

case "${SIMPASTIL_TEST_APKSIGNER_MODE:?missing report mode}" in
  modern-single)
    printf 'V2 Signer: certificate DN: CN=Simpastil Acceptance\n'
    printf 'V2 Signer: certificate SHA-256 digest: %s\n' "$digest"
    ;;
  modern-multi-scheme)
    printf 'V2 Signer: certificate SHA-256 digest: %s\n' "$digest"
    printf 'V3 Signer: certificate SHA-256 digest: %s\n' "$digest"
    ;;
  legacy-single)
    printf 'Signer #1 certificate SHA-256 digest: %s\n' "$digest"
    ;;
  modern-multiple-certificates)
    printf 'V2 Signer: certificate SHA-256 digest: %s\n' "$digest"
    printf 'V2 Signer #2: certificate SHA-256 digest: %s\n' "$second_digest"
    ;;
  *) exit 64 ;;
esac
