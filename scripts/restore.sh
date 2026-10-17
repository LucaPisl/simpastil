#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
source "$script_dir/lib/backup-common.sh"

usage() {
  printf '%s\n' 'Usage: scripts/restore.sh --project NAME --input-dir ABSOLUTE_DIR --jwt-public-key FILE --totp-key FILE --outbox-key FILE --tls-cert FILE' >&2
  exit 2
}

project=
input_dir=
jwt_public_key=
totp_key=
outbox_key=
tls_cert=
while (($#)); do
  case "$1" in
    --project) (($# >= 2)) || usage; project=$2; shift 2 ;;
    --input-dir) (($# >= 2)) || usage; input_dir=$2; shift 2 ;;
    --jwt-public-key) (($# >= 2)) || usage; jwt_public_key=$2; shift 2 ;;
    --totp-key) (($# >= 2)) || usage; totp_key=$2; shift 2 ;;
    --outbox-key) (($# >= 2)) || usage; outbox_key=$2; shift 2 ;;
    --tls-cert) (($# >= 2)) || usage; tls_cert=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$project" && -n "$input_dir" && -n "$jwt_public_key" && -n "$totp_key" && -n "$outbox_key" && -n "$tls_cert" ]] || usage
backup_validate_project "$project"
backup_require_command docker
backup_require_command node
backup_require_command cmp
input_dir=$(backup_resolve_safe_directory "$input_dir" 'Restore input')
backup_verify_bundle "$input_dir"
jwt_public_key=$(backup_resolve_readable_file "$jwt_public_key" 'JWT public key')
totp_key=$(backup_resolve_readable_file "$totp_key" 'TOTP/API-key encryption key')
outbox_key=$(backup_resolve_readable_file "$outbox_key" 'Outbox encryption key')
tls_cert=$(backup_resolve_readable_file "$tls_cert" 'TLS certificate')

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/simpastil-restore.XXXXXXXX")
trap 'rm -rf -- "$scratch_dir"' EXIT
"$script_dir/crypto-material-inventory.sh" \
  --jwt-public-key "$jwt_public_key" \
  --totp-key "$totp_key" \
  --outbox-key "$outbox_key" \
  --tls-cert "$tls_cert" \
  --output "$scratch_dir/crypto-material-inventory.json"
if ! cmp -s -- "$input_dir/crypto-material-inventory.json" "$scratch_dir/crypto-material-inventory.json"; then
  backup_fail 'Restore refused before database changes: external crypto material does not match. Supply the archived material or recover explicitly: rotate JWT and invalidate sessions; re-enroll TOTP; clear only unrecoverable API-key reveal ciphertext while retaining hashes; expire queued one-time deliveries; or install the expected TLS certificate.'
fi

uid=$(id -u)
gid=$(id -g)
cd -- "$repo_root"
backup_compose_file_args "$repo_root"
compose() {
  docker compose --project-name "$project" --profile maintenance ${backup_compose_file_args[@]+"${backup_compose_file_args[@]}"} "$@"
}

running_services=$(compose ps --status running --services)
while IFS= read -r service; do
  [[ -z "$service" || "$service" == postgres ]] && continue
  backup_fail "Restore requires a fresh stack; service '$service' is running. This command will not stop or remove running services."
done <<< "$running_services"

compose run --rm --no-deps --user "$uid:$gid" --volume "$input_dir:/restore:ro" restore check-archive
# No volume is removed. The read-only target check precedes role provisioning.
compose up -d postgres
postgres_ready=false
for attempt in {1..30}; do
  if compose exec -T postgres pg_isready -q; then
    postgres_ready=true
    break
  fi
  sleep 2
done
[[ "$postgres_ready" == true ]] || backup_fail 'PostgreSQL did not become ready; the database was not restored.'

compose run --rm --no-deps --user "$uid:$gid" --volume "$input_dir:/restore:ro" restore check-empty
compose run --rm --no-deps provision provision
compose run --rm --no-deps --user "$uid:$gid" --volume "$input_dir:/restore:ro" restore restore
compose run --rm --no-deps migrate
compose run --rm --no-deps provision verify

compose run --rm --no-deps migrate node dist/commands/export-deployment-manifest.js > "$scratch_dir/deployment-manifest.json"
if ! cmp -s -- "$input_dir/deployment-manifest.json" "$scratch_dir/deployment-manifest.json"; then
  backup_fail 'Restore stopped before application startup: the restored deployment/migration manifest differs from the archived release.'
fi
compose run --rm --no-deps --user "$uid:$gid" --volume "$input_dir:/restore:ro" restore inventory > "$scratch_dir/role-grants-rls.json"
if ! cmp -s -- "$input_dir/role-grants-rls.json" "$scratch_dir/role-grants-rls.json"; then
  backup_fail 'Restore stopped before application startup: role grants or row-level-security policy inventory differs from the archive.'
fi

# A host-proxy install keeps the bundled nginx off (profile); naming it here
# would start it anyway.
start_services=(api outbox)
if compose config --services | grep -qx nginx; then
  start_services+=(nginx)
fi
compose up -d --wait --wait-timeout 120 "${start_services[@]}"
printf 'Restore completed for fresh Compose project %s; API readiness passed.\n' "$project"
