#!/bin/sh
set -eu
umask 077

database_url=$(tr -d '\r\n' < /run/secrets/database_url_super)
[ -n "$database_url" ] || { echo 'Superuser database secret is empty.' >&2; exit 2; }
case "$database_url" in postgresql://*|postgres://*) ;; *) echo 'Restore only accepts a PostgreSQL URL for the named Compose database.' >&2; exit 2 ;; esac
url_authority=${database_url#*://}
case "$url_authority" in */*) url_authority=${url_authority%%/*} ;; *) echo 'Superuser database URL must name a database.' >&2; exit 2 ;; esac
url_host=${url_authority##*@}
case "$url_host" in postgres|postgres:5432) ;; *) echo 'Restore refuses database hosts outside the named Compose PostgreSQL service.' >&2; exit 2 ;; esac
url_query=${database_url#*\?}
if [ "$url_query" != "$database_url" ]; then
  url_query_lower=$(printf '%s' "$url_query" | tr '[:upper:]' '[:lower:]')
  case "$url_query_lower" in *%*) echo 'Restore refuses encoded PostgreSQL URL query parameters.' >&2; exit 2 ;; esac
  case "&$url_query_lower&" in *'&host='*|*'&hostaddr='*) echo 'Restore refuses PostgreSQL URL host overrides.' >&2; exit 2 ;; esac
fi

assert_empty_database() {
  local_relation_count=$(psql --dbname="$database_url" --no-psqlrc --set=ON_ERROR_STOP=1 --no-align --tuples-only \
    --command="SELECT (
      (SELECT count(*) FROM pg_catalog.pg_class AS relation JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_' AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f'))
      + (SELECT count(*) FROM pg_catalog.pg_proc AS procedure JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = procedure.pronamespace WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_')
      + (SELECT count(*) FROM pg_catalog.pg_type AS type JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = type.typnamespace WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_' AND type.typtype IN ('d', 'e', 'r'))
      + (SELECT count(*) FROM pg_catalog.pg_extension AS extension JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = extension.extnamespace WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_')
      + (SELECT count(*) FROM pg_catalog.pg_namespace WHERE nspname <> 'public' AND nspname <> 'information_schema' AND nspname !~ '^pg_')
    )::text")
  [ "$local_relation_count" = 0 ] || {
    echo 'Restore target is not empty; no archive changes were made.' >&2
    exit 3
  }
}

case "${1:-}" in
  check-archive)
    [ -f /restore/database.dump ] || { echo 'Database archive is unavailable.' >&2; exit 2; }
    pg_restore --list /restore/database.dump > /dev/null
    echo 'database_archive_readable'
    ;;
  check-empty)
    assert_empty_database
    echo 'restore_target_empty'
    ;;
  restore)
    [ -f /restore/database.dump ] || { echo 'Database archive is unavailable.' >&2; exit 2; }
    assert_empty_database
    # Do not use --clean or --no-owner: restore only into an empty DB and keep
    # the protected deployment-authority ownership recorded by pg_dump.
    pg_restore --exit-on-error --single-transaction --dbname="$database_url" /restore/database.dump
    echo 'database_archive_restored'
    ;;
  inventory)
    psql --dbname="$database_url" --no-psqlrc --set=ON_ERROR_STOP=1 --no-align --tuples-only \
      --file=/ops/role-grants-rls.sql
    ;;
  *)
    echo 'Usage: restore-database.sh check-archive|check-empty|restore|inventory' >&2
    exit 2
    ;;
esac
