#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ "${SIMPASTIL_ACCEPTANCE_SCOPE:-}" == disposable-android-signing ]] \
  || fail 'set SIMPASTIL_ACCEPTANCE_SCOPE=disposable-android-signing to confirm this uses only a generated test signer'
[[ $# == 1 ]] || fail 'usage: android-release.sh ABSOLUTE_OUTPUT_DIR'
[[ "$1" == /* && "$1" != / ]] || fail 'output directory must be an explicit absolute non-root path'
output="$(realpath -m "$1")"
repo_root="$(git -C "$ROOT" rev-parse --show-toplevel)"
case "$output/" in "$repo_root/"*) fail 'release output must be outside the repository';; esac
[[ ! -e "$output" ]] || fail 'output directory already exists; choose a fresh disposable path'

for tool in flutter gradle keytool sha256sum od node tar; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-android-release.XXXXXX")"
chmod 700 "$scratch"
trap 'rm -rf -- "$scratch"' EXIT
expected_flutter="$(sed -nE 's/^[[:space:]]*"flutter":[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*$/\1/p' "$ROOT/.fvmrc")"
actual_flutter="$(flutter --version --machine | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).flutterVersion))')"
[[ -n "$expected_flutter" && "$actual_flutter" == "$expected_flutter" ]] || fail 'installed Flutter does not match .fvmrc'
expected_gradle="$(sed -nE 's/^distributionUrl=.*gradle-([0-9]+\.[0-9]+\.[0-9]+)-all\.zip$/\1/p' "$ROOT/flutter_app/android/gradle/wrapper/gradle-wrapper.properties")"
actual_gradle="$(gradle --no-daemon --console=plain --version | sed -nE 's/^Gradle ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)"
[[ -n "$expected_gradle" && "$expected_gradle" == "$actual_gradle" ]] || fail 'installed Gradle does not match the checked wrapper distribution'

workspace="$scratch/workspace"
mkdir -p "$workspace"
tar -C "$ROOT" \
  --exclude='flutter_app/.dart_tool' \
  --exclude='flutter_app/build' \
  --exclude='flutter_app/android/.gradle' \
  --exclude='flutter_app/android/local.properties' \
  --exclude='flutter_app/android/signing.properties' \
  --exclude='flutter_app/**/.env*' \
  --exclude='flutter_app/**/node_modules' \
  --exclude='flutter_app/**/coverage' \
  --exclude='flutter_app/**/signing.properties' \
  --exclude='flutter_app/**/*.pem' \
  --exclude='flutter_app/**/*.key' \
  --exclude='flutter_app/android/*.jks' \
  --exclude='flutter_app/android/*.keystore' \
  --exclude='flutter_app/android/*.p12' \
  -cf - flutter_app contracts | tar -C "$workspace" -xf -
flutter_project="$workspace/flutter_app"
android_project="$flutter_project/android"

export SIMPASTIL_ACCEPTANCE_STORE_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
export SIMPASTIL_ACCEPTANCE_KEY_PASSWORD="$SIMPASTIL_ACCEPTANCE_STORE_PASSWORD"
[[ -n "$SIMPASTIL_ACCEPTANCE_STORE_PASSWORD" ]] || fail 'disposable password generation failed'
key_store="$scratch/acceptance-signing.p12"
key_alias='simpastil-acceptance'
SIMPASTIL_ACCEPTANCE_STORE_PASSWORD="$SIMPASTIL_ACCEPTANCE_STORE_PASSWORD" \
SIMPASTIL_ACCEPTANCE_KEY_PASSWORD="$SIMPASTIL_ACCEPTANCE_KEY_PASSWORD" \
  keytool -genkeypair -noprompt -storetype PKCS12 -keystore "$key_store" \
    -storepass:env SIMPASTIL_ACCEPTANCE_STORE_PASSWORD \
    -keypass:env SIMPASTIL_ACCEPTANCE_KEY_PASSWORD \
    -alias "$key_alias" -keyalg RSA -keysize 2048 -validity 3650 \
    -dname 'CN=Simpastil Disposable Acceptance,O=Simpastil,C=RO' \
    >"$scratch/keytool.log" 2>&1 || fail 'disposable acceptance signer could not be generated'
keytool -exportcert -keystore "$key_store" -storepass:env SIMPASTIL_ACCEPTANCE_STORE_PASSWORD \
  -alias "$key_alias" -file "$scratch/certificate.der" >"$scratch/export.log" 2>&1 ||
  fail 'disposable acceptance certificate could not be exported'
expected_fingerprint="$(sha256sum "$scratch/certificate.der" | cut -d ' ' -f 1)"

signing_properties="$scratch/signing.properties"
umask 077
printf 'SIMPASTIL_KEYSTORE_PATH=%s\nSIMPASTIL_KEY_ALIAS=%s\nSIMPASTIL_STORE_PASSWORD=%s\nSIMPASTIL_KEY_PASSWORD=%s\nSIMPASTIL_EXPECTED_CERT_SHA256=%s\n' \
  "$key_store" "$key_alias" "$SIMPASTIL_ACCEPTANCE_STORE_PASSWORD" \
  "$SIMPASTIL_ACCEPTANCE_KEY_PASSWORD" "$expected_fingerprint" > "$signing_properties"
unset SIMPASTIL_ACCEPTANCE_STORE_PASSWORD SIMPASTIL_ACCEPTANCE_KEY_PASSWORD

(cd "$flutter_project" && flutter pub get --enforce-lockfile) >"$scratch/pub-get.log" 2>&1 || {
  tail -n 60 "$scratch/pub-get.log" >&2
  fail 'Flutter could not resolve the tracked lockfile'
}
if ! (cd "$flutter_project" && SIMPASTIL_SIGNING_PROPERTIES="$signing_properties" flutter build apk --release) >"$scratch/release-build.log" 2>&1; then
  fail 'disposable signed release APK build failed'
fi
for password in "$(sed -n 's/^SIMPASTIL_STORE_PASSWORD=//p' "$signing_properties")" \
  "$(sed -n 's/^SIMPASTIL_KEY_PASSWORD=//p' "$signing_properties")"; do
  if grep -Fq "$password" "$scratch/release-build.log"; then
    fail 'a signing password appeared in Gradle output'
  fi
done

apk="$flutter_project/build/app/outputs/flutter-apk/app-release.apk"
[[ -s "$apk" ]] || fail 'release APK output is missing'
SIMPASTIL_SIGNING_PROPERTIES="$signing_properties" "$ROOT/scripts/verify-android-signer.sh" "$apk"
SIMPASTIL_FLUTTER_PROJECT_ROOT="$flutter_project" \
SIMPASTIL_ANDROID_PROJECT_ROOT="$android_project" \
SIMPASTIL_SIGNING_PROPERTIES="$signing_properties" \
SIMPASTIL_MANIFEST_CLASS=acceptance-only \
  "$ROOT/scripts/build-release-manifest.sh" "$apk" "$output"
printf 'acceptance_artifact_class=acceptance-only\n'
printf 'acceptance_output=%s\n' "$output"
