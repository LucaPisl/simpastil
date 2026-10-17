#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-signing-policy.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

"$ROOT/scripts/tests/verify-android-signer-output.test.sh"

(cd "$ROOT/flutter_app" && flutter pub get --enforce-lockfile) >"$TMP/pub-get.log" 2>&1 || fail 'tracked Flutter lock could not be resolved'

if (cd "$ROOT/flutter_app/android" && env -u SIMPASTIL_SIGNING_PROPERTIES -u SIMPASTIL_KEYSTORE_PATH -u SIMPASTIL_KEY_ALIAS -u SIMPASTIL_STORE_PASSWORD -u SIMPASTIL_KEY_PASSWORD -u SIMPASTIL_EXPECTED_CERT_SHA256 gradle --no-daemon --console=plain :app:assembleRelease --dry-run) >"$TMP/missing.log" 2>&1; then
  fail 'assembleRelease accepted absent signing inputs'
fi
grep -Fq 'Release signing is required' "$TMP/missing.log" || fail 'missing signing did not fail with the safe diagnostic'

STORE_CANARY='store-password-must-not-leak-7bf4'
KEY_CANARY='key-password-must-not-leak-84d1'
printf 'SIMPASTIL_STORE_PASSWORD=%s\n' "$STORE_CANARY" > "$TMP/incomplete.properties"
if (cd "$ROOT/flutter_app/android" && SIMPASTIL_SIGNING_PROPERTIES="$TMP/incomplete.properties" SIMPASTIL_KEY_PASSWORD="$KEY_CANARY" gradle --no-daemon --console=plain :app:assembleRelease --dry-run) >"$TMP/incomplete.log" 2>&1; then
  fail 'assembleRelease accepted incomplete signing inputs'
fi
grep -Fq 'Release signing is required' "$TMP/incomplete.log" || fail 'incomplete signing did not fail with the safe diagnostic'
if grep -Fq "$STORE_CANARY" "$TMP/missing.log" "$TMP/incomplete.log" || grep -Fq "$KEY_CANARY" "$TMP/missing.log" "$TMP/incomplete.log"; then
  fail 'a signing password appeared in Gradle output'
fi

if grep -Eq 'signingConfig[[:space:]]*=[[:space:]]*signingConfigs\.getByName\("debug"\)' "$ROOT/flutter_app/android/app/build.gradle.kts"; then
  fail 'release build type falls back to the debug signing key'
fi

"$ROOT/scripts/acceptance/android-release.sh" "$TMP/release" > "$TMP/acceptance.log" 2>&1 || {
  tail -n 80 "$TMP/acceptance.log" >&2
  fail 'disposable non-debug release acceptance failed'
}
MANIFEST="$TMP/release/release-manifest.json"
APK="$TMP/release/app-release.apk"
[[ -s "$MANIFEST" && -s "$APK" ]] || fail 'acceptance APK or manifest is missing'
EXPECTED_FINGERPRINT="$(node -p "require('$MANIFEST').signing.certificateSha256")"

if SIMPASTIL_EXPECTED_CERT_SHA256="$(printf '0%.0s' {1..64})" "$ROOT/scripts/verify-android-signer.sh" "$APK" >"$TMP/wrong.log" 2>&1; then
  fail 'wrong expected signing fingerprint was accepted'
fi
grep -Fq 'certificate fingerprint does not match' "$TMP/wrong.log" || fail 'wrong fingerprint did not produce the expected diagnostic'

for tool in keytool od; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for the debug signer fixture"; done
ANDROID_TOOLCHAIN="$(cd "$ROOT/flutter_app/android" && gradle --no-daemon --console=plain --quiet :app:printSimpastilToolchain)"
COMPILE_SDK="$(printf '%s\n' "$ANDROID_TOOLCHAIN" | sed -nE 's/^SIMPASTIL_ANDROID_COMPILE_SDK=([0-9]+)$/\1/p' | head -n 1)"
BUILD_TOOLS="$(printf '%s\n' "$ANDROID_TOOLCHAIN" | sed -nE 's/^SIMPASTIL_ANDROID_BUILD_TOOLS=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[[ -n "$COMPILE_SDK" && -n "$BUILD_TOOLS" && -n "$SDK_ROOT" ]] || fail 'resolved Android SDK toolchain is required'
AAPT="${AAPT:-$SDK_ROOT/build-tools/$BUILD_TOOLS/aapt}"
ANDROID_JAR="$SDK_ROOT/platforms/android-$COMPILE_SDK/android.jar"
[[ -x "$AAPT" && -s "$ANDROID_JAR" ]] || fail 'matching aapt and Android platform are required'
APKSIGNER="${APKSIGNER:-$(command -v apksigner || true)}"
if [[ -z "$APKSIGNER" && -n "$SDK_ROOT" ]]; then
  APKSIGNER="$(find "$SDK_ROOT/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner -print 2>/dev/null | sort -V | tail -n 1)"
fi
[[ -x "$APKSIGNER" ]] || fail 'Android build-tools apksigner is required'
export SIMPASTIL_DEBUG_FIXTURE_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
keytool -genkeypair -noprompt -storetype PKCS12 -keystore "$TMP/debug-signer.p12" \
  -storepass:env SIMPASTIL_DEBUG_FIXTURE_PASSWORD -keypass:env SIMPASTIL_DEBUG_FIXTURE_PASSWORD \
  -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 3650 \
  -dname 'CN=Android Debug,O=Android,C=US' >"$TMP/debug-keytool.log" 2>&1 || fail 'debug signer fixture could not be created'
mkdir -p "$TMP/debug-apk"
APP_VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*$/\1/p' "$ROOT/flutter_app/pubspec.yaml" | head -n 1)"
APP_BUILD="${APP_VERSION##*+}"
APP_VERSION="${APP_VERSION%%+*}"
APP_ID="$(sed -nE 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$ROOT/flutter_app/android/app/build.gradle.kts" | head -n 1)"
printf '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="%s" android:versionCode="%s" android:versionName="%s"><uses-sdk android:minSdkVersion="21" android:targetSdkVersion="%s"/><application android:label="fixture" android:hasCode="false"/></manifest>\n' \
  "$APP_ID" "$APP_BUILD" "$APP_VERSION" "$COMPILE_SDK" > "$TMP/debug-apk/AndroidManifest.xml"
"$AAPT" package -f -M "$TMP/debug-apk/AndroidManifest.xml" -I "$ANDROID_JAR" -F "$TMP/debug-unsigned.apk" >/dev/null 2>&1 || fail 'debug APK fixture could not be packaged'
SIMPASTIL_DEBUG_FIXTURE_PASSWORD="$SIMPASTIL_DEBUG_FIXTURE_PASSWORD" \
  "$APKSIGNER" sign --min-sdk-version 21 --ks "$TMP/debug-signer.p12" \
  --ks-key-alias androiddebugkey --ks-pass env:SIMPASTIL_DEBUG_FIXTURE_PASSWORD \
  --key-pass env:SIMPASTIL_DEBUG_FIXTURE_PASSWORD --out "$TMP/debug.apk" \
  "$TMP/debug-unsigned.apk" >"$TMP/debug-sign.log" 2>&1 || fail 'debug APK fixture could not be signed'
unset SIMPASTIL_DEBUG_FIXTURE_PASSWORD
DEBUG_APK="$TMP/debug.apk"
if SIMPASTIL_EXPECTED_CERT_SHA256="$EXPECTED_FINGERPRINT" "$ROOT/scripts/verify-android-signer.sh" "$DEBUG_APK" >"$TMP/debug.log" 2>&1; then
  fail 'debug-signed APK was accepted as a release artifact'
fi
grep -Fq 'debug signing certificate is not permitted' "$TMP/debug.log" || fail 'debug signer did not produce the expected diagnostic'

if grep -Fq "$STORE_CANARY" "$MANIFEST" "$TMP/acceptance.log" || grep -Fq "$KEY_CANARY" "$MANIFEST" "$TMP/acceptance.log"; then
  fail 'a signing password appeared in release output'
fi
if git -C "$ROOT" status --porcelain | grep -E 'signing\.properties|\.(jks|p12|keystore)([[:space:]]|$)' >/dev/null; then
  fail 'temporary signing material entered repository status'
fi

printf 'PASS: release signing is fail-closed and signer verification rejects debug/wrong identities\n'
