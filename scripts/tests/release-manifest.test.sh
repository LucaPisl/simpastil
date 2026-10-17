#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-release-manifest.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for tool in keytool sha256sum od node flutter gradle; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
(cd "$ROOT/flutter_app" && flutter pub get --enforce-lockfile) > "$TMP/pub-get.log" 2>&1 || fail 'tracked Flutter lock could not be resolved'
ANDROID_TOOLCHAIN="$(cd "$ROOT/flutter_app/android" && gradle --no-daemon --console=plain --quiet :app:printSimpastilToolchain)"
COMPILE_SDK="$(printf '%s\n' "$ANDROID_TOOLCHAIN" | sed -nE 's/^SIMPASTIL_ANDROID_COMPILE_SDK=([0-9]+)$/\1/p' | head -n 1)"
BUILD_TOOLS="$(printf '%s\n' "$ANDROID_TOOLCHAIN" | sed -nE 's/^SIMPASTIL_ANDROID_BUILD_TOOLS=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[[ -n "$COMPILE_SDK" && -n "$BUILD_TOOLS" && -n "$SDK_ROOT" ]] || fail 'resolved Android SDK toolchain is required'
AAPT="${AAPT:-$SDK_ROOT/build-tools/$BUILD_TOOLS/aapt}"
ANDROID_JAR="$SDK_ROOT/platforms/android-$COMPILE_SDK/android.jar"
[[ -x "$AAPT" && -s "$ANDROID_JAR" ]] || fail 'matching aapt and Android platform are required'

FIXTURE_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
export SIMPASTIL_MANIFEST_FIXTURE_PASSWORD="$FIXTURE_PASSWORD"
KEYSTORE="$TMP/test-signing.p12"
keytool -genkeypair -noprompt -storetype PKCS12 -keystore "$KEYSTORE" \
  -storepass:env SIMPASTIL_MANIFEST_FIXTURE_PASSWORD \
  -keypass:env SIMPASTIL_MANIFEST_FIXTURE_PASSWORD -alias manifest-fixture \
  -keyalg RSA -keysize 2048 -validity 3650 \
  -dname 'CN=Simpastil Disposable Manifest Test,O=Simpastil,C=RO' >/dev/null 2>&1 ||
  fail 'disposable signer fixture could not be created'
keytool -exportcert -keystore "$KEYSTORE" -storepass:env SIMPASTIL_MANIFEST_FIXTURE_PASSWORD \
  -alias manifest-fixture -file "$TMP/certificate.der" >/dev/null 2>&1 || fail 'test certificate could not be exported'

mkdir -p "$TMP/apk" "$TMP/fixtures"
APP_VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*$/\1/p' "$ROOT/flutter_app/pubspec.yaml" | head -n 1)"
APP_BUILD="${APP_VERSION##*+}"
APP_VERSION="${APP_VERSION%%+*}"
APP_ID="$(sed -nE 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$ROOT/flutter_app/android/app/build.gradle.kts" | head -n 1)"
printf '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="%s" android:versionCode="%s" android:versionName="%s"><uses-sdk android:minSdkVersion="21" android:targetSdkVersion="%s"/><application android:label="fixture" android:hasCode="false"/></manifest>\n' \
  "$APP_ID" "$APP_BUILD" "$APP_VERSION" "$COMPILE_SDK" > "$TMP/apk/AndroidManifest.xml"
"$AAPT" package -f -M "$TMP/apk/AndroidManifest.xml" -I "$ANDROID_JAR" -F "$TMP/unsigned.apk" >/dev/null 2>&1 || fail 'minimal APK fixture could not be packaged'
APKSIGNER="${APKSIGNER:-$(command -v apksigner || true)}"
if [[ -z "$APKSIGNER" ]]; then
  SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  [[ -n "$SDK_ROOT" ]] || fail 'ANDROID_SDK_ROOT or ANDROID_HOME is required'
  APKSIGNER="$(find "$SDK_ROOT/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner -print 2>/dev/null | sort -V | tail -n 1)"
fi
[[ -x "$APKSIGNER" ]] || fail 'apksigner is required'
"$APKSIGNER" sign --min-sdk-version 21 --ks "$KEYSTORE" --ks-key-alias manifest-fixture \
  --ks-pass env:SIMPASTIL_MANIFEST_FIXTURE_PASSWORD \
  --key-pass env:SIMPASTIL_MANIFEST_FIXTURE_PASSWORD \
  --out "$TMP/app-release.apk" "$TMP/unsigned.apk" >/dev/null 2>&1 || fail 'fixture APK could not be signed'
unset SIMPASTIL_MANIFEST_FIXTURE_PASSWORD

printf '{"packages":[{"name":"fixture","version":"1.0.0"}]}\n' > "$TMP/fixtures/flutter-deps.json"
printf ':app:releaseRuntimeClasspath\n+--- com.example:fixture:1.0\n' > "$TMP/fixtures/android-deps.txt"
export SIMPASTIL_EXPECTED_CERT_SHA256="$(sha256sum "$TMP/certificate.der" | cut -d ' ' -f 1)"
if "$ROOT/scripts/verify-android-signer.sh" "$TMP/unsigned.apk" >"$TMP/unsigned-verification.log" 2>&1; then
  fail 'unsigned APK fixture passed signer verification'
fi
grep -Fq 'apksigner rejected the APK' "$TMP/unsigned-verification.log" || fail 'unsigned APK failed without the expected diagnostic'
export SIMPASTIL_WORKFLOW_ACTIONS_JSON='{"actions/checkout":"actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
export SIMPASTIL_JOB_IMAGE_DIGESTS_JSON='{"node":"docker.io/library/node:22.23.2-bookworm@sha256:8a34c4ab3ea2c5cd194f07e317b2a8f09461d3c8b05c4e34c8ccd56d56024c4d","flutter":"ghcr.io/cirruslabs/flutter:3.41.5@sha256:5120236042c0a04d831c69fc41f0d56462d145d3b0078fdd07b50d655bbec985","docker":"docker.io/library/docker:29.7.2-cli@sha256:3f4743208d2338c934d7b8bcfbe1bb54c0b2355c510ad5e0f31c0c4a54bd704e"}'
export SIMPASTIL_SERVER_IMAGE_DIGESTS_JSON='{"production":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","compatibility":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SCHEMA_RANGE="$(sed -nE 's/.*io\.simpastil\.compatible-schema-range="([0-9.]+)".*/\1/p' "$ROOT/server/Dockerfile" | head -n 1)"
export SIMPASTIL_SERVER_IMAGE_METADATA_JSON="$(printf '{\"production\":{\"reference\":\"registry.example.invalid/simpastil/simpastil-server:v1.0.0-production@sha256:%s\",\"digest\":\"sha256:%s\",\"profile\":\"production\",\"schemaRange\":\"%s\",\"sourceCommit\":\"%s\"},\"compatibility\":{\"reference\":\"registry.example.invalid/simpastil/simpastil-server:v1.0.0-compatibility@sha256:%s\",\"digest\":\"sha256:%s\",\"profile\":\"compatibility\",\"schemaRange\":\"%s\",\"sourceCommit\":\"%s\"}}' \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "$SCHEMA_RANGE" "$SOURCE_COMMIT" \
  cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  "$SCHEMA_RANGE" "$SOURCE_COMMIT")"
export SIMPASTIL_ARTIFACT_RETENTION_DAYS=365
export SIMPASTIL_TEST_EVIDENCE_JSON='{"release-signing":"scripts/tests/android-signing-policy.test.sh","manifest":"scripts/tests/release-manifest.test.sh"}'
export SIMPASTIL_ROLLOUT_EVIDENCE_JSON='{"enforcedMinimumClientBuild":1,"reference":"fixture:rollout-evidence"}'
export SIMPASTIL_FLUTTER_DEPENDENCIES_JSON="$TMP/fixtures/flutter-deps.json"
export SIMPASTIL_ANDROID_DEPENDENCIES_REPORT="$TMP/fixtures/android-deps.txt"

if SIMPASTIL_WORKFLOW_ACTIONS_JSON= "$ROOT/scripts/build-release-manifest.sh" "$TMP/app-release.apk" "$TMP/missing" >"$TMP/missing.log" 2>&1; then
  fail 'manifest accepted missing workflow action provenance'
fi
grep -Fq 'workflow action refs are required' "$TMP/missing.log" || fail 'missing provenance had no safe diagnostic'

"$ROOT/scripts/build-release-manifest.sh" "$TMP/app-release.apk" "$TMP/output-one" >/dev/null
"$ROOT/scripts/build-release-manifest.sh" "$TMP/app-release.apk" "$TMP/output-two" >/dev/null
cmp -s "$TMP/output-one/release-manifest.json" "$TMP/output-two/release-manifest.json" || fail 'manifest output is not deterministic'

node - "$TMP/output-one/release-manifest.json" "$TMP/output-one/app-release.apk" <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const apk = fs.readFileSync(process.argv[3]);
if (manifest.targetMinimumClientBuild !== 2) throw new Error('immutable target build is not 2');
if (!/^[0-9]+$/.test(manifest.source.appBuild) || Number(manifest.source.appBuild) < manifest.targetMinimumClientBuild) throw new Error('APK build number is below the target build 2');
if (!/^[A-F0-9]{64}$/.test(manifest.signing.certificateSha256)) throw new Error('signing fingerprint is malformed');
if (manifest.artifacts.apk.sha256 !== crypto.createHash('sha256').update(apk).digest('hex')) throw new Error('APK checksum does not match');
if (!manifest.artifacts.dependencyInventory.sha256 || !manifest.lockChecksums.flutterPubspec) throw new Error('inventory or lock checksum is missing');
if (manifest.artifactRetention.minimumDays < 365) throw new Error('release retention window is missing or too short');
if (!manifest.provenance.serverImages.production || !manifest.provenance.serverImages.compatibility) throw new Error('server image profile provenance is incomplete');
if (!fs.existsSync(process.argv[2] + '.sha256')) throw new Error('release manifest checksum is missing');
if (!manifest.provenance.workflowActionRefs || !manifest.provenance.jobImageDigests || !manifest.provenance.serverImageDigests || !manifest.provenance.testEvidence || !manifest.provenance.migrationHead) throw new Error('release provenance is incomplete');
if (manifest.targetMinimumClientBuild === manifest.rolloutEvidence.enforcedMinimumClientBuild) throw new Error('mutable rollout authority was confused with artifact target');
if (Object.hasOwn(manifest, 'minimumClientBuild')) throw new Error('ambiguous mutable minimum leaked into artifact identity');
NODE

(cd "$TMP/output-one" && sha256sum --check release-manifest.json.sha256 >/dev/null) || fail 'release manifest checksum is not portable'

if grep -Fq "$FIXTURE_PASSWORD" "$TMP/output-one/release-manifest.json"; then
  fail 'signing secret appeared in the manifest'
fi
printf 'PASS: manifest is deterministic and binds APK, signer, locks, dependencies, and release provenance\n'
