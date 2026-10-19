# Contributing to Simpastil

This repository contains a Flutter mobile client (`flutter_app/`) and a TypeScript/Fastify API (`server/`). The app is offline-first; the server is tenant-isolated with PostgreSQL row-level security. Read the relevant contract page before changing sync, medication, deployment, or release behavior.

Continuous integration runs the full validation on pull requests and on the
default branch. Use the focused local checks below while developing.

## Contribution terms

By submitting a contribution you agree that it is licensed under the
[GNU Affero General Public License v3.0](LICENSE), like the rest of the project.
You are encouraged to certify the
[Developer Certificate of Origin](https://developercertificate.org/) by signing
off your commits (`git commit -s`), which adds a `Signed-off-by` line.

AI-assisted code is fine, as long as you have reviewed it yourself and it meets
a high quality bar. Maintainers may decline any contribution. If you disagree
with a decision, you are free to fork the project.

## Local setup

- Use the Flutter version pinned in [`.fvmrc`](.fvmrc) (`fvm use` reads it); keep `flutter_app/pubspec.lock` committed.
- Use the Node version in [`server/package.json`](server/package.json) (`engines`); install from the committed lock with `npm ci`.
- For a local API, start from [`server/.env.example`](server/.env.example) (copy to the git-ignored `server/.env`). The repository-root [`.env.example`](.env.example) is the template for the production Compose environment file, which uses the file-backed secrets described in [DEPLOYMENT.md](DEPLOYMENT.md). Keep `.env`, signing files, private keys, tokens, and real user data out of Git and test fixtures.
- Database tests must use the isolated test database setup. Never point tests at a developer, staging, or production database.

### Run a local API

You need Node 24, Docker and the `psql` client. `server/docker-compose.dev.yml` is a standalone file that starts a throwaway PostgreSQL only (service `db`; it does not start the API). The `docker-compose.dev.yml` in the repository root is a different file, an override for the production Compose stack, and is not used here:

```sh
cd server
docker compose -f docker-compose.dev.yml up -d --wait
npm ci
cp .env.example .env              # then edit .env as described below
npx tsx scripts/generate-keys.ts  # prints JWT_PRIVATE_KEY / JWT_PUBLIC_KEY lines for .env
openssl rand -hex 32              # run twice: TOTP_ENC_KEY and DELIVERY_PAYLOAD_KEY
bash scripts/setup-test-db.sh     # creates the app_user role for the dev database
npm run db:migrate:dev            # applies migrations using DATABASE_URL_SUPER
npm run dev                       # tsx watch on PORT (3000 by default)
```

If another PostgreSQL already uses port 5432, run `export DEV_DB_PORT=55432` (any free port) before the first and the `setup-test-db.sh` commands, and use that port in the three database URLs in `server/.env`; the throwaway database is published on localhost only.

In `server/.env`, the database URLs already match the throwaway database (`devpassword` for `postgres` and for `app_user`, the default of `setup-test-db.sh`); if you gave `setup-test-db.sh` a different password, update `DATABASE_URL` and `DATABASE_URL_APP`. Paste the generated JWT lines, and set `TOTP_ENC_KEY` and `DELIVERY_PAYLOAD_KEY` to two different 32-byte hex values.

Set `ADMIN_EMAIL` and `ADMIN_PASSWORD` together in `server/.env` to enable the environment-managed administrator for local work. The Flutter app also runs without any server (offline-first); see the [README](README.md) for building it.

## Focused and aggregate checks

Run server commands from `server/`:

```sh
cd server
npm ci
npm run build
npm run openapi:check
npm test
```

Run Flutter commands from `flutter_app/`:

```sh
cd flutter_app
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

After editing Drift tables/DAOs or Riverpod providers, regenerate committed outputs from `flutter_app/`:

```sh
cd flutter_app
dart run build_runner build --delete-conflicting-outputs
```

When you bump `AppDatabase.supportedSchemaVersion`, also dump the new schema snapshot and regenerate the verifier helpers, then add the step's data-survival coverage to `test/core/db/schema_upgrade_test.dart` (it migrates every historical version in `drift_schemas/` to the current one and fails when a snapshot is missing). Never edit existing snapshots; they describe shipped stores.

```sh
dart run drift_dev schema dump lib/core/db/database.dart drift_schemas/
dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
dart format test/generated_migrations
```

After editing `lib/l10n/app_en.arb` or `app_ro.arb`, regenerate localizations from `flutter_app/`:

```sh
cd flutter_app
flutter gen-l10n
```

After editing `server/src/db/schema.ts`, run `npm run db:generate` in `server/`, review the generated SQL, and commit it with the schema change. Never hand-apply migration SQL or run `rls-policies.sql` manually. For deployment acceptance, use the disposable drivers in `scripts/acceptance/`; do not target a live stack.

## Translations

Translations into more languages are very welcome. The English strings are in
`flutter_app/lib/l10n/app_en.arb`. Copy it to `app_<language code>.arb` (for
example `app_de.arb`), translate the values and keep the keys and
placeholders unchanged. Run `flutter gen-l10n` in `flutter_app/` and add the
language to the picker in
`lib/features/settings/presentation/language_settings.dart`. If you only want
to translate, open a pull request with the ARB file and a maintainer will
connect it.

## Protected storage and disposable Android checks

The app opens its database through the encrypted SQLite hook in `pubspec.yaml`;
do not replace it with plain SQLite. Before the full suite, run
`test/core/storage/protected_database_opening_test.dart`,
`protected_store_coordinator_test.dart` and `storage_services_test.dart`.
Migrations must keep pending sync operations and staging rows. Details are in
the [protected-storage contract](docs/ARCHITECTURE.md#protected-android-care-storage).

Native checks require a separately created **blank disposable Android AVD**.
The following guarded harness deletes only its test generation between legacy
fixtures, so never run it on an existing personal/developer installation:

```sh
cd flutter_app
flutter run --debug --target integration_test/protected_storage_test.dart \
  --dart-define=SIMPASTIL_DISPOSABLE_TEST=true -d DISPOSABLE_DEVICE_ID
```

Quit the first process with `q`, force-stop that disposable app, then run the
same target with `--dart-define=RESTART_STAGE=restart` to verify actual
process-restart persistence. `flutter test` uninstalls its integration-test app
on completion and cannot substitute for this two-process check. Use fictional
care only, preserve concise pass evidence outside Git, and clean the disposable
fixture after verification.

Inspect the **built APK**, including resolved manifest resource references and
all legacy/cloud/device-transfer exclusion domains, from the repository root. Build the debug APK first:

```sh
cd flutter_app
flutter build apk --debug
```

```sh
node scripts/check-android-backup-package.mjs \
  flutter_app/build/app/outputs/flutter-apk/app-debug.apk \
  /path/to/Android/Sdk/build-tools/VERSION/aapt2
```

Also format `integration_test/` and `packages/simpastil_storage/lib/` with the
app sources. See the [protected-storage contract](docs/ARCHITECTURE.md#protected-android-care-storage).

## Change discipline

Write a focused regression test before changing behavior. Keep tests tied to observable behavior and run the focused test plus the full check for that component (server or Flutter, above). Generated files are committed with their sources; do not hand-edit generated Dart localization or Drift files. Keep changes focused, and say in the pull request which checks you could not run.

## Invariants

- Runtime API queries use least-privilege `app_user`; migrations use the separate superuser credential. Every tenant transaction sets `app.current_user_id` locally and queries also constrain `user_id` explicitly.
- User and admin access gates reject every JWT that carries a `purpose` property. A 2FA challenge is not an access token.
- Medication sync flushes pending work before pulling. Pulls never replace unsynced local state. Conflict policy is server-wins for profiles/pills/schedules and local-wins for dose logs.
- Local `frequencyDays` is a JSON string; the wire value is an integer array. Decode on write, encode on pull, and preserve camelCase field names.
- Client stale-reset is 88 days, below the server's 90-day tombstone retention horizon (automatic purge is currently disabled).
- The Android widget reads `today_doses`, `snapshot_day`, and `app_theme_mode`; keep these cross-language keys stable. `prn_in_stats_$userId` and `prn_in_widget_$userId` are Dart-only inputs.
- Notification locale lookup supports English and Romanian; unsupported locales fall back to English so reminder scheduling continues.

See [architecture and contracts](docs/ARCHITECTURE.md) before editing API,
medication, sync, projection, or privacy boundaries.

## Documentation

Keep the guides linked from [README.md](README.md) current, and update examples
and links together with code changes. The generated OpenAPI document is
authoritative for API routes and schemas. Development workflow lives here,
operations in `DEPLOYMENT.md`, technical contracts in `docs/ARCHITECTURE.md`,
and release signing in `docs/RELEASE.md`.
