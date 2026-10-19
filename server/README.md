# Simpastil server

Fastify 5 + TypeScript API for Simpastil, backed by PostgreSQL through
Drizzle. This file is a component map. Operations live in
[DEPLOYMENT.md](../DEPLOYMENT.md) (install, upgrade, backup, restore,
rollback), the development workflow in [CONTRIBUTING.md](../CONTRIBUTING.md),
and the API, sync, privacy and logging contracts in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md). Routes and schemas are
defined by the generated [`openapi/openapi.json`](openapi/openapi.json), which
is never edited by hand.

Production runs only through the Compose stack at the repository root (nginx,
API, PostgreSQL, one-shot provisioning and migration services, a
least-privilege outbox worker). Do not follow ad-hoc host installs or run
migrations or `rls-policies.sql` by hand against production.

## Layout

| Path | Contents |
| --- | --- |
| `src/app.ts`, `src/index.ts` | Fastify app factory and API entry point |
| `src/modules/` | Route, schema and service modules: `auth`, `admin`, `profiles`, `pills`, `schedules`, `dose_logs`, `sync`, `medication`, `recovery`, `capabilities`, `health` |
| `src/plugins/`, `src/lib/` | Authentication gates, safe logger, token cleanup and other shared code |
| `src/db/` | Drizzle schema, migrations (`src/db/migrations/`), provisioning, migration and operator commands |
| `src/outbox/` | Encrypted transactional outbox worker (SMTP delivery) |
| `src/commands/` | Operator commands such as the deployment manifest export |
| `src/test/` | Contract and end-to-end tests |
| `admin/` | Vue + Vite admin UI with its own lockfile and tests |
| `openapi/` | Generated OpenAPI document |

## Local development

Requires Node.js 24 (see `engines` in `package.json`), Docker and the `psql`
client. `server/docker-compose.dev.yml` (this directory) is a standalone file
that starts a throwaway PostgreSQL (service `db`, user `postgres`, password
`devpassword`, port 5432 on localhost only, or `DEV_DB_PORT` when set); it does not
start the API. The `docker-compose.dev.yml`
in the repository root is a different file: an override for the production
Compose stack, not used for local API work.

```sh
cd server
docker compose -f docker-compose.dev.yml up -d --wait
npm ci
cp .env.example .env              # local development values only
npx tsx scripts/generate-keys.ts  # prints JWT_PRIVATE_KEY / JWT_PUBLIC_KEY lines for .env
openssl rand -hex 32              # run twice: TOTP_ENC_KEY and DELIVERY_PAYLOAD_KEY
bash scripts/setup-test-db.sh     # creates the app_user role for the dev database
npm run db:migrate:dev            # applies migrations using DATABASE_URL_SUPER
npm run dev                       # tsx watch on PORT (3000 by default)
```

Development setup keeps the environment variables of `.env.example`:
`DATABASE_URL` and `DATABASE_URL_APP` (runtime `app_user`),
`DATABASE_URL_SUPER` (one-shot provisioning and migrations only), the JWT
keypair, `TOTP_ENC_KEY`, `DELIVERY_PAYLOAD_KEY`, SMTP settings and
`PUBLIC_APP_URL`. Generate a development JWT keypair with
`npx tsx scripts/generate-keys.ts` from `server/`. The database URLs in
`.env.example` already match the throwaway database. Never commit `.env`. See
[CONTRIBUTING.md](../CONTRIBUTING.md#run-a-local-api) for the full walkthrough.

### Commands

```sh
npm run build                # tsc
npm test                     # vitest via scripts/run-tests.mjs
npm run db:setup-test        # provision the disposable test database
npm test -- src/path/to/file.test.ts
npm run db:generate          # after editing src/db/schema.ts
npm run db:migrate:dev       # apply migrations with DATABASE_URL_SUPER
npm run openapi:generate     # after changing routes or their schemas
npm run openapi:check        # fails when the generated document drifts
```

Admin UI, from `server/admin/`: `npm ci`, `npm test`, `npm run build`.

Never point tests at developer, staging or production data. Commit regenerated
migrations and `openapi/openapi.json` together with their sources.
