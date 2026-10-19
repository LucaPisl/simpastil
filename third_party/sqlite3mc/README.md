# SQLite3 Multiple Ciphers (vendored)

The Flutter app opens its encrypted local database with
[SQLite3 Multiple Ciphers](https://github.com/utelle/SQLite3MultipleCiphers)
(SQLite3MC). These two files are compiled from source into the app by the
`sqlite3` package's build hook (`flutter_app/pubspec.yaml`, `hooks` > `user_defines`
> `sqlite3` > `source: source`). Nothing is downloaded at build time.

| Item | Value |
| --- | --- |
| SQLite3 Multiple Ciphers | 2.6.1 |
| SQLite | 3.54.0 |
| Origin | `https://github.com/utelle/SQLite3MultipleCiphers/releases/download/v2.6.1/sqlite3mc-2.6.1-sqlite-3.54.0-amalgamation.zip` |
| Archive SHA-256 | `3f25af603566a23c821d8e581778b5ece2a541d2435776de57b8d845c176815a` |
| Release checksums | `sqlite3mc-2.6.1-SHA256SUMS`, signed keylessly by the upstream release workflow |

It is the release `sqlite3` 3.7.1 expects (its changelog names SQLite3
Multiple Ciphers 2.6.1 and SQLite 3.54.0), compiled by the same hook with the
same default compile-time options. Provenance: the archive's SHA-256 matches the upstream
`sqlite3mc-2.6.1-SHA256SUMS` asset and GitHub's own digest of the asset, and
`cosign verify-blob` accepted that checksum file against its `.sig` and `.pem`
for the identity `https://github.com/utelle/SQLite3MultipleCiphers/` and the
issuer `https://token.actions.githubusercontent.com`. The archive was unpacked
unmodified; only `sqlite3mc_amalgamation.c` and `sqlite3mc_amalgamation.h` are
kept. Their hashes are in `SHA256SUMS`, and `scripts/check-locks-and-digests.sh`
verifies them in CI.

Previous release: 2.5.0 / SQLite 3.53.4 (archive SHA-256
`cd3a598b667dea206b6c5319d4ecb9d687ee40565f9fd2ba280d0c2f93790f58`). The ChaCha20
defaults the app relies on did not change between the two (`kdf_iter` 64007,
`legacy` 0, page size 4096, no plaintext header), and a database written by
2.5.0 (`flutter_app/test/fixtures/encrypted`) opens unchanged.

Licenses: SQLite is in the public domain; SQLite3 Multiple Ciphers is MIT
licensed (see the license text inside `sqlite3mc_amalgamation.c`).

## Updating

Keep the version in step with the `sqlite3` package version in `pubspec.yaml`:

1. Read the SQLite3 Multiple Ciphers version in the new `sqlite3` release's
   `CHANGELOG.md` and download that release's
   `sqlite3mc-<version>-sqlite-<sqlite>-amalgamation.zip` and
   `sqlite3mc-<version>-SHA256SUMS` (with `.sig` and `.pem`) from the
   upstream GitHub release.
2. Verify the archive with `sha256sum --check --ignore-missing` against the
   checksum file, and the checksum file with `cosign verify-blob` (see
   above).
3. Replace the two files, regenerate `SHA256SUMS` (`sha256sum *.c *.h`), and
   update the table above, including the version asserted in
   `flutter_app/test/core/storage/sqlite3mc_build_test.dart`.
4. Run `flutter test test/core/storage`: the committed fixture written by an
   older release must still open, the cipher defaults must be unchanged, and a
   database written by the new build must open again.
