#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'usage: build-release-manifest.sh SIGNED_APK OUTPUT_DIR'
apk="$1"
output="$2"
[[ -s "$apk" ]] || fail 'signed APK is missing or empty'
[[ "$output" == /* && "$output" != / ]] || fail 'output directory must be an explicit absolute non-root path'
output="$(realpath -m "$output")"
case "$output/" in "$ROOT/"*) fail 'release output must be outside the repository';; esac
for artifact in app-release.apk app-release.apk.sha256 dependency-inventory.json dependency-inventory.json.sha256 release-manifest.json release-manifest.json.sha256; do
  [[ ! -e "$output/$artifact" ]] || fail "refusing to overwrite existing output: $artifact"
done

manifest_class="${SIMPASTIL_MANIFEST_CLASS:-production-release}"
[[ "$manifest_class" == production-release || "$manifest_class" == acceptance-only ]] || fail 'unsupported manifest class'
if [[ "$manifest_class" == production-release ]]; then
  [[ -n "${SIMPASTIL_WORKFLOW_ACTIONS_JSON:-}" ]] || fail 'workflow action refs are required'
  [[ -n "${SIMPASTIL_JOB_IMAGE_DIGESTS_JSON:-}" ]] || fail 'job image digests are required'
  [[ -n "${SIMPASTIL_SERVER_IMAGE_DIGESTS_JSON:-}" ]] || fail 'server image digests are required'
  [[ -n "${SIMPASTIL_SERVER_IMAGE_METADATA_JSON:-}" ]] || fail 'server image profile metadata is required'
  [[ -n "${SIMPASTIL_TEST_EVIDENCE_JSON:-}" ]] || fail 'test evidence references are required'
  [[ "${SIMPASTIL_ARTIFACT_RETENTION_DAYS:-}" =~ ^[0-9]+$ ]] || fail 'release artifact retention days are required'
  (( SIMPASTIL_ARTIFACT_RETENTION_DAYS >= 365 )) || fail 'production release artifacts and images must be retained for at least 365 days'
fi
mkdir -p "$output"
apk="$(realpath "$apk")"
flutter_project="${SIMPASTIL_FLUTTER_PROJECT_ROOT:-$ROOT/flutter_app}"
android_project="${SIMPASTIL_ANDROID_PROJECT_ROOT:-$flutter_project/android}"
command -v gradle >/dev/null 2>&1 || fail 'the pinned Gradle CLI is required'
scratch="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-release-manifest.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
"$ROOT/scripts/verify-android-signer.sh" "$apk" > "$scratch/signer.txt"
certificate_fingerprint="$(sed -nE 's/^certificate_sha256=([A-F0-9]{64})$/\1/p' "$scratch/signer.txt")"
[[ -n "$certificate_fingerprint" ]] || fail 'verified signing fingerprint is unavailable'

flutter_dependencies="${SIMPASTIL_FLUTTER_DEPENDENCIES_JSON:-}"
if [[ -n "$flutter_dependencies" ]]; then
  [[ -s "$flutter_dependencies" ]] || fail 'provided Flutter dependency graph is missing'
  cp "$flutter_dependencies" "$scratch/flutter-dependencies.json"
else
  (cd "$flutter_project" && flutter pub deps --json) > "$scratch/flutter-dependencies.json"
fi
android_dependencies="${SIMPASTIL_ANDROID_DEPENDENCIES_REPORT:-}"
if [[ -n "$android_dependencies" ]]; then
  [[ -s "$android_dependencies" ]] || fail 'provided Android dependency report is missing'
  cp "$android_dependencies" "$scratch/android-dependencies.txt"
else
  (cd "$android_project" && gradle --no-daemon --console=plain --quiet :app:dependencies --configuration releaseRuntimeClasspath) > "$scratch/android-dependencies.txt"
fi

flutter_info="$(cd "$flutter_project" && flutter --version --machine)"
flutter_pin="$(sed -nE 's/^[[:space:]]*"flutter":[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*$/\1/p' "$ROOT/.fvmrc")"
gradle_pin="$(sed -nE 's/^distributionUrl=.*gradle-([0-9]+\.[0-9]+\.[0-9]+)-all\.zip$/\1/p' "$ROOT/flutter_app/android/gradle/wrapper/gradle-wrapper.properties")"
gradle_sha="$(sed -nE 's/^distributionSha256Sum=([a-f0-9]{64})$/\1/p' "$ROOT/flutter_app/android/gradle/wrapper/gradle-wrapper.properties")"
gradle_output="$(gradle --no-daemon --console=plain --version)"
gradle_actual="$(printf '%s\n' "$gradle_output" | sed -nE 's/^Gradle ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)"
java_version="$(java -version 2>&1 | sed -nE '1s/.*version \"([^\"]+)\".*/\1/p')"
[[ -n "$flutter_pin" && -n "$gradle_pin" && -n "$gradle_sha" && "$gradle_pin" == "$gradle_actual" && "$java_version" == 21.0.9 ]] || fail 'installed Flutter/Java/Gradle toolchains do not match recorded inputs'
android_toolchain="$(cd "$android_project" && gradle --no-daemon --console=plain --quiet :app:printSimpastilToolchain)"
android_compile_sdk="$(printf '%s\n' "$android_toolchain" | sed -nE 's/^SIMPASTIL_ANDROID_COMPILE_SDK=([0-9]+)$/\1/p' | head -n 1)"
android_build_tools="$(printf '%s\n' "$android_toolchain" | sed -nE 's/^SIMPASTIL_ANDROID_BUILD_TOOLS=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)"
android_ndk="$(printf '%s\n' "$android_toolchain" | sed -nE 's/^SIMPASTIL_ANDROID_NDK=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)"
[[ -n "$android_compile_sdk" && -n "$android_build_tools" && -n "$android_ndk" ]] || fail 'resolved Android SDK/Build Tools/NDK versions are unavailable'
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[[ -n "$sdk_root" ]] || fail 'Android SDK root is required to inspect the APK manifest'
aapt="${AAPT:-$sdk_root/build-tools/$android_build_tools/aapt}"
[[ -x "$aapt" ]] || fail 'matching Android build-tools aapt is required'

app_version="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*$/\1/p' "$ROOT/flutter_app/pubspec.yaml" | head -n 1)"
[[ "$app_version" == *+* ]] || fail 'pubspec.yaml version must include a build number'
app_build="${app_version##*+}"
app_semver="${app_version%%+*}"
app_id="$(sed -nE 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$ROOT/flutter_app/android/app/build.gradle.kts" | head -n 1)"
apk_metadata="$("$aapt" dump badging "$apk")" || fail 'aapt could not inspect the signed APK manifest'
apk_id="$(printf '%s\n' "$apk_metadata" | sed -nE "s/^package: name='([^']+)'.*/\1/p" | head -n 1)"
apk_build="$(printf '%s\n' "$apk_metadata" | sed -nE "s/^package:.*versionCode='([^']+)'.*/\1/p" | head -n 1)"
apk_version="$(printf '%s\n' "$apk_metadata" | sed -nE "s/^package:.*versionName='([^']*)'.*/\1/p" | head -n 1)"
[[ -n "$app_id" && "$apk_id" == "$app_id" && "$apk_build" == "$app_build" && "$apk_version" == "$app_semver" ]] || fail 'signed APK package/version does not match the checked-out release source'
source_commit="$(git -C "$ROOT" rev-parse HEAD)"
migration_head="$(find "$ROOT/server/src/db/migrations" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' -print | sort | tail -n 1 | xargs -r basename)"
[[ -n "$migration_head" ]] || fail 'server migration head cannot be determined'

export SIMPASTIL_MANIFEST_CLASS="$manifest_class"
export SIMPASTIL_MANIFEST_OUTPUT="$output"
export SIMPASTIL_MANIFEST_SOURCE_COMMIT="$source_commit"
export SIMPASTIL_MANIFEST_APP_VERSION="$app_semver"
export SIMPASTIL_MANIFEST_APP_BUILD="$app_build"
export SIMPASTIL_MANIFEST_APPLICATION_ID="$app_id"
export SIMPASTIL_MANIFEST_FLUTTER_PIN="$flutter_pin"
export SIMPASTIL_MANIFEST_FLUTTER_INFO="$flutter_info"
export SIMPASTIL_MANIFEST_JAVA_VERSION="$java_version"
export SIMPASTIL_MANIFEST_GRADLE_VERSION="$gradle_pin"
export SIMPASTIL_MANIFEST_GRADLE_SHA="$gradle_sha"
export SIMPASTIL_MANIFEST_COMPILE_SDK="$android_compile_sdk"
export SIMPASTIL_MANIFEST_BUILD_TOOLS="$android_build_tools"
export SIMPASTIL_MANIFEST_NDK="$android_ndk"
export SIMPASTIL_MANIFEST_MIGRATION_HEAD="$migration_head"
export SIMPASTIL_MANIFEST_SIGNER="$certificate_fingerprint"
export SIMPASTIL_MANIFEST_APK="$apk"
export SIMPASTIL_MANIFEST_FLUTTER_DEPS="$scratch/flutter-dependencies.json"
export SIMPASTIL_MANIFEST_ANDROID_DEPS="$scratch/android-dependencies.txt"
rollout_evidence="${SIMPASTIL_ROLLOUT_EVIDENCE_JSON:-}"
[[ -n "$rollout_evidence" ]] || rollout_evidence='{}'
export SIMPASTIL_MANIFEST_ROLLOUT_EVIDENCE="$rollout_evidence"
export SIMPASTIL_MANIFEST_SERVER_IMAGE_METADATA="${SIMPASTIL_SERVER_IMAGE_METADATA_JSON:-}"
export SIMPASTIL_MANIFEST_ARTIFACT_RETENTION_DAYS="${SIMPASTIL_ARTIFACT_RETENTION_DAYS:-0}"

node <<'NODE'
'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const fail = message => { process.stderr.write('FAIL: ' + message + '\n'); process.exit(1); };
const env = name => process.env[name] || '';
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const objectJson = (name, required) => {
  const raw = env(name);
  if (!raw && !required) return {};
  if (!raw) fail(name + ' is required');
  let value;
  try { value = JSON.parse(raw); } catch { fail(name + ' must be valid JSON'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(name + ' must be a JSON object');
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]]));
};
const lockFiles = {
  flutterPubspec: path.join(process.env.ROOT, 'flutter_app/pubspec.lock'),
  serverNpm: path.join(process.env.ROOT, 'server/package-lock.json'),
  adminNpm: path.join(process.env.ROOT, 'server/admin/package-lock.json'),
};
const lockChecksums = {};
for (const [name, file] of Object.entries(lockFiles)) {
  if (!fs.existsSync(file)) fail('required dependency lock is missing: ' + name);
  lockChecksums[name] = sha256(file);
}
lockChecksums.gradleWrapperDistribution = process.env.SIMPASTIL_MANIFEST_GRADLE_SHA;
if (!/^[a-f0-9]{64}$/.test(lockChecksums.gradleWrapperDistribution)) fail('Gradle distribution checksum is missing or malformed');
const manifestClass = env('SIMPASTIL_MANIFEST_CLASS');
const production = manifestClass === 'production-release';
const workflowActionRefs = objectJson('SIMPASTIL_WORKFLOW_ACTIONS_JSON', production);
const jobImageDigests = objectJson('SIMPASTIL_JOB_IMAGE_DIGESTS_JSON', production);
const serverImageDigests = objectJson('SIMPASTIL_SERVER_IMAGE_DIGESTS_JSON', production);
const serverImages = objectJson('SIMPASTIL_MANIFEST_SERVER_IMAGE_METADATA', production);
const testEvidence = objectJson('SIMPASTIL_TEST_EVIDENCE_JSON', production);
const assertValues = (object, name, predicate) => {
  if (production && Object.keys(object).length === 0) fail(name + ' cannot be empty');
  for (const [key, value] of Object.entries(object)) {
    if (typeof value !== 'string' || !predicate(value)) fail(name + '.' + key + ' is not an immutable reference');
  }
};
assertValues(workflowActionRefs, 'workflow action refs', value => /@[a-f0-9]{40}$/i.test(value));
assertValues(jobImageDigests, 'job image digests', value => /@sha256:[a-f0-9]{64}$/i.test(value));
assertValues(serverImageDigests, 'server image digests', value => /^(?:.+@)?sha256:[a-f0-9]{64}$/i.test(value));
if (production && Object.keys(testEvidence).length === 0) fail('test evidence references cannot be empty');
for (const [key, value] of Object.entries(testEvidence)) {
  if (typeof value !== 'string' || value.trim() === '') fail('test evidence reference ' + key + ' is invalid');
}
let rollout;
try { rollout = JSON.parse(env('SIMPASTIL_MANIFEST_ROLLOUT_EVIDENCE') || '{}'); }
catch { fail('rollout evidence must be valid JSON'); }
if (!rollout || typeof rollout !== 'object' || Array.isArray(rollout)) fail('rollout evidence must be a JSON object');
if (Object.keys(rollout).length > 0 &&
    (!Number.isInteger(rollout.enforcedMinimumClientBuild) || typeof rollout.reference !== 'string' || !rollout.reference)) {
  fail('rollout evidence must separately identify the observed enforced minimum and its evidence reference');
}
const flutterInfo = JSON.parse(env('SIMPASTIL_MANIFEST_FLUTTER_INFO'));
if (flutterInfo.flutterVersion !== env('SIMPASTIL_MANIFEST_FLUTTER_PIN')) fail('installed Flutter SDK differs from .fvmrc');
if (!flutterInfo.dartSdkVersion) fail('installed Dart SDK version is unavailable');
const sourceCommit = env('SIMPASTIL_MANIFEST_SOURCE_COMMIT');
if (!/^[a-f0-9]{40}$/i.test(sourceCommit)) fail('source commit must be a full Git SHA');
const migrationHead = env('SIMPASTIL_MANIFEST_MIGRATION_HEAD');
if (!/^[0-9]{4}_[a-z0-9_-]+\.sql$/.test(migrationHead)) fail('migration head is malformed');
const serverDockerfile = fs.readFileSync(path.join(process.env.ROOT, 'server/Dockerfile'), 'utf8');
const schemaRanges = [...serverDockerfile.matchAll(/io\.simpastil\.compatible-schema-range="([0-9]{4}\.\.[0-9]{4})"/g)]
  .map(match => match[1]);
if (schemaRanges.length < 2 || new Set(schemaRanges).size !== 1) fail('production and compatibility server schema ranges must be present and identical');
const expectedSchemaRange = schemaRanges[0];
const imageProfiles = ['production', 'compatibility'];
if (production && (!imageProfiles.every(profile => Object.hasOwn(serverImages, profile)) ||
    Object.keys(serverImages).length !== imageProfiles.length)) fail('both production and compatibility server image profiles are required');
for (const profile of Object.keys(serverImages)) {
  const image = serverImages[profile];
  if (!image || typeof image !== 'object' || Array.isArray(image)) fail('server image metadata must be an object');
  if (image.profile !== profile) fail('server image profile label does not match its manifest key');
  if (image.sourceCommit !== sourceCommit) fail('server image and APK must share the same source commit');
  if (image.schemaRange !== expectedSchemaRange) fail('server image schema range differs from the checked Docker build profile');
  if (typeof image.digest !== 'string' || !/^sha256:[a-f0-9]{64}$/.test(image.digest)) fail('server image digest is malformed');
  if (typeof image.reference !== 'string' || !image.reference.endsWith('@' + image.digest)) fail('server image reference must be digest-addressed');
  const provenanceDigest = serverImageDigests[profile];
  if (typeof provenanceDigest !== 'string' || !(provenanceDigest === image.digest || provenanceDigest.endsWith('@' + image.digest))) {
    fail('server image profile digest differs from the release provenance digest');
  }
}
const retentionDays = Number(env('SIMPASTIL_MANIFEST_ARTIFACT_RETENTION_DAYS'));
if (production && (!Number.isInteger(retentionDays) || retentionDays < 365)) fail('production artifact retention must be at least 365 days');
const appVersion = env('SIMPASTIL_MANIFEST_APP_VERSION');
const appBuild = env('SIMPASTIL_MANIFEST_APP_BUILD');
if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(appVersion) || !/^[0-9]+$/.test(appBuild)) fail('app version/build is malformed');
if (production && Number(appBuild) < 2) fail('production release APK build number must be at least the target build 2');
const compileSdk = Number(env('SIMPASTIL_MANIFEST_COMPILE_SDK'));
if (!Number.isInteger(compileSdk) || compileSdk < 1) fail('Android compile SDK must be an exact integer');
for (const [name, value] of [['Android Build Tools', env('SIMPASTIL_MANIFEST_BUILD_TOOLS')], ['Android NDK', env('SIMPASTIL_MANIFEST_NDK')]]) {
  if (!/^[0-9]+(?:\.[0-9]+){1,3}$/.test(value)) fail(name + ' version is missing or malformed');
}
const flutterGraph = readJson(env('SIMPASTIL_MANIFEST_FLUTTER_DEPS'));
const androidReport = fs.readFileSync(env('SIMPASTIL_MANIFEST_ANDROID_DEPS'), 'utf8').replace(/\r\n/g, '\n').trimEnd().split('\n');
const inventory = {
  format: 'simpastil-dependency-inventory/v1',
  sourceCommit,
  lockChecksums,
  flutterPackageGraph: flutterGraph,
  androidReleaseRuntimeClasspath: androidReport,
};
const output = env('SIMPASTIL_MANIFEST_OUTPUT');
const inventoryPath = path.join(output, 'dependency-inventory.json');
fs.writeFileSync(inventoryPath, JSON.stringify(inventory, null, 2) + '\n', { mode: 0o600 });
const apkOutput = path.join(output, 'app-release.apk');
fs.copyFileSync(env('SIMPASTIL_MANIFEST_APK'), apkOutput);
fs.chmodSync(apkOutput, 0o600);
const artifact = {
  apk: { file: 'app-release.apk', sha256: sha256(apkOutput) },
  dependencyInventory: { file: 'dependency-inventory.json', format: inventory.format, sha256: sha256(inventoryPath) },
};
fs.writeFileSync(path.join(output, 'app-release.apk.sha256'), artifact.apk.sha256 + '  app-release.apk\n', { mode: 0o600 });
fs.writeFileSync(path.join(output, 'dependency-inventory.json.sha256'), artifact.dependencyInventory.sha256 + '  dependency-inventory.json\n', { mode: 0o600 });
const manifest = {
  schemaVersion: 1,
  artifactClass: manifestClass,
  source: { commit: env('SIMPASTIL_MANIFEST_SOURCE_COMMIT'), applicationId: env('SIMPASTIL_MANIFEST_APPLICATION_ID'), appVersion, appBuild },
  targetMinimumClientBuild: 2,
  toolchains: {
    flutter: env('SIMPASTIL_MANIFEST_FLUTTER_PIN'),
    dart: flutterInfo.dartSdkVersion,
    java: env('SIMPASTIL_MANIFEST_JAVA_VERSION'),
    gradle: env('SIMPASTIL_MANIFEST_GRADLE_VERSION'),
    android: { compileSdk, buildTools: env('SIMPASTIL_MANIFEST_BUILD_TOOLS'), ndk: env('SIMPASTIL_MANIFEST_NDK') },
  },
  lockChecksums,
  signing: { certificateSha256: env('SIMPASTIL_MANIFEST_SIGNER') },
  artifacts: artifact,
  artifactRetention: {
    minimumDays: production ? retentionDays : 0,
    policy: production ? 'retain APK, dependency inventory, manifest, and server image digests for at least the minimum period' : 'acceptance-only disposable output',
  },
  provenance: {
    workflowActionRefs,
    jobImageDigests,
    serverImageDigests,
    serverImages,
    migrationHead,
    testEvidence,
  },
  rolloutEvidence: rollout,
};
fs.writeFileSync(path.join(output, 'release-manifest.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o600 });
process.stdout.write('release_manifest=' + path.join(output, 'release-manifest.json') + '\n');
process.stdout.write('apk_sha256=' + artifact.apk.sha256 + '\n');
process.stdout.write('dependency_inventory_sha256=' + artifact.dependencyInventory.sha256 + '\n');
process.stdout.write('signing_certificate_sha256=' + manifest.signing.certificateSha256 + '\n');
NODE

(cd "$output" && sha256sum release-manifest.json > release-manifest.json.sha256)
