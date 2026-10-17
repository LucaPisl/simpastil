#!/usr/bin/env bash
# generate-keys.sh — Generate the RSA-2048 keypair used for JWT RS256 signing.
#
# Usage:
#   bash scripts/generate-keys.sh SECRET_DIR
#
# Writes SECRET_DIR/jwt_private.pem and SECRET_DIR/jwt_public.pem, the file names
# DEPLOYMENT.md and .env.example point JWT_PRIVATE_KEY_FILE / JWT_PUBLIC_KEY_FILE
# at. SECRET_DIR is created with mode 0700 when missing and should live outside
# the checkout (for example /secure/simpastil). The files are mode 0444 so the
# non-root API container user (UID 1001) can read the bind-mounted secrets, as
# DEPLOYMENT.md describes. Existing key files are never overwritten.
#
# For a local development .env use `npx tsx scripts/generate-keys.ts` in server/.
#
# Requirements: openssl

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: bash scripts/generate-keys.sh SECRET_DIR" >&2
  exit 2
fi

SECRET_DIR="$1"
PRIVATE_KEY="$SECRET_DIR/jwt_private.pem"
PUBLIC_KEY="$SECRET_DIR/jwt_public.pem"

for existing in "$PRIVATE_KEY" "$PUBLIC_KEY"; do
  if [ -e "$existing" ] || [ -L "$existing" ]; then
    echo "Refusing to overwrite existing $existing" >&2
    echo "Rotating signing keys invalidates every issued token; move the old files aside deliberately first." >&2
    exit 1
  fi
done

umask 077
mkdir -p "$SECRET_DIR"
chmod 0700 "$SECRET_DIR"

TMP_PRIVATE="$(mktemp "$SECRET_DIR/.jwt_private.XXXXXX")"
TMP_PUBLIC="$(mktemp "$SECRET_DIR/.jwt_public.XXXXXX")"
cleanup() {
  rm -f "$TMP_PRIVATE" "$TMP_PUBLIC"
}
trap cleanup EXIT

openssl genrsa -out "$TMP_PRIVATE" 2048 2>/dev/null
openssl rsa -in "$TMP_PRIVATE" -pubout -out "$TMP_PUBLIC" 2>/dev/null
chmod 0444 "$TMP_PRIVATE" "$TMP_PUBLIC"

# ln refuses to replace an existing file, so a concurrent run cannot clobber keys.
ln "$TMP_PRIVATE" "$PRIVATE_KEY"
ln "$TMP_PUBLIC" "$PUBLIC_KEY"

echo "Wrote $PRIVATE_KEY and $PUBLIC_KEY"
echo "Point JWT_PRIVATE_KEY_FILE and JWT_PUBLIC_KEY_FILE in your Compose env file at them."
echo "The private key is a SECRET: never commit it, and retain a separate protected backup."
