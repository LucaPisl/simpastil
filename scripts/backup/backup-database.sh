#!/bin/sh
set -eu
umask 077

database_url=$(tr -d '\r\n' < /run/secrets/database_url_super)
[ -n "$database_url" ] || { echo 'Superuser database secret is empty.' >&2; exit 2; }
case "$database_url" in postgresql://*|postgres://*) ;; *) echo 'Backup only accepts a PostgreSQL URL for the named Compose database.' >&2; exit 2 ;; esac
url_authority=${database_url#*://}
case "$url_authority" in */*) url_authority=${url_authority%%/*} ;; *) echo 'Superuser database URL must name a database.' >&2; exit 2 ;; esac
url_host=${url_authority##*@}
case "$url_host" in postgres|postgres:5432) ;; *) echo 'Backup refuses database hosts outside the named Compose PostgreSQL service.' >&2; exit 2 ;; esac
url_query=${database_url#*\?}
if [ "$url_query" != "$database_url" ]; then
  url_query_lower=$(printf '%s' "$url_query" | tr '[:upper:]' '[:lower:]')
  case "$url_query_lower" in *%*) echo 'Backup refuses encoded PostgreSQL URL query parameters.' >&2; exit 2 ;; esac
  case "&$url_query_lower&" in *'&host='*|*'&hostaddr='*) echo 'Backup refuses PostgreSQL URL host overrides.' >&2; exit 2 ;; esac
fi
[ -d /backup ] && [ -w /backup ] || { echo 'Backup mount is unavailable.' >&2; exit 2; }

# Preserve object owners and ACLs; cluster roles are provisioned separately.
pg_dump --dbname="$database_url" --format=custom --compress=6 --file=/backup/database.dump
psql --dbname="$database_url" --no-psqlrc --set=ON_ERROR_STOP=1 --no-align --tuples-only \
  --file=/ops/role-grants-rls.sql > /backup/role-grants-rls.json
