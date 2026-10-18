# SQLite3 Multiple Ciphers (vendored)

The Flutter app opens its encrypted local database with
[SQLite3 Multiple Ciphers](https://github.com/utelle/SQLite3MultipleCiphers)
(SQLite3MC). These two files are compiled from source into the app by the
`sqlite3` package's build hook (`flutter_app/pubspec.yaml`, `hooks` > `user_defines`
> `sqlite3` > `source: source`). Nothing is downloaded at build time.

| Item | Value |
| --- | --- |
| SQLite3 Multiple Ciphers | 2.5.0 |
| SQLite | 3.53.4 |
| Origin | `https://github.com/utelle/SQLite3MultipleCiphers/releases/download/v2.5.0/sqlite3mc-2.5.0-sqlite-3.53.4-amalgamation.zip` |
| Archive SHA-256 | `cd3a598b667dea206b6c5319d4ecb9d687ee40565f9fd2ba280d0c2f93790f58` |

The archive is exactly the one that `sqlite3` 3.5.2 builds its own prebuilt
`libsqlite3mc` from (`tool/download_sqlite.dart` in that release), compiled with
the same hook and the same default compile-time options. The archive was
unpacked unmodified; only `sqlite3mc_amalgamation.c` and
`sqlite3mc_amalgamation.h` are kept. Their hashes are in `SHA256SUMS`, and
`scripts/check-locks-and-digests.sh` verifies them in CI.

Licenses: SQLite is in the public domain; SQLite3 Multiple Ciphers is MIT
licensed (see the license text inside `sqlite3mc_amalgamation.c`).

## Updating

Keep the version in step with the `sqlite3` package version in `pubspec.yaml`:

1. Read `sqliteMultipleCiphersSource` in `tool/download_sqlite.dart` of the new
   `sqlite3` release and download that archive.
2. Replace the two files, regenerate `SHA256SUMS` (`sha256sum *.c *.h`), and
   update the table above.
3. Confirm a database written by the previous release still opens.
