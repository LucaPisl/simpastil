#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-backup-common.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

fixture_root="$TMP/repository"
output_dir="$TMP/output"
mkdir -p "$fixture_root/scripts/lib" "$output_dir"
cp -- "$ROOT/scripts/lib/backup-common.sh" "$fixture_root/scripts/lib/backup-common.sh"

if ! resolved="$(bash -c '
  set -euo pipefail
  source "$1"
  backup_resolve_safe_directory "$2" "Backup output"
' _ "$fixture_root/scripts/lib/backup-common.sh" "$output_dir")"; then
  fail 'backup path validation must work in a source archive without .git metadata'
fi

[[ "$resolved" == "$output_dir" ]] || fail 'backup path validation returned an unexpected directory'
printf 'PASS: backup path validation supports source archives without Git metadata\n'

select_args() {
  bash -c '
    set -euo pipefail
    source "$1"
    backup_compose_file_args /repo
    printf "%s|" "${backup_compose_file_args[@]}"
  ' _ "$fixture_root/scripts/lib/backup-common.sh"
}

[[ "$(env -u COMPOSE_FILE bash -c "$(declare -f select_args); fixture_root='$fixture_root'; select_args")" == '-f|/repo/docker-compose.yml|' ]] \
  || fail 'without COMPOSE_FILE the repository docker-compose.yml must be selected'
[[ "$(COMPOSE_FILE=a.yml:b.yml select_args)" == "|" ]] \
  || fail 'COMPOSE_FILE must be left to Compose instead of being overridden by -f'
printf 'PASS: backup and restore honour COMPOSE_FILE and default to docker-compose.yml\n'

# COMPOSE_FILE in the repository-root .env is left to Compose as well.
env_repo="$TMP/env-repo"
mkdir -p "$env_repo"
select_in_env_repo() {
  env -u COMPOSE_FILE bash -c '
    set -euo pipefail
    source "$1"
    backup_compose_file_args "$2"
    printf "%s|" ${backup_compose_file_args[@]+"${backup_compose_file_args[@]}"}
  ' _ "$fixture_root/scripts/lib/backup-common.sh" "$env_repo"
}
printf 'POSTGRES_USER=x\nCOMPOSE_FILE=docker-compose.yml:local.yml\n' > "$env_repo/.env"
[[ "$(select_in_env_repo)" == '|' ]] \
  || fail 'COMPOSE_FILE in the repository .env must be left to Compose'
printf 'export COMPOSE_FILE=a.yml:b.yml # note\n' > "$env_repo/.env"
[[ "$(select_in_env_repo)" == '|' ]] \
  || fail 'an exported COMPOSE_FILE in .env must be left to Compose'
printf '# COMPOSE_FILE=a.yml\nCOMPOSE_FILE=\nOTHER_COMPOSE_FILE=a.yml\n' > "$env_repo/.env"
[[ "$(select_in_env_repo)" == "-f|$env_repo/docker-compose.yml|" ]] \
  || fail 'a commented, empty or look-alike COMPOSE_FILE in .env must not count'
rm -f -- "$env_repo/.env"
[[ "$(select_in_env_repo)" == "-f|$env_repo/docker-compose.yml|" ]] \
  || fail 'a missing .env must select the repository docker-compose.yml'
printf 'PASS: backup and restore honour COMPOSE_FILE from the repository .env\n'

# An empty selection must expand safely under `set -u` (bash < 4.4 treats an
# empty array as unset); the scripts use the guarded expansion.
[[ "$(bash -c '
  set -euo pipefail
  args=()
  printf "%s|" a ${args[@]+"${args[@]}"} b
')" == 'a|b|' ]] || fail 'guarded empty-array expansion must be safe under set -u'
for script in backup restore; do
  grep -qF '${backup_compose_file_args[@]+"${backup_compose_file_args[@]}"}' "$ROOT/scripts/$script.sh" \
    || fail "$script.sh must use the bash 3.2 safe expansion of backup_compose_file_args"
  if grep -qF '"${backup_compose_file_args[@]}"' "$ROOT/scripts/$script.sh" \
    && grep -F '"${backup_compose_file_args[@]}"' "$ROOT/scripts/$script.sh" | grep -vqF '+"${backup_compose_file_args[@]}"'; then
    fail "$script.sh still has an unguarded empty-array expansion"
  fi
done
printf 'PASS: empty Compose file selection expands safely on bash 3.2\n'
