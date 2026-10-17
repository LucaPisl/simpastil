#!/usr/bin/env bash
set -euo pipefail

# Load local server env vars.
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -z "${DATABASE_URL_SUPER:-}" ]]; then
  echo "DATABASE_URL_SUPER is not set in server/.env"
  exit 1
fi

# Run migrations with elevated DB role, without changing runtime DATABASE_URL.
DATABASE_URL="${DATABASE_URL_SUPER}" ./node_modules/.bin/drizzle-kit migrate
