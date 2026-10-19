<p align="center">
  <img src="docs/images/cover.png" alt="Simpastil: offline-first medication tracking for you and the people you care for" width="100%">
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-blue"></a>
  <a href="https://github.com/LucaPisl/simpastil/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/LucaPisl/simpastil"></a>
  <img alt="Platform: Android" src="https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white">
  <img alt="Built with Flutter" src="https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter&logoColor=white">
  <img alt="Self-hostable with Docker Compose" src="https://img.shields.io/badge/self--hostable-Docker%20Compose-2496ED?logo=docker&logoColor=white">
  <a href="https://ko-fi.com/lucapisl"><img alt="Support on Ko-fi" src="https://img.shields.io/badge/Support%20on-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white"></a>
</p>

# Simpastil

Simpastil is an offline-first Android app for tracking medication and
adherence, for yourself or for the people you care for. Everything works on the
phone with no account and no server. If you want your data on more than one
device, you can connect the app to your own self-hosted Simpastil server.

The repository holds the Flutter app (`flutter_app/`), the Fastify and
PostgreSQL sync server with its admin console (`server/`), and the Docker
Compose deployment (`docker-compose.yml`, `nginx/`).

## What it looks like

### Phone

| Today | As needed | Today at night | Timeline layout |
| --- | --- | --- | --- |
| <img src="docs/images/screenshots/today-focus-light.png" width="170" alt="Today, Focus deck, light"> | <img src="docs/images/screenshots/today-as-needed-light.png" width="170" alt="As-needed ring cards"> | <img src="docs/images/screenshots/today-focus-dark-night.png" width="170" alt="Today, Focus deck, dark night sky"> | <img src="docs/images/screenshots/today-timeline-light.png" width="170" alt="Today, Timeline layout with a missed dose"> |

| Medications | Supply | Routine | History |
| --- | --- | --- | --- |
| <img src="docs/images/screenshots/medications-light.png" width="170" alt="Medications list with stock"> | <img src="docs/images/screenshots/medication-detail-supply.png" width="170" alt="Medication detail with supply calendar"> | <img src="docs/images/screenshots/schedule-day-dial.png" width="170" alt="Routine editor with day dial"> | <img src="docs/images/screenshots/history-day.png" width="170" alt="History for one day"> |

| History calendar | History trends | Settings | Colors and theme |
| --- | --- | --- | --- |
| <img src="docs/images/screenshots/history-calendar-light.png" width="170" alt="History calendar"> | <img src="docs/images/screenshots/history-trends-light.png" width="170" alt="History trends"> | <img src="docs/images/screenshots/settings.png" width="170" alt="Settings"> | <img src="docs/images/screenshots/settings-appearance.png" width="170" alt="Colors and theme editor"> |

| First run | Add a medication | Medications, dark |
| --- | --- | --- |
| <img src="docs/images/screenshots/onboarding-welcome.png" width="170" alt="First-run welcome screen"> | <img src="docs/images/screenshots/onboarding-first-medication.png" width="170" alt="Setup: add your first medication"> | <img src="docs/images/screenshots/medications-dark.png" width="170" alt="Medications list, dark theme"> |

### Tablet

On a tablet, each screen has its own wide layout with a navigation rail.

| Today | History trends |
| --- | --- |
| <img src="docs/images/screenshots/tablet-today-landscape.png" width="420" alt="Tablet Today with the dose deck, as-needed cards, stock and the week"> | <img src="docs/images/screenshots/tablet-history-trends-landscape.png" width="420" alt="Tablet History trends with adherence, weekly trend and time of day"> |

| Medications | History calendar |
| --- | --- |
| <img src="docs/images/screenshots/tablet-medications-landscape.png" width="420" alt="Tablet Medications list beside the selected medication"> | <img src="docs/images/screenshots/tablet-history-calendar-landscape.png" width="420" alt="Tablet History calendar beside the selected day"> |

| Portrait, dark | Medication detail, dark | Settings |
| --- | --- | --- |
| <img src="docs/images/screenshots/tablet-today-portrait-dark.png" width="220" alt="Tablet Today in portrait, dark theme"> | <img src="docs/images/screenshots/tablet-medication-detail-portrait-dark.png" width="220" alt="Tablet medication detail in portrait, dark theme"> | <img src="docs/images/screenshots/tablet-settings-landscape.png" width="340" alt="Tablet Settings"> |

## Features

- **No account needed.** Everything runs on the phone; a server is optional.
- **Phones and tablets.** On tablets and other wide windows the app uses its own
  layouts: a navigation rail, a two-pane Today with a side column (this week,
  stock, what is coming up) and a dose-details panel, a medication list beside
  its detail, master-detail Settings, and a History with calendar and trends
  side by side. The phone has the same features in narrow-screen layouts.
- **Today.** Six layouts for the day's doses: Focus deck, Timeline, Day planner,
  People lanes, Action inbox and Daily journal. *Taken now* records the current
  time; *Undo* removes the entry and keeps its history.
- **Missed doses.** With *Record missed doses* on (Settings > Reminders, on by
  default), a dose nobody recorded is written to the history as missed once the
  delay has passed (an hour unless you choose another). It can still be recorded as taken late or skipped, and the miss
  can be undone. Recorded misses count in adherence, show in the calendar and
  are included in exports. Turning the setting off keeps existing misses.
- **Medications and supply.** Color-coded medications in compact rows with a
  stock strip, a detail page with stock, the last 14 days and recent activity,
  a live preview while you edit, and a supply calendar that shows when stock
  runs out. Running-low notices appear on Today.
- **As-needed medications.** As-needed medications have no routine. Each one
  is a ring card on Today: hold it to record a dose, then undo or open the
  details. Doses appear in every Today layout at the time they were taken.
- **Reminders.** The app asks for notification access only when you set up
  reminders. Settings shows whether access, scheduling and delivery are
  working. A scheduled reminder does not count as delivered.
  The list of upcoming reminders is computed on the device from your routines.
- **History and trends.** A week strip, calendar and per-day records, plus a
  day streak, adherence, time-of-day and as-needed charts, and stock changes.
  Days before a person was added on this phone are marked as such, not shown as
  days without doses.
- **Recorded by.** Attributes new doses to the primary profile, a name you type,
  or the person taking the medication. Earlier records keep their name.
- **Widget.** A home-screen widget shows today's doses.
- **Privacy.** Care data is kept in an encrypted SQLite database (SQLite3
  Multiple Ciphers) with a Keystore-backed key, excluded from Android backup and
  device transfer. An optional app lock is available. Portable backups are
  encrypted with their own password; PDF and CSV reports are created only when
  you export them.
- **Reduce motion.** Changes appear in place instead of animating. It turns on
  automatically when the phone's accessibility setting asks for less motion.
- **Optional sync** with a self-hosted server: PostgreSQL with row-level tenant
  isolation, an admin console, API keys and email invitations, and TOTP
  two-factor authentication for users and administrators.
- **Update notices.** A card on Today and in Settings says when a newer
  release is out; you install it yourself. The server checks GitHub once a day
  for its apps, and a phone without a server can check on its own if you switch that
  on (it is off by default for new installs). See
  [Update notices](docs/INSTALL-ANDROID.md#update-notices).
- **Languages.** English and Romanian. Translations into more languages are
  very welcome; [CONTRIBUTING.md](CONTRIBUTING.md#translations) explains how.

## Getting started

To only install a released app, see
[docs/INSTALL-ANDROID.md](docs/INSTALL-ANDROID.md). The paths below start from a
checkout of this repository.

### 1. The app, without a server

To build and run from source you need the Flutter version pinned in [`.fvmrc`](.fvmrc) (3.47.7) with
the Android SDK, and an Android device or emulator.

```sh
cd flutter_app
flutter pub get --enforce-lockfile
flutter run -d <device-id>        # list devices with: flutter devices
```

On first launch choose **Start on this device**, then add a person and a
medication. To build an installable debug APK:

```sh
cd flutter_app
flutter build apk --debug
```

Release APKs are refused unless signing is configured: copy
`flutter_app/android/signing.example.properties` to
`flutter_app/android/signing.properties` and fill it in, or provide the
equivalent `SIMPASTIL_*` environment variables. A debug-signed install cannot be
upgraded in place by a production-signed APK. See [docs/RELEASE.md](docs/RELEASE.md).

### 2. A server for sync (production, Docker Compose)

The supported topology is nginx, the Fastify API, an outbox worker, one-shot
provisioning and migration services, and PostgreSQL 16. You need a Linux host
with Docker Compose, a DNS name with a TLS certificate and key, and optionally
an SMTP account for emailed invitations and password resets.

The full from-zero procedure is in **[DEPLOYMENT.md](DEPLOYMENT.md)**: the secret
files, the Compose environment file, TLS placement, first start, creating the
first administrator, upgrades, backup and restore, and rollback. In outline, from
a checkout of a release tag (`/srv/simpastil` is only an example):

```sh
cd /srv/simpastil
scripts/init-deploy.sh --domain your.host.example --smtp-host smtp.example.org \
  --cert /path/to/fullchain.pem --key /path/to/privkey.pem   # --smtp-host is optional
docker compose --env-file /secure/simpastil/compose.env up --detach --build
curl --fail "https://your.host.example:34857/api/v1/health/ready"
docker compose --env-file /secure/simpastil/compose.env run --rm provision rotate-bootstrap
```

`init-deploy.sh` writes the secret files and `compose.env` under
`/secure/simpastil`; DEPLOYMENT.md explains how to use directories you own
instead and how to run behind a reverse proxy you already have. The last
command prints a one-time proof (valid for 30 minutes) that you enter, with an
email and password, at `https://your.host.example:34857/#/setup` to create the
first administrator. Users then join through an API key or an
invitation created in the admin console, and the app connects to your server's
origin from its settings.

### 3. A server for development

You need Node 24 (see `server/package.json`), Docker, and the `psql` client for
a throwaway PostgreSQL. Run everything from `server/`. The database comes from
`server/docker-compose.dev.yml`, a standalone file that starts only PostgreSQL
(service `db`, user `postgres`, password `devpassword`, port 5432 on localhost
only) and does not start the API. Do not confuse it with the `docker-compose.dev.yml` in the
repository root, which is an override for the production Compose file and needs
that stack's secrets. Details and the `.env` values to edit are in
[CONTRIBUTING.md](CONTRIBUTING.md#run-a-local-api).

```sh
cd server
docker compose -f docker-compose.dev.yml up -d --wait
npm ci
cp .env.example .env
npx tsx scripts/generate-keys.ts   # prints the JWT key lines for .env
openssl rand -hex 32               # run twice: TOTP_ENC_KEY and DELIVERY_PAYLOAD_KEY
bash scripts/setup-test-db.sh
npm run db:migrate:dev
npm run dev
```

The API listens on port 3000 by default. If something already uses port 5432
(for example a local PostgreSQL), run `export DEV_DB_PORT=55432` (any free
port) before the first and the `setup-test-db.sh` commands, and use that port in
the three database URLs in `.env`. Never point development or test runs at
real data, and never commit `.env` files or keys.

## Verify your checkout

These commands do not deploy or publish. Use disposable infrastructure only.

```sh
cd server
npm ci
npm run build
npm run openapi:check
npm test
```

`npm test` needs Docker; it starts disposable PostgreSQL containers.

```sh
cd flutter_app
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Release signing and artifact verification are described in [docs/RELEASE.md](docs/RELEASE.md).

## Repository layout

| Path | What it is |
| --- | --- |
| `flutter_app/` | Offline-first Flutter client (Riverpod, GoRouter, Drift, WorkManager, Android widget) |
| `server/` | Fastify 5 + TypeScript API, Drizzle/PostgreSQL, outbox worker, generated OpenAPI |
| `server/admin/` | Vue + Vite admin console |
| `contracts/` | Versioned JSON contracts and fixtures shared by server and app tests |
| `nginx/`, `docker-compose*.yml` | The supported self-hosted deployment |
| `scripts/` | Acceptance, backup/restore, release and policy checks |
| `docs/` | Architecture, release and decision documents; start at [docs/README.md](docs/README.md) |

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md): development workflow and checks
- [DEPLOYMENT.md](DEPLOYMENT.md): install, upgrade, backup, restore, rollback
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): API, sync, medication, privacy and storage contracts
- [docs/RELEASE.md](docs/RELEASE.md): signing, provenance and artifact verification
- [docs/README.md](docs/README.md): index of all documents
- [CHANGELOG.md](CHANGELOG.md): release history

## Support this project

Simpastil is free and open source, and you can help in two ways:

- **Help build it.** Bug reports, translations and code are welcome; start
  with [CONTRIBUTING.md](CONTRIBUTING.md).
- **Fund the work.** If the app is useful to you, a donation helps
  keep development going. It is entirely optional.

<p>
  <a href="https://ko-fi.com/lucapisl"><img alt="Support Simpastil on Ko-fi" src="https://storage.ko-fi.com/cdn/kofi3.png?v=3" height="36"></a>
</p>

## License

Simpastil is licensed under the
[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). You may use,
study, modify and share it, but anyone who distributes a modified version, or
runs one as a network service, must make the corresponding source available
under the same license.

**Assets.** Some icons were made by Xeno, and others were generated or edited
with Claude (Anthropic). All assets are licensed AGPL-3.0-only.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the
workflow and contribution terms. To report a problem, open Settings > About >
Report a problem in the app; it prepares a short report that holds no names,
medicines, doses or server address, and the quickest route is a GitHub issue.
To report a vulnerability, follow [SECURITY.md](SECURITY.md) and do not open a
public issue.
