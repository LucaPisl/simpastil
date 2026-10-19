# Releases, signing and artifact verification

This guide describes how Simpastil releases are tagged, built, signed and
verified.

## How releases are made

Releases are tagged on the default branch. The tag is `v<version>`, where
`<version>` is the `flutter_app/pubspec.yaml` version without the `+build`
suffix. The release workflow builds and signs the Android
APK, builds the server images, and publishes the signed APK, a provenance
manifest and a dependency inventory, each with a checksum, plus one archive
of all of them. The workflow repeats the version and branch checks
immediately before signing. Validation jobs receive no signing or registry
credentials.

## Immutable inputs

Treat tracked lockfiles and toolchain declarations as release inputs: [Flutter SDK pin](../.fvmrc), [Flutter dependency lock](../flutter_app/pubspec.lock), [Gradle version and SHA-256](../flutter_app/android/gradle/wrapper/gradle-wrapper.properties), [server Node engine and lock](../server/package.json), and both npm lockfiles. The current pins include Flutter 3.41.5, Node 24.22.0, Java runtime 21.0.9 (with Android bytecode target 17), and Gradle 8.14.5 with its recorded SHA-256. CI job images and workflow actions are pinned by digest or commit hash; update them only as a reviewed maintenance change.

## Signing and clean install

Release signing fails closed: there is no debug-key fallback. The protected workflow verifies the built APK's non-debug certificate against the separately configured SHA-256 fingerprint and checks package/version metadata against the source checkout. Signing material is exposed only to the APK build step; the publish credential is scoped to the final asset-publish step, and the dedicated package-write credential is limited to OCI image publication.

A release APK cannot be installed over a debug-signed build. Move the data with a portable backup: create a backup, uninstall, install the release APK and restore. Keep the production keystore recoverable through encrypted, access-controlled backup. Loss of that signing identity prevents future in-place Android upgrades.

## The release signing key

Android accepts an update only when it is signed with the same key as the
installed app. The release key is therefore the app's identity for as long as
it exists: every future release must be signed with it, and nobody else may
hold it. Create it once, before the first release, and treat it like the
server's secrets.

### Create it

Create the key on the release operator's own computer, outside any repository
and outside any folder that a sync client (Nextcloud, Dropbox, iCloud) uploads.
`keytool` ships with every JDK:

```sh
install -d -m 0700 ~/simpastil-signing
cd ~/simpastil-signing
keytool -genkeypair -v -storetype PKCS12 \
  -keystore simpastil-release.p12 -alias simpastil-release \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Simpastil"
chmod 0600 simpastil-release.p12
```

`keytool` asks for the password; type it there and never on a command line,
where it would land in the shell history. A PKCS12 keystore has one password,
so the store password and the key password are the same value. Generate a long
random password in a password manager and keep it there. The `-validity` of
10000 days outlives any realistic life of the app; the certificate cannot be
extended later without a key rotation.

Print the certificate fingerprint:

```sh
keytool -list -v -storetype PKCS12 -keystore simpastil-release.p12 \
  -alias simpastil-release | grep 'SHA256:'
```

The fingerprint is public. It is published in
[INSTALL-ANDROID.md](INSTALL-ANDROID.md#verify-the-download) and in each
release manifest so that users can check who signed an APK, and the build
refuses to sign with any other key.

### Back it up

Keep at least two copies of the `.p12` file in different places, for example
as an attachment in the password manager and on an encrypted USB drive kept
offline. The keystore is encrypted with its password, but store the password
separately from the copies anyway. Check a backup by listing it with the
`keytool -list` command above.

- **Lost key:** no new release can update existing installs. Every user has to
  move to a new identity with a portable backup, an uninstall and a reinstall.
- **Leaked key:** whoever holds it can sign APKs that install as updates. Stop
  publishing, announce it, and move users to a new key the same way as for a
  lost key.

### Where it is used

- **Gitea Actions (release builds).** The `signing-preflight` and `release`
  workflows read four repository secrets: `ANDROID_SIGNING_KEYSTORE_B64` (the
  `.p12` file as one line of base64), `ANDROID_SIGNING_KEY_ALIAS`,
  `ANDROID_SIGNING_STORE_PASSWORD` and `ANDROID_SIGNING_KEY_PASSWORD`, plus the
  repository variable `ANDROID_SIGNING_CERT_SHA256`. Add them in the
  repository's Settings, Actions, Secrets and Variables pages, together with
  the variable `SIMPASTIL_DEFAULT_BRANCH` that names the protected release
  branch. Gitea stores secrets encrypted and never shows them again, and only the
  signing steps receive them.
- **GitHub.** GitHub never receives the key. The public repository only hosts
  the release files that the Gitea release workflow built and signed.
- **Local release builds.** Write the five `SIMPASTIL_*` values from
  [`signing.example.properties`](../flutter_app/android/signing.example.properties)
  into a file next to the keystore, `chmod 0600` it, and point the build at it:

  ```sh
  SIMPASTIL_SIGNING_PROPERTIES=$HOME/simpastil-signing/signing.properties \
    flutter build apk --release
  ```

  The build also reads `flutter_app/android/signing.properties`, which is
  gitignored, but a file inside the checkout is copied by any sync client that
  covers the checkout.

Debug and profile builds keep using the Android debug key, so they cannot be
installed over a release build, and the reverse is also true.

## Release files, provenance, and verification

Each release publishes the signed APK, `release-manifest.json` and `dependency-inventory.json` as separate assets, each with a `.sha256` file, plus `simpastil-<tag>-<run>-<id>.tar.gz` and its `.sha256`, which hold the same six files. The update check in the server and the app reads `source.appBuild` from the `release-manifest.json` asset of the latest GitHub release, so that asset is required on every GitHub release; without it, no installation hears about the release. The manifest binds:

- the source commit and the app identity, version and build;
- the signer fingerprint;
- toolchains, dependency locks and immutable job and action inputs;
- test evidence references;
- server image digests and the schema compatibility range;
- rollout evidence and a minimum 365-day retention commitment.

 Its immutable `targetMinimumClientBuild` records the client build this artifact is intended to support; it is distinct from the deployment authority's separately reported, mutable `enforcedMinimumClientBuild` in rollout evidence. The Android inventory format is repository-defined (`simpastil-dependency-inventory/v1`), not SPDX or CycloneDX. Server images include BuildKit SBOMs; the manifest is source-bound provenance with checksums, not a separate DSSE/cosign attestation.

Migration-specific rollout and rollback limits are in [DEPLOYMENT.md](../DEPLOYMENT.md#appendix-medication-ledger-activation).

Before distribution, independently verify every SHA-256 file, the APK package/version, and its signer fingerprint against the reviewed release configuration. Deploy only the image digest recorded in the same manifest. Preserve both production and compatibility server image digests and the release files for at least 365 days, or longer if policy requires it. Rotate compromised or expired registry and signing credentials through the protected operator process; never copy them into the repository or validation jobs.

## Pre-release signing check

Release acceptance uses a disposable non-debug signing identity and labels its
artifacts acceptance-only; that does not prove the real production certificate.
Before the first production publication, test the release flow on a throwaway
repository with disposable signing and registry credentials. Then push a
`preflight-v<app version>` tag for the exact commit intended for release. The
signing-preflight workflow uses the production signing identity to build the
APK and verify its fingerprint, but publishes no APK, server image or release
asset. Only after it passes, push the matching `v<app version>` tag. The
release workflow repeats the fingerprint check and then publishes.

The compatibility image can support rollback only within the supported schema
range. After ledger activation, rollback must never down-migrate, lower the
immutable artifact target, or reopen legacy medication writes. See the
[rollback limits](../DEPLOYMENT.md#appendix-medication-ledger-activation).

## Related documents

- Development and tests: [CONTRIBUTING.md](../CONTRIBUTING.md)
- Operations, backup, restore, upgrade and rollback: [DEPLOYMENT.md](../DEPLOYMENT.md)
- Technical contracts: [ARCHITECTURE.md](ARCHITECTURE.md)
