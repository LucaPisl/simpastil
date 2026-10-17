#!/usr/bin/env bash
# One-time setup: create the app_user role and grant it access.
# Run this once after `docker compose -f docker-compose.dev.yml up -d`.
#
# Usage: bash scripts/setup-test-db.sh [db_password]
#   db_password defaults to 'devpassword' (matches docker-compose.dev.yml)
#   DB_PORT defaults to DEV_DB_PORT (the port docker-compose.dev.yml publishes), then 5432

set -euo pipefail

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-${DEV_DB_PORT:-5432}}"
DB_NAME="${DB_NAME:-simpastil}"
DB_SUPER_USER="${DB_SUPER_USER:-postgres}"
DB_SUPER_PASS="${DB_SUPER_PASS:-devpassword}"
APP_USER_PASS="${1:-devpassword}"

export PGPASSWORD="$DB_SUPER_PASS"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_SUPER_USER" -d "$DB_NAME" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT LOGIN;
  END IF;
END;
\$\$;

ALTER ROLE app_user PASSWORD '$APP_USER_PASS';
GRANT CONNECT ON DATABASE $DB_NAME TO app_user;
SQL

echo "✓ app_user role configured."
echo ""
echo "Now run tests with:"
echo "  DATABASE_URL_SUPER=postgresql://postgres:${DB_SUPER_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME} \\"
echo "  DATABASE_URL_APP=postgresql://app_user:${APP_USER_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME} \\"
echo "  npm test"
