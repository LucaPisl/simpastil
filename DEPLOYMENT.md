# Simpastil deployment and upgrade guide

This guide covers the supported Docker Compose deployment, from an empty host to
a running, backed-up and upgradable stack. The Compose file and the ordered
migration chain are the executable reference; the generated [API
contract](server/openapi/openapi.json), the [architecture](docs/ARCHITECTURE.md)
and the [release guide](docs/RELEASE.md) define the remaining contracts.

Deploy from a checkout of a tagged release or of a specific commit, and record
the exact commit or release-manifest digest used for every deployment.

## Quickstart

On a Linux host with Docker Engine, the Compose plugin, `git`, `openssl` and
`node`, a DNS name and a CA-issued certificate for it:

```sh
cd /srv/simpastil
scripts/init-deploy.sh --domain pills.example.org --smtp-host smtp.example.org \
  --cert /path/to/fullchain.pem --key /path/to/privkey.pem   # --smtp-host is optional
docker compose --env-file /secure/simpastil/compose.env up --detach --build
docker compose --env-file /secure/simpastil/compose.env run --rm provision rotate-bootstrap
```

Run it from a checkout of a release tag; `/srv/simpastil` is only an example
location. `init-deploy.sh` writes every secret file and `compose.env` under
`/secure/simpastil`, installs the certificate for the bundled nginx and creates
`/secure/simpastil-backups` for automatic backups; it refuses to overwrite
anything that exists. Those default directories sit under `/secure`, which an
ordinary user cannot create: either run `sudo install -d -o "$USER" /secure`
first, or pass `--secrets-dir DIR` and `--backup-dir DIR` for locations you own
(and use `DIR/compose.env` in the two `docker compose` commands).

The last command prints a one-time proof: open `https://pills.example.org:34857/#/setup` within 30
minutes and create the administrator.

- `--https-port 443` publishes HTTPS on the standard port (default 34857).
- `--tls host-proxy --cert <certificate your proxy serves>` is for a host that
  already runs a reverse proxy: the API listens on `127.0.0.1:34857` and the
  bundled nginx and admin console stay off. See [Topology and
  prerequisites](#topology-and-prerequisites) for the proxy settings.
- `--tls self-signed` is only for a browser trial: the Android app refuses a
  self-signed certificate, so phones cannot sync.

Upgrades are three commands and take their own backup; see [Upgrade](#upgrade).
The rest of this guide explains each piece.

## Topology and prerequisites

The supported topology is nginx → Fastify API → PostgreSQL 16, with separate
one-shot `premigrate-backup`, `provision` and `migrate` services, a
least-privilege `outbox` worker and the long-running `scheduled-backup` service
(see [Scheduled backups](#scheduled-backups)). Each start runs them in that order once
PostgreSQL is healthy: the backup step writes a restorable bundle whenever the
image bundles migrations the database does not have yet, then provisioning and
migrations run; the API and worker start only after the ordered migration
service succeeds; `scheduled-backup` starts after the same migrations. nginx also serves the built admin
console (a Vue single-page app) at `/`; the API is under `/api/`.

You need:

- A dedicated Linux host with Docker Engine and the Docker Compose plugin
  (`docker compose`), `git`, `openssl` and `node` (the backup scripts call
  `node`), with persistent storage for the PostgreSQL volume.
- A DNS name for the server and a valid TLS certificate and key for it. nginx
  reads `nginx/certs/cert.pem` and `nginx/certs/key.pem` (the directory is
  git-ignored and mounted read-only) and accepts TLS 1.3 only.
- Optional: an SMTP server for the outbox worker (password-reset and
  invitation mail). Without `SMTP_HOST` the worker idles, email invitations
  and emailed reset links are unavailable, and the administrator issues password
  reset links from the admin console instead (see Password reset below).
  SMTP authentication is optional.
- Protected storage, outside the checkout, for the Compose environment file and
  the secret files.

Published ports: HTTP `80` (redirects to HTTPS) and HTTPS **`34857`**, bound to
all interfaces by default. The default public origin is therefore
`https://your.host.example:34857`. Override the published ports and bind address
with `NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT` and `NGINX_HOST_IP` in the Compose
environment file. The port-80 redirect follows `NGINX_HTTPS_PORT`; set
`NGINX_PUBLIC_HTTPS_PORT` as well only when clients reach HTTPS on a port other
than the published one (for example through port forwarding).

Host-proxy topology: when the host already runs a reverse proxy that terminates
TLS, add [`docker-compose.host-proxy.yml`](docker-compose.host-proxy.yml) with
`COMPOSE_FILE=docker-compose.yml:docker-compose.host-proxy.yml` in the Compose
environment file. The API is then published on `127.0.0.1:${API_HOST_PORT}`
(default 34857), the bundled nginx and the admin console stay off, and your
proxy forwards to that address.

The API rate-limits by client address taken from `X-Forwarded-For`. The bundled
nginx overwrites that header with the connecting address, and the API trusts
exactly `TRUSTED_PROXY_HOPS` proxy hops (default `1`), so a client cannot forge
its rate-limit identity. When you run your own proxy in front of the API (for
example a host nginx publishing the API on `127.0.0.1:34857` with the bundled
nginx disabled), keep the default `1` and have that proxy send
`proxy_set_header X-Forwarded-For $remote_addr;` or `$proxy_add_x_forwarded_for`;
both resolve to the real client. Raise `TRUSTED_PROXY_HOPS` only for a chain in
which every hop appends its peer (for example a CDN in front of a host proxy),
and set it to `0` if the API is reachable without any proxy.
A front proxy must set `X-Forwarded-For`, otherwise every client shares one
rate-limit bucket; `TRUSTED_PROXY_HOPS=0` is for exposing the API directly.

The API connects as `app_user`, the outbox worker as `outbox_user`, and only
one-shot provision/migration/maintenance operations receive the superuser
credential. The one exception is the long-running `scheduled-backup` service,
which holds the superuser credential for as long as it runs because `pg_dump`
needs it; it is hardened as described under [Scheduled
backups](#scheduled-backups). Every other runtime process (the API, the outbox
worker, nginx) must never use the superuser URL. Do not
hand-apply SQL or run `rls-policies.sql`; the ordered migration chain in
`server/src/db/migrations/` is the reference. Each schema migration also
advances the deployment manifest to its schema version, except `0023`, which
only widens CHECK constraints and leaves the manifest at schema version 22.

## Configuration and secret files

Compose consumes paths to secret files, not secret values in the environment
file. Lay out a protected directory outside the checkout (this guide uses
`/secure/simpastil`) holding one file per secret plus a Compose environment
file, `compose.env`.

File-backed Compose secrets are bind mounts: Docker Compose does not change
their owner or mode, so each file must be readable by the user inside every
service that consumes it. The Node provision, migration, API, and outbox
processes run as UID/GID 1001. A practical standalone layout is an
operator-owned secret directory with mode `0700` and source files with mode
`0444`; the Docker host daemon can mount them, while other host users cannot
traverse the directory. Use narrower per-file ownership/modes when they cover
every consuming container identity. A single trailing newline in a secret file
is ignored.

Generate the secrets once (never paste them into docs, shell history, logs or
Git). Passwords are hex so they are safe inside connection URLs:

```sh
umask 077
mkdir -p /secure/simpastil && cd /secure/simpastil
openssl rand -hex 32 > postgres_password          # PostgreSQL superuser
openssl rand -hex 32 > app_user_password          # runtime role app_user
openssl rand -hex 32 > outbox_user_password       # worker role outbox_user
openssl rand -hex 32 > totp_encryption_key        # AES-256-GCM key, exactly 64 hex characters
openssl rand -hex 32 > delivery_payload_key       # outbox envelope key, exactly 64 hex characters
openssl genrsa -out jwt_private.pem 2048          # RS256 signing key
openssl rsa -in jwt_private.pem -pubout -out jwt_public.pem   # or: bash scripts/generate-keys.sh /secure/simpastil
printf '%s' "postgres://postgres:$(cat postgres_password)@postgres:5432/simpastil" > database_url_super
printf '%s' "postgres://app_user:$(cat app_user_password)@postgres:5432/simpastil" > database_url_app
printf '%s' "postgres://outbox_user:$(cat outbox_user_password)@postgres:5432/simpastil" > database_url_outbox
printf '%s' 'smtp-username' > smtp_user           # optional, see below
printf '%s' 'smtp-password' > smtp_password       # optional, see below
chmod 0444 * && chmod 0700 .
```

The superuser name and database in `database_url_super` must match
`POSTGRES_USER` (default `postgres`) and `POSTGRES_DB` (default `simpastil`).
The role passwords in the three URL files must equal the `*_user_password`
files, which the provision service uses to create the roles. `bash
scripts/generate-keys.sh /secure/simpastil` writes the two JWT key files with the
modes above and refuses to overwrite existing keys. The SMTP credential files
are optional: for a relay that needs no authentication omit `smtp_user`,
`smtp_password`, `SMTP_USER_FILE` and `SMTP_PASS_FILE`. Compose then mounts
`/dev/null` as an empty secret and the outbox worker sends without
authentication. If you provide credentials, provide both, non-empty.
Alongside the secrets, retain the keys separately as described under backup:
losing `totp_encryption_key` locks out every two-factor user, and losing
`delivery_payload_key` strands queued deliveries.

Create `/secure/simpastil/compose.env` (mode `0600`) with the public settings
and the file paths:

```sh
COMPOSE_PROJECT_NAME=simpastil-production
PUBLIC_APP_URL=https://your.host.example:34857
CORS_ORIGIN=https://your.host.example:34857
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_FROM="Simpastil <SENDER-ADDRESS>"   # replace with a sender your SMTP host accepts
POSTGRES_PASSWORD_FILE=/secure/simpastil/postgres_password
DATABASE_URL_SUPER_FILE=/secure/simpastil/database_url_super
DATABASE_URL_FILE=/secure/simpastil/database_url_app
DATABASE_URL_OUTBOX_FILE=/secure/simpastil/database_url_outbox
APP_USER_PASSWORD_FILE=/secure/simpastil/app_user_password
OUTBOX_USER_PASSWORD_FILE=/secure/simpastil/outbox_user_password
JWT_PRIVATE_KEY_FILE=/secure/simpastil/jwt_private.pem
JWT_PUBLIC_KEY_FILE=/secure/simpastil/jwt_public.pem
TOTP_ENC_KEY_FILE=/secure/simpastil/totp_encryption_key
DELIVERY_PAYLOAD_KEY_FILE=/secure/simpastil/delivery_payload_key
SMTP_USER_FILE=/secure/simpastil/smtp_user       # optional
SMTP_PASS_FILE=/secure/simpastil/smtp_password   # optional
SIMPASTIL_BACKUP_DIR=/secure/simpastil-backups   # automatic pre-migration and scheduled backups
SIMPASTIL_BACKUP_UID=1000                        # your `id -u`, owner of that directory
SIMPASTIL_BACKUP_GID=1000                        # your `id -g`
TLS_CERT_FILE=/srv/simpastil/nginx/certs/cert.pem
```

`SIMPASTIL_BACKUP_DIR` is a host directory outside the checkout, mode `0700`,
owned by the UID/GID given (default 1001). Do not use a Docker volume: it would
sit beside the database volume and `restore.sh` reads a host directory.
`TLS_CERT_FILE` (default `nginx/certs/cert.pem`) is only fingerprinted into
backups so a restore can check the certificate; with a host proxy, point it at
the certificate that proxy serves. `SIMPASTIL_BACKUP_KEEP` (default 5) is how
many pre-migration backups are kept. The scheduled backups have their own three
optional settings (`SIMPASTIL_SCHEDULED_BACKUP`, `SIMPASTIL_BACKUP_INTERVAL` and
`SIMPASTIL_SCHEDULED_BACKUP_KEEP`) under [Scheduled backups](#scheduled-backups).

`PUBLIC_APP_URL` (one canonical HTTPS origin, used in reset and invitation
links), `CORS_ORIGIN` and every `*_FILE` variable above except `SMTP_USER_FILE` and
`SMTP_PASS_FILE` are mandatory: Compose refuses to start
without them. Optional settings and their defaults are in
[`docker-compose.yml`](docker-compose.yml) (`POSTGRES_USER`, `POSTGRES_DB`,
`SMTP_HOST` (blank: no email), `SMTP_PORT` 587, `SMTP_FROM` (a built-in no-reply sender), `NGINX_*`, connection
and outbox tuning, `SHUTDOWN_TIMEOUT_MS`, `TRUSTED_PROXY_HOPS`, `SIMPASTIL_UPDATE_CHECK`,
`SIMPASTIL_SUBNET` (default `10.200.1.0/24`; change it when another Compose
project on the host uses that range) and `SIMPASTIL_VERSION`, the server image
release, which only a rollback sets). Set `SMTP_FROM`
to a sender your SMTP host accepts. `COMPOSE_PROJECT_NAME` makes install,
upgrade and the backup scripts agree on one project name. Leave `RELEASE_ID`
unset (see the upgrade section). The repository-root
[`.env.example`](.env.example) is a template for this file;
[`server/.env.example`](server/.env.example) is for local development only.
Neither is a production secret store.

Install the TLS certificate chain and key (from your CA) before starting the
proxy:

```sh
install -d -m 0755 /srv/simpastil/nginx/certs
install -m 0644 /path/to/fullchain.pem /srv/simpastil/nginx/certs/cert.pem
install -m 0600 /path/to/privkey.pem /srv/simpastil/nginx/certs/key.pem
```

Renew by replacing the files and restarting the proxy (`docker compose
--env-file /secure/simpastil/compose.env restart nginx`).

### Certificate fingerprint

The Android app pins the server's public key and shows its fingerprint when you
first connect. Compare it with the value below before you trust the server.
`scripts/init-deploy.sh` prints it for a new install. For an existing server,
compute it from the certificate your clients are served (`TLS_CERT_FILE`, by
default `nginx/certs/cert.pem`; with a host proxy, the certificate that proxy
serves). If the file holds a chain, the first certificate must be the leaf:

```sh
cd /srv/simpastil
openssl x509 -in nginx/certs/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | xxd -p -c 32 | tr a-f A-F | sed 's/../&:/g; s/:$//'
```

Without `xxd`, replace `xxd -p -c 32` with `od -An -tx1 -v | tr -d ' \n'`. The
result is 32 uppercase hex byte pairs separated by colons (95 characters), the
SHA-256 of the certificate's DER-encoded public key (SubjectPublicKeyInfo). It
does not change when the certificate is renewed with the same key, and changes
when the key changes: tell your users to expect the new value after a key
rotation.

## First install

From a clean checkout on the host, with the files above prepared:

```sh
cd /srv/simpastil
docker compose --env-file /secure/simpastil/compose.env up --detach --build
```

Name no services: with the host-proxy file, naming `nginx` would start the
bundled proxy that the file keeps off. Compose builds the server and nginx images (the nginx image also builds the
admin console), starts PostgreSQL, runs `premigrate-backup` (it finds an empty database and
writes nothing), runs `provision` (creates
`app_user`/`outbox_user` and verifies their privileges), runs `migrate` (the
ordered migration chain), and then starts the API, worker and proxy. The
privileged migration connection is isolated to the one-shot services. Do not
manually create roles, seed migration journal rows, or bypass readiness to force
an install through. Watch progress with `docker compose --env-file
/secure/simpastil/compose.env ps` and `logs --tail=100 api`.

### Medication ledger on a fresh install

A new database starts with the medication ledger **inactive**: the deployment
manifest row is created with `ledger_activated = false`, an enforced minimum
client build of 1 and an artifact target of 2 (a release build above the target,
such as build 3, is valid). Nothing activates it
automatically, neither the migrations, the first start nor the first user. In
this state the server runs in its compatibility ("bridge") mode, medication
writes from the app use atomic bridge commands, and `GET /api/v1/capabilities`
reports `medicationLedgerActive: false`. The app records doses and syncs
normally in this mode, so a fresh install is usable without any further step.

Activating the ledger is a separate, one-way operator action (`provision
activate-ledger`). It is described, with its prerequisites and limits, in
[Appendix: medication ledger
activation](#appendix-medication-ledger-activation). Do not run it without
reading that appendix and taking a verified backup.

### First administrator and first user

Database-backed administrator setup: after migrations complete, rotate the
one-time bootstrap proof through the provision service:

```sh
docker compose --env-file /secure/simpastil/compose.env run --rm provision rotate-bootstrap
```

The proof is printed once, expires after 30 minutes, and is entered on the admin
console's setup page, `https://your.host.example:34857/#/setup`, together with
the administrator's email address and a new password. Treat the proof as a
credential and do not store it in logs or tickets. Existing installations
migrate as already-consumed; use the same privileged rotation command only for
an authorized recovery. Environment-managed admin mode (the API reads
`ADMIN_EMAIL` and `ADMIN_PASSWORD` together) has its own session policy and does
not use database bootstrap; it is intended for local development, not this
Compose file.

Sign in at `https://your.host.example:34857/#/login` with the administrator
password only; the email you entered during setup is not asked for (set up
two-factor authentication in Settings). Users join in one of two ways from the console:
create an API key on the Keys page and give it to the person (the app registers
an account with that key, which can be claimed once), or send an invitation from
the Invites page, which queues an email through the outbox worker.

### Password reset

How a forgotten password is handled is a server setting, changed by the
administrator (`GET` and `PUT /api/v1/admin/settings`, and the console's
settings):

- **email**: the user asks for a reset in the app and the outbox worker mails a
  link. This needs `SMTP_HOST`; the API refuses to select it otherwise.
- **manual**: the app's request creates nothing and sends nothing (it still
  answers exactly as before, so nobody can tell whether an address exists). The
  administrator issues a link for a user from the console (`POST
  /api/v1/admin/users/{id}/reset-link`) and hands it over in person. Email
  invitations are refused in this mode; create an API key instead.
- **automatic** (the default): email when `SMTP_HOST` is set, manual otherwise.

The link lifetime is 60 minutes unless changed (5 to 1440 minutes). The link
from the console is shown once and never stored in plain text or written to the
audit log. Issuing any new link, by email or by hand, revokes the user's older
unused links. Invitation links keep their fixed seven-day lifetime.

## Update check

Once a day (the first check about a minute after start) the `api` container
asks GitHub for the latest published release of `LucaPisl/simpastil` (drafts
and prereleases do not count) and reads the app build from its
`release-manifest.json`. The requests carry only a `simpastil-server/<version>`
user agent, so GitHub sees the server's IP address and nothing about your data.
They need outbound HTTPS to `api.github.com`, `github.com` and GitHub's release
download hosts. The result is kept in memory and reported by
`GET /api/v1/capabilities`. The admin dashboard shows a banner when the release
is newer than the running server, and apps signed in to this server read the
answer from capabilities instead of contacting GitHub. Set
`SIMPASTIL_UPDATE_CHECK=off` in the Compose environment file to disable it
(`on` is the default; any other value stops the API from starting). Nothing is
ever downloaded or installed.

When a newer server version is published the API writes one log record per
check, a stable interface for monitoring:

```json
{"event":"update.available","currentServerVersion":"1.0.0","latestServerVersion":"1.1.0","latestClientBuild":4,"releaseUrl":"https://github.com/LucaPisl/simpastil/releases/tag/v1.1.0"}
```

```sh
docker compose --env-file /secure/simpastil/compose.env logs api | jq -c 'select(.event == "update.available")'
```

A failed check (GitHub unreachable, an error status, or a release without a
valid manifest) logs `update.check_failed` with an `errorCode` only and keeps
the previous result.

## Health, readiness, and support

- `GET /api/v1/health/live` is process liveness.
- `GET /api/v1/health/ready` verifies the database, the deployment manifest, the
  runtime role, required configuration, and that the applied migration head
  (count, newest timestamp and hash of `drizzle.__drizzle_migrations`) matches
  the journal bundled in the running image. A database behind or ahead of the
  image is not ready. `RELEASE_ID` is optional and unset on a stock install; set
  it only to pin readiness to one manifest `release_id`.
- `GET /api/v1/health` remains a compatibility summary.
- Bare `/` returns 404 from the API process; through nginx it serves the admin
  console. Neither is a health endpoint.

After startup, confirm all expected Compose services are healthy/completed and
request readiness at the configured public host, for example `curl --fail
"$PUBLIC_APP_URL/api/v1/health/ready"`. Readiness is not proof of tenant
isolation by itself; the release acceptance also checks runtime role, `FORCE ROW
LEVEL SECURITY`, and cross-tenant denial. See [safe logging and
diagnostics](docs/ARCHITECTURE.md) for support information to share.

When readiness fails, the API log says why. Every log line has a plain-English
`msg` next to its JSON fields, and `readiness.not_ready` names the reason once
when it changes (`database_unreachable`, `migrations_behind`,
`migrations_incompatible`, `migrations_unreadable`, `runtime_role_unsafe`,
`release_mismatch`, or `contract_not_ready`). For example:

```sh
docker compose logs api --since 10m | grep -E 'readiness\.|request\.error|process\.crashed'
```

A service that stops on a startup error (a missing or invalid setting, an
unreachable database) prints a single `process.crashed` or `*_failed` line that
names the setting or the kind of failure. Lines never contain the exception text,
so they are safe to paste into a bug report.

## Upgrade

Every upgrade takes its own backup. The one-shot `premigrate-backup` service
runs before `provision` and `migrate`; when the new image bundles migrations
the database does not have yet, it writes a complete `restore.sh` bundle named
`pre-<applied migration count>-<UTC time>` to `SIMPASTIL_BACKUP_DIR`, verifies
its checksums and keeps the newest `SIMPASTIL_BACKUP_KEEP` (default 5). If it
cannot write the bundle, nothing migrates. When the database is already at the
image's head it does nothing, so restarts cost no backup.

1. Read the [changelog](CHANGELOG.md) and the per-migration notes below. A
   release whose notes say **breaking** can only be undone by a restore (see
   [Rollback](#rollback)) and keeps the API unavailable between steps 4 and 5.
2. Check the Compose environment file for a `RELEASE_ID`
   that an earlier install set (for example `migration-0015`) and remove it, or
   set it to the new head's manifest `release_id`. A stale pin makes
   `GET /api/v1/health/ready` return 503 after the migration advances the
   manifest, even though the API keeps serving. Coming from a release before
   1.0.0, also add `SIMPASTIL_BACKUP_DIR`, `SIMPASTIL_BACKUP_UID`,
   `SIMPASTIL_BACKUP_GID` and `TLS_CERT_FILE` (see [Configuration and secret
   files](#configuration-and-secret-files)); Compose refuses to start without
   the backup directory.
3. Check out the approved revision and build the images. The running API keeps
   serving:

   ```sh
   cd /srv/simpastil
   git fetch origin && git checkout <approved-commit-or-tag>
   docker compose --env-file /secure/simpastil/compose.env build
   ```

4. Back up and migrate while the old API is still running:

   ```sh
   docker compose --env-file /secure/simpastil/compose.env run --rm migrate
   ```

   This runs `premigrate-backup`, `provision` and `migrate` in order and stops
   at the first failure. If it fails, nothing was migrated and the running
   release is untouched; read `docker compose logs premigrate-backup` (most
   often the backup directory is missing or not writable by
   `SIMPASTIL_BACKUP_UID`), fix it and run the step again. `migrate` holds a
   database lock, so a second concurrent run waits instead of interleaving.
5. Start the new release:

   ```sh
   docker compose --env-file /secure/simpastil/compose.env up --detach
   ```

6. After the upgrade, confirm `GET /api/v1/health/ready` returns 200 and that
   every service is healthy.

Do not skip straight to `up --detach --build`: Compose stops the running API
before it runs the one-shot services, so a failed backup would leave the
service down. If that happened, the database is unchanged; start the previous
release again with `SIMPASTIL_VERSION=<previous release> docker compose
--env-file /secure/simpastil/compose.env up --detach --no-build api outbox`
(add `nginx` only when the install runs the bundled proxy), fix the cause and
continue from step 4.

Images are tagged by release (`simpastil-server:<version>`), so an upgrade
keeps the previous release's image on the host for a rollback. Prune old tags
only after you no longer need to go back to them.

Per-migration notes:

- The PRN recovery update requires migration 0017 and its matching server image
  before a client uses `medicationBridgePrnCommands: 1` and
  `medicationBridgePrnSync: 5`. Rehearse the upgrade against a protected
  disposable restore. This update does not activate the medication ledger or
  require nginx changes. The phone upgrade advances its protected database to
  schema 14; keep a verified protected backup and the existing APK signing
  identity, and never clear app data or attempt a database downgrade as a
  rollback.
- Refresh recovery requires migration `0018_recoverable_refresh.sql` and its
  matching server image before clients can use `contracts.refreshRecovery: 1`.
  Before an upgrade from an earlier schema, check for duplicate refresh-token
  hash groups; stop for a reviewed repair if any exist. Do not delete sessions
  to force the unique index through. This additive protocol keeps older clients
  supported; it does not recover an old uncertain refresh that lacks a saved
  successor proposal. See the [protocol and rollout
  evidence](docs/decisions/refresh-recovery.md).
- `0019_migration_head_readiness.sql`, `0020_sync_mapping_entity_identity.sql`,
  `0021_pill_stock_guard_allows_untracked.sql` and
  `0022_user_delete_skips_handoff_journal.sql` advance the deployment
  manifest; the server image and the schema must move together, as the
  readiness check enforces.
- `0023_recorded_miss_state.sql` lets the medication ledger store a recorded
  missed dose (`miss` action, `missed` state). It only widens CHECK constraints,
  so every existing row stays valid, and it does not advance the deployment
  manifest (`schema_version` stays 22; readiness compares the applied migration
  head, not that value). The Compose migration service applies it; never apply
  the SQL by hand. It is paired with `medicationCommands: 3`, which turns
  recorded misses on for clients that speak it and makes a client that only
  speaks contract 2 report update required. Install the app build that carries
  recorded misses (build 3) on every device first: it keeps working, with
  misses off, against a server that is still on 0022. Afterwards confirm
  `curl -s https://your.host.example:34857/api/v1/capabilities` reports
  `medicationCommands: 3` and `recordedMiss: true`.

  This migration deliberately does not record itself in the deployment
  manifest. After 0023 the manifest still reports `schema_version` 22 and
  `release_id` `migration-0022`, and a `RELEASE_ID` pin in the Compose
  environment must stay `migration-0022`. Readiness compares the applied
  migration head with the image's bundled head, not the manifest's
  `schema_version`.

  **Rollback after 0023 means restoring the pre-0023 backup.** Readiness
  requires the applied migration head to equal the image's bundled head, so the
  previous (0022) server image never becomes ready against a 0023 database,
  even before any miss exists. Take and verify a backup before deploying 0023:
  it is the only way back. To return,
  restore that backup into a fresh Compose project with the previous image,
  following the restore rules below; everything written since the backup is
  lost. Never reuse the 0023 database with the older image.

Each migration from `0024_migration_compatibility.sql` on declares
whether it is **expand** (older images keep working) or **breaking**; see the
[migration compatibility decision](docs/decisions/migration-compatibility.md).

- `0025_medication_detail_sync.sql` gives a medicine the reviewed details the
  app previously kept on one device only: the amount taken per dose, the
  package strength, the form, and whether somebody has reviewed the original
  dosage wording. It only adds nullable columns, one column with a default, and
  CHECK constraints on the new columns, so every existing row stays valid, and
  it declares **expand**: the previous image keeps serving this database, so
  going back is `rollback.sh` rather than a restore. It does not advance the
  deployment manifest, which keeps reporting `schema_version` 22 and
  `release_id` `migration-0022`.

  It is paired with `medicationDetails: 1`. Deploy it before installing the app
  build that speaks it: an older build ignores a capability it does not know,
  and its edits leave the new columns alone, so nothing it sends can erase a
  review. Until a device runs the newer build, a review made on it stays on
  that device; the first sync afterwards hands those reviews to the account.
  Confirm `curl -s https://your.host.example:34857/api/v1/capabilities`
  reports `medicationDetails: 1`.

- `0026_server_settings.sql` adds the `server_settings` table, one row that holds
  how password reset works (email or manual, or automatic) and how long a reset
  link stays valid (5 to 1440 minutes, default 60). It also adds a read-only
  function that counts recent permanent email failures for the admin console,
  without exposing recipients or message contents. It only adds a table and a
  function, so it declares **expand**: the previous image keeps serving this
  database and going back is `rollback.sh`. The API role can read and update the
  settings row but cannot insert or delete rows; the table has row-level
  security enforced like the other tables.

## Rollback

Rollback never down-migrates. If an upgrade fails, preserve the logs and data
and prefer a forward repair. To go back to an earlier release:

```sh
cd /srv/simpastil
scripts/rollback.sh --to 1.0.0 --env-file /secure/simpastil/compose.env --dry-run
```

`rollback.sh` reads the database's applied migrations and compatibility floor
and the migrations bundled in `simpastil-server:<version>`, and never changes
the database. Without `--dry-run`, when that image can serve the database
(every migration since it was an **expand**), it recreates `api` and `outbox`
from it and waits for readiness. Then set `SIMPASTIL_VERSION=<version>` in the
Compose environment file so the next `up` keeps it; remove the line when you
upgrade again.

When a **breaking** migration ran since that release, or the target is older
than 1.0.0 (those images only accept their exact migration head), it refuses
and names the newest automatic bundle taken at that release's migration count
(`pre-<count>-*`). Going back then means a restore; everything written since
the backup is lost. After medication-ledger activation, see also the rollback
limits in the [appendix](#appendix-medication-ledger-activation).

Releases before 1.2.0 have no `scheduled-backup` command. While
`SIMPASTIL_VERSION` points at one, the `scheduled-backup` container cannot run
and keeps restarting: run `docker compose stop scheduled-backup`, take manual
backups, and the service returns when you upgrade again.

### Restore into a fresh project

Restore a bundle with the release that was running when it was taken: its
`deployment-manifest.json` names that release as `serverImageDigest`, and
restore stops unless the restoring release records the same value.
`rollback.sh` prints it. (Bundles taken before 1.0.0 record an image digest
instead; restore those with the release that bundles that migration count.)
Use a new project name, a free subnet and free ports (`API_HOST_PORT` with the
host-proxy file, `NGINX_HTTP_PORT` and `NGINX_HTTPS_PORT` with the bundled
nginx), so the restored stack can start beside the old one:

```sh
cd /srv/simpastil
set -a; . /secure/simpastil/compose.env; set +a
export SIMPASTIL_VERSION=1.0.0 SIMPASTIL_SUBNET=10.200.9.0/24
export API_HOST_PORT=34858 NGINX_HTTP_PORT=8080 NGINX_HTTPS_PORT=34858
./scripts/restore.sh \
  --project simpastil-restore-2026-10-16 \
  --input-dir /secure/simpastil-backups/pre-25-20261016T120000Z \
  --jwt-public-key /secure/simpastil/jwt_public.pem \
  --totp-key /secure/simpastil/totp_encryption_key \
  --outbox-key /secure/simpastil/delivery_payload_key \
  --tls-cert /srv/simpastil/nginx/certs/cert.pem
```

Check out the matching release tag first when its image is no longer on the
host. Once the restored project is ready, stop the old project's `api` and
`outbox`, move the proxy (or `NGINX_*` ports) to the restored project, and keep
the old project's volume until the restore is accepted. See [Backup, restore,
delivery, and shutdown](#backup-restore-delivery-and-shutdown) for the restore
rules.

## Android client upgrade and local recovery

Install the approved client update over the existing installation. Normal
Android care opening creates and verifies an encrypted original recovery copy
before upgrading legacy v3/v4/v5 data. It activates a verified protected
generation and retires the plaintext source only after checking both protected
copies and completing durable deletion. A pending preparation/retirement state
requires retry or recovery; it must not be described as complete protection.

Do not uninstall, clear app storage, remove the device key or delete database
sidecars to resolve an opening failure. Established care is never initialized
again on key loss, an unsupported version or an unreadable/missing file.
Preserve the installation and use an existing verified portable backup or the
currently authorized connected source when the relevant recovery path is
available. The internal device-key recovery copy cannot be decrypted after its
device key is lost. Storage support evidence must exclude keys, SQL, row data
and private paths; report the typed failure and copy-check status.

The client stores protected generations in Android private no-backup storage.
Its packaged policy disables platform backup and excludes all nine storage
domains in both cloud and device-transfer rules, including secure preferences.
App interface lock and reminder permission/readiness are independent of the
database key. These client rules do not alter the server backup scripts below.
The [architecture guide](docs/ARCHITECTURE.md#protected-android-care-storage)
defines the preparation, verification and cleanup boundaries.

## Portable Android backup checks

Android portable care files and the server backup bundles below are different
interfaces. The Android backend writes password-protected `.simpbak`
files to a document explicitly chosen on the device. Its backup password is
separate from the device key and account sign-in. Keep that password separately
and securely; a forgotten password cannot be recovered by an operator. An
explicitly reviewed unprotected file is readable to anyone who has it.

Full capture includes supported local care, original authors, drafts, pending
work and relevant preferences. It requires current access to every retained
workspace; a locked collection does not become an incomplete Full backup.
Credentials, device keys, care grants and live synchronization authority are
excluded. Connected imports retain original account-scoped evidence and locked
workspace metadata. Later account sign-in alone cannot activate archived shared
profiles/history; a current server pull establishes operational care. An
exported author name is not account identity.

Saved and Checked are distinct. A check reopens the actual chosen destination
and validates its bytes and portable format. If reopening is unavailable, keep
the truthful Saved/unchecked result. A definitively invalid or oversized
readback fails the check. A failed dispatched write may leave a partial file.
Capture/check dates matter: an older checked copy is not a new backup. Checking
an existing file does not activate any care or reminders. Preserve existing data
on a wrong password, damaged/unsupported file or changed source. The format
refuses unsupported sizes rather than truncating care.

Selected local import keeps the current author and preferences. Divergent rows
retain both originals for review. Full replacement first reopens a protected
recovery copy of the affected care and preferences, then commits care and a
durable preference intent. Preference or optional reminder/widget failure does
not undo committed care or claim full completion: pending preferences retry on
startup, changed preferences need review, and OS projections retry separately.
Repeated import leaves records made since the first application intact. Preserve
both the chosen backup and on-device recovery originals when recovery is
unavailable.

PDF/CSV reports are explicitly shared clear files, not restorable backups.
Before sharing, their working copies remain in private no-backup storage and are
removed after success, cancellation or failure. These client rules do not change
the server scripts, keys or deployment policies below.

## Scheduled backups

The `scheduled-backup` service starts with the rest of the stack, after the
migrations, and needs no host timer. Every `SIMPASTIL_BACKUP_INTERVAL` it writes
the same verified, restorable bundle as the pre-migration backup, whether or not
anything changed, into the `scheduled/` folder of `SIMPASTIL_BACKUP_DIR` (created
with mode `0700` for `SIMPASTIL_BACKUP_UID`/`SIMPASTIL_BACKUP_GID`; nothing to set
up on an existing host). Bundles are named `scheduled-<UTC time>` and restore
with `restore.sh` exactly like the others. The schedule comes from the newest
bundle on disk, so restarting the service or the host does not take an extra
backup; the first backup runs as soon as the stack is up.

| Setting in the Compose environment file | Default | Meaning |
| --- | --- | --- |
| `SIMPASTIL_SCHEDULED_BACKUP` | `on` | `off` keeps the service running but idle: it never connects to the database and writes nothing. |
| `SIMPASTIL_BACKUP_INTERVAL` | `24h` | A number and a unit (`m`, `h` or `d`), from `1h` to `31d`; anything else stops the service at start with a configuration error in its log. |
| `SIMPASTIL_SCHEDULED_BACKUP_KEEP` | `7` | How many scheduled bundles to keep (1 to 100). |

Pruning only ever deletes `scheduled-<UTC time>` folders inside `scheduled/`. The
pre-migration bundles (`pre-<count>-<UTC time>`, kept per `SIMPASTIL_BACKUP_KEEP`)
sit at the top level of the backup directory and are never touched, so the two
retention counts are independent. A failed backup is logged
(`scheduled_backup.failed`) and retried within 15 minutes; the service never
exits for it. Its health check reports healthy while the newest successful backup
is younger than two intervals, for 30 minutes after start (the first backup, or a
catch-up after downtime) and whenever scheduled backups are off; otherwise
`docker compose ps` shows it as unhealthy. Look at `docker compose logs
scheduled-backup` for the reason, most often a backup directory that
`SIMPASTIL_BACKUP_UID` cannot write to.

**Bundles contain medical data and stay on this host.** They hold the complete
database (accounts, medication history, encrypted two-factor secrets) and the
fingerprints of the key files, not the key files themselves, and they live in
`SIMPASTIL_BACKUP_DIR`. That directory is not a disaster-recovery copy: a lost
disk or host loses the backups with it. Copy `SIMPASTIL_BACKUP_DIR` off the host
on your own schedule, encrypted and access-controlled, and keep a separate
protected copy of the key files that [Backup, restore, delivery, and
shutdown](#backup-restore-delivery-and-shutdown) describes: a restore needs
the matching ones.

**Superuser credential exception.** `pg_dump` needs the PostgreSQL superuser, so
this is the one long-running service that holds `database_url_super`; every other
runtime process uses a least-privilege role. The exposure is limited rather than
removed:

- it runs the same code as `premigrate-backup`, opens a database connection only
  for the seconds a backup takes, and has no network listener or published port;
- it joins only the database network, with a read-only root filesystem, a small
  `tmpfs` for its status file, all Linux capabilities dropped and
  `no-new-privileges`, as the unprivileged `SIMPASTIL_BACKUP_UID`;
- it mounts the superuser credential, the key files and certificate that are
  fingerprinted into a bundle, the backup directory and a read-only SQL file,
  and nothing else;
- with `SIMPASTIL_SCHEDULED_BACKUP=off` the process does not read the credential
  at all. To remove the service entirely, set that and run `docker compose
  stop scheduled-backup`, or omit it with a Compose override of your own.

The restore rules do not change: `restore.sh` still needs a fresh project, and a
running `scheduled-backup` counts as a running service. The restore starts only
the API, worker and proxy; run `docker compose up --detach` in the restored
project once you accept it, and the schedule resumes there.

## Backup, restore, delivery, and shutdown

The supported backup and restore interfaces are
[`scripts/backup.sh`](scripts/backup.sh) and
[`scripts/restore.sh`](scripts/restore.sh). They produce and consume a bounded
bundle for a named Docker Compose project; they do not encrypt it and do not
remove volumes. The database contains sensitive account and medication history,
so protect the complete bundle with organization-approved encryption, access
control, and off-site retention.

The bundle contains a PostgreSQL custom archive, role/grant/RLS inventory,
deployment and migration manifest, restore manifest, and SHA-256 checksums. A
separate inventory records non-secret identifiers/fingerprints for JWT signing,
TOTP/API-key encryption, outbox encryption, and TLS. Retain the matching
cryptographic material separately. A clean restore requires matching material;
silently substituting different keys is not a valid restore. Database
runtime-role passwords may be provisioned again during restore; the matching
cryptographic identities must remain the same. If a key is lost, follow the
relevant recovery/rotation procedure for its dependent sessions, factors, queued
deliveries, or certificates instead of claiming a byte-identical restore.

Upgrades back up automatically (see [Upgrade](#upgrade)) and the stack backs
itself up on a timer (see [Scheduled backups](#scheduled-backups)); take a
manual backup before any other risky change. The automatic bundles hold the same content and use the key files named in the
Compose environment file, so they restore with `restore.sh` like a manual one.
They are as sensitive as the database: keep `SIMPASTIL_BACKUP_DIR` at mode
`0700` and copy bundles off the host with the same protection.

Create backups from the repository root with the live stack's Compose project
name (`COMPOSE_PROJECT_NAME`, or the checkout directory name by default) and a
new empty output directory. Do not place output under the repository. The stack
must be running, because the backup reads from the live PostgreSQL service. The
scripts do not accept `--env-file`, and Compose still needs the required
variables, so export them first (the Compose environment file is plain
`NAME=value` lines):

```sh
set -a; . /secure/simpastil/compose.env; set +a
```

```sh
cd /srv/simpastil
./scripts/backup.sh \
  --project simpastil-production \
  --output-dir /srv/protected-backups/simpastil-2026-09-25 \
  --jwt-public-key /secure/simpastil/jwt_public.pem \
  --totp-key /secure/simpastil/totp_encryption_key \
  --outbox-key /secure/simpastil/delivery_payload_key \
  --tls-cert /srv/simpastil/nginx/certs/cert.pem
```

The key and certificate paths above are the files `init-deploy.sh` wrote; if
you keep the keys elsewhere, pass those paths instead. Both scripts use the
repository `docker-compose.yml` by default. If you run
Compose with a custom file set, set `COMPOSE_FILE` (for example
`COMPOSE_FILE=docker-compose.yml:docker-compose.local.yml`) either exported in
the shell that calls `backup.sh` or `restore.sh` (sourcing the Compose
environment file as above does this), or in the `.env` file in the repository
root, which Compose reads from the project directory. They then leave file
selection to Compose.

The script refuses a non-empty output directory, validates the named stack,
creates restrictive local permissions, and prints the checksum-manifest digest.
Encrypt and transfer the completed bundle using approved protected storage;
verify checksums after transfer and keep the release/image digest and
key-inventory records with the bundle. Checksums detect corruption but do not
provide authenticity or confidentiality.

Restore is limited to a fresh, named Compose project. It verifies the archive
and external crypto inventory before database changes, requires services to be
stopped, verifies an empty destination, provisions roles, restores data and
migrations, compares deployment/RLS inventories, and waits for readiness. It
will not stop a running service or remove a volume:

```sh
cd /srv/simpastil
set -a; . /secure/simpastil/compose.env; set +a
./scripts/restore.sh \
  --project simpastil-restore-drill-2026-09-25 \
  --input-dir /srv/protected-backups/simpastil-2026-09-25 \
  --jwt-public-key /secure/simpastil/jwt_public.pem \
  --totp-key /secure/simpastil/totp_encryption_key \
  --outbox-key /secure/simpastil/delivery_payload_key \
  --tls-cert /srv/simpastil/nginx/certs/cert.pem
```

Never use the production project name for a drill, point restore at a live
stack, or manually drop data to make it proceed. A refusal is a stop condition.
A drill on the same host as the live stack also needs its own
`SIMPASTIL_SUBNET` and ports, as in [Restore into a fresh
project](#restore-into-a-fresh-project).
Acceptance is a clean-stack restore followed by readiness, migration-head,
role/RLS, checksum, and domain-total comparison. Retain encrypted bundles and
matching keys according to the deployment recovery objectives.

The disposable lifecycle driver is
[`scripts/acceptance/compose-lifecycle.sh`](scripts/acceptance/compose-lifecycle.sh).

Reset and invitation requests use the single validated public origin and
transactional outbox. The API writes an encrypted, short-lived delivery payload
and the separate outbox role delivers it with bounded retries; operators see
safe delivery state, not raw links or email bodies. SMTP credentials are
worker-only. A successful API response means the request was accepted for
processing, not that mail has already reached a recipient.

API, worker, and proxy have bounded graceful shutdown with a 50-second Compose
grace period. Use normal Compose stop/restart operations and allow in-flight
requests/claims to drain. Investigate a failed readiness, migration, or shutdown
through safe codes/correlation IDs; never repair production by editing migration
state by hand.

## Troubleshooting entry points

- Not ready or a service that exits at startup: read its last log lines; the
  `msg` and the `readinessReason`, `causeKind`, `causeCode`, `configVariable`
  and `where` fields point at the cause without exposing configuration values.
- Role or RLS mismatch: stop traffic and use the provision/readiness reports;
  never point the API or the outbox worker at the superuser.
- Migration failure: preserve logs and data, identify the exact migration and
  release, and follow a forward repair. Do not mark a migration complete
  manually.
- Outbox delivery failure: inspect the bounded safe category and retry state; do
  not copy delivery tokens or message contents into diagnostics.
- Restore rejection: preserve the source bundle; confirm checksums, matching key
  fingerprints, and a genuinely fresh destination.
- Client upgrade gate: check capabilities and the enforced minimum separately
  from the artifact target. Compatibility mode does not undo ledger activation.

For signing, pinned images and artifact verification see
[RELEASE.md](docs/RELEASE.md).

## Appendix: medication ledger activation

This appendix applies to deployments that ran earlier builds in bridge mode, and
to anyone who chooses to activate the ledger. A fresh install does not need it
(see [Medication ledger on a fresh
install](#medication-ledger-on-a-fresh-install)).

The release artifact's target minimum is build 2 (a release build above it is
valid, and raising the build does not raise the target); the currently enforced
deployment minimum starts at build 1. These are separate values. Roll out the
build-2 bridge-capable client and remediated server while enforcement remains 1;
do not strand older installations by raising the gate first.

Before ledger activation, old split calls must retain durable
`sending`/acknowledged/uncertain checkpoints. The inactive server supports
atomic bridge writes and finite read-only bridge sync. It reconciles checkpoints
only from stable source IDs, backfill provenance, bounded response identity, and
current authoritative state. Exact effects can be adopted; an uncertain or
changed-base effect is a revisioned blocking issue, not a guess.

Activate only after the acceptance evidence proves complete
source/action/payload/journal coverage, no duplicates or unresolved blocking
issues, reconciled dose/stock effects and counts, and every other activation
prerequisite. The flip is exclusive and audited—never enable dual writes. After
activation, normal medication sync and commands use mapped v2. The permanent
reconciliation route remains available to devices returning from offline use; it
can adopt a proven existing effect or apply only a proven missing residual
through the native ledger against the unchanged base. It never reopens legacy
writes. Settings provides the explicit keep-verified-server-state or supported
apply-preserved-intent resolution; both are authenticated, revision-checked, and
audited.

Raise the enforced minimum to build 2 only after rollout evidence and activation
prerequisites are satisfied. The privileged command records a non-secret change
reference and cannot exceed the artifact target:

```sh
docker compose --env-file /secure/simpastil/compose.env run --rm provision set-minimum-client-build 2 --change-ref CHANGE-REFERENCE
```

The exact ledger activation authority is `activate-ledger` in the one-shot
provision command. It is one-way: take and verify a backup first, and run it
only after the acceptance evidence and the activation prerequisites above are
satisfied. The Compose `provision` service does not carry the activation inputs,
so pass them for this single run (the change reference is a non-secret ticket or
release identifier of at most 256 characters, and the build must be at least the
artifact target, 2):

```sh
docker compose --env-file /secure/simpastil/compose.env run --rm -e LEDGER_CURRENT_BUILD=2 -e LEDGER_CHANGE_REFERENCE=CHANGE-REFERENCE provision activate-ledger
```

The command runs in one transaction. It covers every pending legacy handoff
journal row, materializes scheduled occurrences, promotes complete bridge
receipts, re-checks coverage and stock reconciliation, and only then flips the
audited authority. On any unmet barrier it prints `provision.command_failed`,
exits non-zero, and changes nothing; a repeat after success is refused because
the ledger is already active. Confirm the result through `GET
/api/v1/capabilities` (`medicationLedgerActive: true`) before raising the
enforced minimum client build. Do not edit deployment authority tables directly.

Activation is one-way: there is no supported way back to the bridge. This
release has these known limits after activation:

- Undo is not offered for doses taken before activation: activation creates no
  head occurrence event for them, so neither the Today card nor the dose detail
  shows an Undo. Correct a wrong count with a stock correction. (The code keeps
  a defensive guard that leaves stock unchanged if such an undo ever reaches the
  phone; it is not a supported path.)
- The server's opening stock for a medication comes from the stock the phone
  last sent in a stock edit (its start or correct command), which waits on the
  phone until activation. The phone sends that opening as the count it shows at
  that moment, so doses taken on this phone in bridge mode are included. Doses
  from other phones are not; correct the stock after activation if the count
  differs.
- Activate only after every phone has synced, so no phone still holds unsent
  doses or stock changes from bridge mode. A phone that returns later folds its
  own bridge-era doses into its held opening count, but only the first phone to
  start stock tracking for a medication wins: any other phone's bridge-era doses
  for that medication are not counted and its start goes to review.

After activation, rollback means deploying the remediated compatibility image on
the current schema, not reverting migrations or restoring legacy writes.
Compatibility mode can relax only minimum-client rejection. Never down-migrate,
lower the immutable artifact target, delete source/checkpoint/journal data, or
route writes through both contracts.


