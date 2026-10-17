#!/usr/bin/env bash
# rollback.sh — Go back to an earlier server release on the same database.
#
# Usage:
#   scripts/rollback.sh --to VERSION [--project NAME] [--env-file PATH] [--dry-run]
#
# Run it from the checkout with the same COMPOSE_FILE (and project and env file)
# the install uses. It never changes the database:
#
#   1. It reads the database's applied migration count and compatibility floor,
#      and the migration count bundled in simpastil-server:VERSION.
#   2. If that image can serve this database (docs/decisions/migration-compatibility.md),
#      it recreates api and outbox from it with --no-build --no-deps and waits
#      until the api reports ready.
#   3. Otherwise it changes nothing and prints how to restore the matching
#      automatic pre-migration backup into a fresh Compose project.
#
# Afterwards set SIMPASTIL_VERSION=VERSION in the env file, or the next
# `docker compose up` starts the newer release again.
set -euo pipefail

fail() { printf 'rollback: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

version='' dry_run=0 compose_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    --project) [[ $# -ge 2 ]] || usage; compose_args+=(--project-name "$2"); shift 2 ;;
    --env-file) [[ $# -ge 2 ]] || usage; compose_args+=(--env-file "$2"); shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail '--to needs a release version such as 1.0.0'

compose() { docker compose "${compose_args[@]}" "$@"; }
image="simpastil-server:$version"

docker image inspect "$image" >/dev/null 2>&1 ||
  fail "$image is not on this host; build or load it first (images are kept per release tag)"
image_version="$(docker run --rm --network none --entrypoint node "$image" -p "require('/app/package.json').version")"
[[ "$image_version" == "$version" ]] || fail "$image contains release $image_version, not $version"
# A rebuild under the same version moves the tag onto the new image, so the tag
# alone cannot prove that the target differs from what is running.
running="$(compose ps --quiet api 2>/dev/null | head -n 1)"
if [[ -n "$running" ]] &&
  [[ "$(docker inspect --format '{{.Image}}' "$running")" == "$(docker image inspect --format '{{.Id}}' "$image")" ]]; then
  fail "the api already runs $image; this build replaced the earlier $version image, so there is nothing to go back to. Restore a backup instead (DEPLOYMENT.md)"
fi
image_count="$(docker run --rm --network none --entrypoint node "$image" \
  -p "require('/app/dist/db/migrations/meta/_journal.json').entries.length")"
[[ "$image_count" =~ ^[0-9]+$ ]] || fail "cannot read the bundled migrations of $image"

# The postgres container trusts its local socket, so no secret is needed here.
read -r applied floor < <(compose exec -T postgres sh -c '
  psql -X -v ON_ERROR_STOP=1 -At -F " " -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    SELECT (SELECT count(*) FROM drizzle.__drizzle_migrations),
           CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                              WHERE table_schema = '"'"'public'"'"'
                                AND table_name = '"'"'deployment_manifest'"'"'
                                AND column_name = '"'"'compatible_from_migration_count'"'"')
                THEN (SELECT compatible_from_migration_count::text FROM public.deployment_manifest WHERE singleton_key)
                ELSE NULL END"') || true
[[ "${applied:-}" =~ ^[0-9]+$ ]] || fail 'cannot read the applied migrations; is the postgres service running?'

printf 'database: %s migrations applied, compatibility floor %s\n' "$applied" "${floor:-none}"
printf 'target:   %s bundles %s migrations\n' "$image" "$image_count"

# Images before migration 0024 (count 25) only accept their exact head.
compatible=0
if [[ "$applied" == "$image_count" ]]; then
  compatible=1
elif (( image_count >= 25 && applied > image_count )) && [[ "${floor:-}" =~ ^[0-9]+$ ]] && (( floor <= image_count )); then
  compatible=1
fi

if [[ "$compatible" != 1 ]]; then
  backup_dir="$(compose config --format json 2>/dev/null | node -e '
    let input = ""; process.stdin.on("data", (c) => (input += c)).on("end", () => {
      const volumes = JSON.parse(input).services?.["premigrate-backup"]?.volumes ?? [];
      const mount = volumes.find((v) => v.target === "/backups");
      process.stdout.write(mount?.source ?? "");
    });' || true)"
  bundle=''
  if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
    bundle="$(find "$backup_dir" -maxdepth 1 -type d -name "pre-$image_count-*" -printf '%f\n' 2>/dev/null | sort | tail -n 1)"
  fi
  {
    printf '\n%s cannot serve this database: ' "$image"
    if (( applied < image_count )); then
      printf 'the database is older than the image.\n'
    elif (( image_count < 25 )); then
      printf 'images before 1.0.0 only accept their exact migration head.\n'
    else
      printf 'a breaking migration raised the floor above %s.\n' "$image_count"
    fi
    printf 'Nothing was changed. Going back means restoring a backup into a fresh Compose project.\n'
    restore_version="$version"
    if [[ -n "$bundle" ]]; then
      printf '\nNewest matching automatic backup: %s/%s\n' "$backup_dir" "$bundle"
      # The bundle records the release that last migrated the database, and a
      # restore only passes its manifest check with that same release.
      recorded="$(node -p "require(process.argv[1]).serverImageDigest ?? ''" \
        "$backup_dir/$bundle/deployment-manifest.json" 2>/dev/null || true)"
      if [[ "$recorded" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        restore_version="$recorded"
      fi
    else
      printf '\nNo automatic backup taken at %s migrations was found in %s.\n' "$image_count" "${backup_dir:-SIMPASTIL_BACKUP_DIR}"
    fi
    printf 'Follow "Restore into a fresh project" in DEPLOYMENT.md with SIMPASTIL_VERSION=%s,\n' "$restore_version"
    printf 'a new project name and a free SIMPASTIL_SUBNET and ports.\n'
  } >&2
  exit 1
fi

if [[ "$dry_run" == 1 ]]; then
  printf '\n%s can serve this database; --dry-run, so nothing was changed.\n' "$image"
  exit 0
fi

printf '\nRecreating api and outbox from %s\n' "$image"
SIMPASTIL_VERSION="$version" compose up --detach --no-build --no-deps --force-recreate api outbox

container="$(SIMPASTIL_VERSION="$version" compose ps --quiet api)"
[[ -n "$container" ]] || fail 'the api container did not start'
for _ in $(seq 1 60); do
  health="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)"
  if [[ "$health" == healthy ]]; then
    printf 'api is ready on %s.\n' "$version"
    printf 'Set SIMPASTIL_VERSION=%s in the env file so the next `docker compose up` keeps it.\n' "$version"
    exit 0
  fi
  sleep 2
done
fail "api on $version did not become ready (last health: $health); check 'docker compose logs api'"
