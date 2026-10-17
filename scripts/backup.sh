#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
source "$script_dir/lib/backup-common.sh"

usage() {
  printf '%s\n' 'Usage: scripts/backup.sh --project NAME --output-dir ABSOLUTE_DIR --jwt-public-key FILE --totp-key FILE --outbox-key FILE --tls-cert FILE' >&2
  exit 2
}

project=
output_dir=
jwt_public_key=
totp_key=
outbox_key=
tls_cert=
while (($#)); do
  case "$1" in
    --project) (($# >= 2)) || usage; project=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || usage; output_dir=$2; shift 2 ;;
    --jwt-public-key) (($# >= 2)) || usage; jwt_public_key=$2; shift 2 ;;
    --totp-key) (($# >= 2)) || usage; totp_key=$2; shift 2 ;;
    --outbox-key) (($# >= 2)) || usage; outbox_key=$2; shift 2 ;;
    --tls-cert) (($# >= 2)) || usage; tls_cert=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$project" && -n "$output_dir" && -n "$jwt_public_key" && -n "$totp_key" && -n "$outbox_key" && -n "$tls_cert" ]] || usage
backup_validate_project "$project"
backup_require_command docker
backup_require_command node
backup_require_command cmp
backup_require_command sha256sum
output_dir=$(backup_resolve_safe_directory "$output_dir" 'Backup output' true)
backup_validate_empty_output_directory "$output_dir"
chmod 700 -- "$output_dir"
jwt_public_key=$(backup_resolve_readable_file "$jwt_public_key" 'JWT public key')
totp_key=$(backup_resolve_readable_file "$totp_key" 'TOTP/API-key encryption key')
outbox_key=$(backup_resolve_readable_file "$outbox_key" 'Outbox encryption key')
tls_cert=$(backup_resolve_readable_file "$tls_cert" 'TLS certificate')
"$script_dir/crypto-material-inventory.sh" \
  --jwt-public-key "$jwt_public_key" \
  --totp-key "$totp_key" \
  --outbox-key "$outbox_key" \
  --tls-cert "$tls_cert" \
  --output "$output_dir/crypto-material-inventory.json"

uid=$(id -u)
gid=$(id -g)
cd -- "$repo_root"
backup_compose_file_args "$repo_root"
compose() {
  docker compose --project-name "$project" --profile maintenance ${backup_compose_file_args[@]+"${backup_compose_file_args[@]}"} "$@"
}

running_services=$(compose ps --status running --services)
postgres_running=false
while IFS= read -r service; do
  [[ "$service" == postgres ]] && postgres_running=true
done <<< "$running_services"
[[ "$postgres_running" == true ]] || backup_fail 'The named Compose project must already have a running PostgreSQL service; backup will not initialize a new database.'

compose run --rm --no-deps --user "$uid:$gid" --volume "$output_dir:/backup:rw" backup
compose run --rm --no-deps migrate node dist/commands/export-deployment-manifest.js > "$output_dir/deployment-manifest.json"

node --input-type=module - "$output_dir" <<'NODE'
import { createHash } from 'node:crypto';
import { createReadStream, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const directory = process.argv.at(-1);
const names = [
  'crypto-material-inventory.json',
  'database.dump',
  'deployment-manifest.json',
  'role-grants-rls.json',
];
const files = [];
for (const name of names) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(join(directory, name))) hash.update(chunk);
  files.push({ name, sha256: hash.digest('hex') });
}
const deployment = JSON.parse(readFileSync(join(directory, 'deployment-manifest.json'), 'utf8'));
if (deployment.formatVersion !== 1 || !deployment.releaseId || !deployment.serverImageDigest
  || deployment.schemaVersion === undefined || deployment.contractVersion === undefined
  || !/^[a-f0-9]{64}$/i.test(deployment.migration?.headHash ?? '')) {
  throw new Error('Deployment manifest is incomplete');
}
const restoreManifest = {
  formatVersion: 1,
  createdAt: new Date().toISOString(),
  sensitive: true,
  encryption: 'not-encrypted-by-this-command',
  externalProtectionRequired: true,
  storage: 'operator-managed-outside-repository',
  source: {
    releaseId: deployment.releaseId,
    imageDigest: deployment.serverImageDigest,
    schemaVersion: deployment.schemaVersion,
    contractVersion: String(deployment.contractVersion),
    migrationHead: deployment.migration.headHash,
  },
  files,
};
writeFileSync(join(directory, 'restore-manifest.json'), `${JSON.stringify(restoreManifest, null, 2)}\n`, {
  encoding: 'utf8', mode: 0o600, flag: 'wx',
});
const manifestHash = createHash('sha256');
for await (const chunk of createReadStream(join(directory, 'restore-manifest.json'))) manifestHash.update(chunk);
files.push({ name: 'restore-manifest.json', sha256: manifestHash.digest('hex') });
const checksums = files.map(({ name, sha256 }) => `${sha256}  ${name}`).join('\n') + '\n';
writeFileSync(join(directory, 'checksums.sha256'), checksums, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
NODE

backup_verify_bundle "$output_dir"
bundle_checksum=$(sha256sum -- "$output_dir/checksums.sha256" | cut -d ' ' -f 1)
printf 'Backup bundle created at %s\nChecksum manifest SHA-256: %s\n' "$output_dir" "$bundle_checksum"
