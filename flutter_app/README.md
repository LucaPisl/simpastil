# Simpastil Flutter client

This directory contains the offline-first Flutter mobile client. Current
development commands and generated-file invariants are in
[CONTRIBUTING.md](../CONTRIBUTING.md); technical contracts are in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md); release signing and install
behavior are in [docs/RELEASE.md](../docs/RELEASE.md).

## Android release signing

Release APKs require a dedicated release keystore and the matching SHA-256
certificate fingerprint. Release builds never fall back to the Android debug
key. Creating, backing up and configuring that key is described in
[docs/RELEASE.md](../docs/RELEASE.md#the-release-signing-key). Locally, copy
`android/signing.example.properties` next to the keystore, outside the
repository, replace every placeholder and point `SIMPASTIL_SIGNING_PROPERTIES`
at it; the gitignored `android/signing.properties` also works. CI should inject the protected signing file and
expected fingerprint only in the protected release job; validation jobs do not
receive signing secrets.

Use `scripts/acceptance/android-release.sh /absolute/path/to/fresh-output`
to exercise a disposable, non-debug signer. It creates only a temporary test
keystore and labels its output `acceptance-only`; that APK is not a production
release. The production release job must independently verify the APK with
`apksigner`, compare the certificate fingerprint, and publish the checksum,
dependency inventory, and release manifest together. The manifest's immutable
`targetMinimumClientBuild` is 2; any currently enforced deployment minimum is
recorded separately as rollout evidence.

The first production-signed APK is a clean install: uninstall any debug-signed
copy first because its app data cannot carry over to the production signing
identity. Keep an encrypted backup of the production signing identity and
rehearse restoring it; losing that identity prevents future in-place Android
upgrades. Android App Bundles (AABs) are not part of this release flow.

For Flutter framework reference, see the [official Flutter
documentation](https://docs.flutter.dev/). Project-specific setup belongs in
the root contribution guide rather than in this component pointer.
