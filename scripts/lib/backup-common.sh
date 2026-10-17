#!/usr/bin/env bash

backup_fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

backup_require_command() {
  command -v "$1" >/dev/null 2>&1 || backup_fail "Required command is unavailable: $1"
}

backup_resolve_readable_file() {
  local path=$1
  local purpose=$2
  local parent
  [[ -f "$path" && -r "$path" ]] || backup_fail "$purpose file must be readable."
  parent=$(cd -- "$(dirname -- "$path")" && pwd -P)
  printf '%s/%s\n' "$parent" "$(basename -- "$path")"
}

backup_validate_project() {
  local project=$1
  [[ "$project" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] \
    || backup_fail 'Compose project name must be an explicit lowercase name of at most 63 characters.'
}

backup_resolve_safe_directory() {
  local path=$1
  local purpose=$2
  local create=${3:-false}
  local repo_root resolved home_resolved

  [[ "$path" == /* ]] || backup_fail "$purpose directory must be an absolute path."
  [[ "$path" != *:* ]] || backup_fail "$purpose directory must not contain a colon."
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || backup_fail "$purpose directory must not contain a newline."
  [[ "$path" != '/' && ( -z "${HOME:-}" || "$path" != "$HOME" ) ]] \
    || backup_fail "$purpose directory must not be the filesystem root or home directory."
  if [[ "$create" == true ]]; then
    mkdir -p -- "$path"
  fi
  [[ -d "$path" && ! -L "$path" ]] || backup_fail "$purpose directory must exist and must not be a symlink."
  resolved=$(cd -- "$path" && pwd -P)
  repo_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

  [[ "$resolved" != '/' ]] || backup_fail "$purpose directory must not be the filesystem root."
  if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
    home_resolved=$(cd -- "$HOME" && pwd -P)
    [[ "$resolved" != "$home_resolved" ]] || backup_fail "$purpose directory must not be the home directory itself."
  fi
  [[ "$resolved" != "$repo_root" && "$resolved" != "$repo_root/"* ]] \
    || backup_fail "$purpose directory must be outside the repository."
  [[ "$repo_root" != "$resolved/"* ]] || backup_fail "$purpose directory must not contain the repository."
  printf '%s\n' "$resolved"
}

backup_validate_empty_output_directory() {
  local directory=$1
  shopt -s nullglob dotglob
  local entries=("$directory"/*)
  shopt -u nullglob dotglob
  ((${#entries[@]} == 0)) || backup_fail 'Backup output directory must be empty; refusing to overwrite an existing artifact.'
}

backup_verify_bundle() {
  local directory=$1
  if ! node --input-type=module - "$directory" <<'NODE'
import { createHash } from 'node:crypto';
import { createReadStream, lstatSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const directory = process.argv.at(-1);
const expectedNames = [
  'checksums.sha256',
  'crypto-material-inventory.json',
  'database.dump',
  'deployment-manifest.json',
  'restore-manifest.json',
  'role-grants-rls.json',
].sort();
const names = readdirSync(directory).sort();
if (JSON.stringify(names) !== JSON.stringify(expectedNames)) throw new Error('unexpected artifact set');
for (const name of expectedNames) {
  const stat = lstatSync(join(directory, name));
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) throw new Error('non-regular or empty artifact');
}

const manifest = JSON.parse(readFileSync(join(directory, 'restore-manifest.json'), 'utf8'));
if (manifest.formatVersion !== 1 || manifest.sensitive !== true
  || manifest.encryption !== 'not-encrypted-by-this-command'
  || manifest.externalProtectionRequired !== true
  || manifest.storage !== 'operator-managed-outside-repository'
  || !manifest.createdAt || !manifest.source?.releaseId || !manifest.source?.imageDigest
  || manifest.source.schemaVersion === undefined || manifest.source.contractVersion === undefined
  || !manifest.source.migrationHead) throw new Error('incomplete restore manifest');
const deployment = JSON.parse(readFileSync(join(directory, 'deployment-manifest.json'), 'utf8'));
if (deployment.formatVersion !== 1
  || manifest.source.releaseId !== deployment.releaseId
  || manifest.source.imageDigest !== deployment.serverImageDigest
  || manifest.source.schemaVersion !== deployment.schemaVersion
  || manifest.source.contractVersion !== String(deployment.contractVersion)
  || manifest.source.migrationHead !== deployment.migration?.headHash) {
  throw new Error('restore manifest does not match deployment manifest');
}
const cryptoInventory = JSON.parse(readFileSync(join(directory, 'crypto-material-inventory.json'), 'utf8'));
if (cryptoInventory.formatVersion !== 1 || !cryptoInventory.materials
  || ['jwtVerificationKey', 'totpAndApiKeyEncryption', 'outboxEnvelopeEncryption', 'tlsLeafCertificate']
    .some((key) => !/^[a-f0-9]{64}$/.test(cryptoInventory.materials[key]?.sha256 ?? '')
      || cryptoInventory.materials[key]?.keyId !== `sha256:${cryptoInventory.materials[key].sha256}`)) {
  throw new Error('invalid crypto material inventory');
}

const expectedArtifacts = [
  'crypto-material-inventory.json',
  'database.dump',
  'deployment-manifest.json',
  'role-grants-rls.json',
];
if (!Array.isArray(manifest.files) || manifest.files.length !== expectedArtifacts.length) {
  throw new Error('incomplete file manifest');
}
const actualChecksums = new Map();
for (const record of manifest.files) {
  if (!expectedArtifacts.includes(record.name) || actualChecksums.has(record.name)
    || !/^[a-f0-9]{64}$/.test(record.sha256)) throw new Error('invalid file record');
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(join(directory, record.name))) hash.update(chunk);
  const digest = hash.digest('hex');
  if (digest !== record.sha256) throw new Error('artifact checksum mismatch');
  actualChecksums.set(record.name, record.sha256);
}
if (expectedArtifacts.some((name) => !actualChecksums.has(name))) throw new Error('missing file record');

const checksumArtifactNames = [...expectedArtifacts, 'restore-manifest.json'];
const checksumLines = readFileSync(join(directory, 'checksums.sha256'), 'utf8').trim().split('\n');
if (checksumLines.length !== checksumArtifactNames.length) throw new Error('unexpected checksum entries');
const checksumNames = new Set();
for (const line of checksumLines) {
  const match = /^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$/.exec(line);
  if (!match || !checksumArtifactNames.includes(match[2]) || checksumNames.has(match[2])) {
    throw new Error('checksum list mismatch');
  }
  const actualHash = match[2] === 'restore-manifest.json'
    ? await (async () => {
      const hash = createHash('sha256');
      for await (const chunk of createReadStream(join(directory, match[2]))) hash.update(chunk);
      return hash.digest('hex');
    })()
    : actualChecksums.get(match[2]);
  if (actualHash !== match[1]) throw new Error('checksum list mismatch');
  checksumNames.add(match[2]);
}
if (checksumArtifactNames.some((name) => !checksumNames.has(name))) throw new Error('incomplete checksum list');
NODE
  then
    backup_fail 'Backup bundle validation failed; no database changes were made.'
  fi
}

# Sets backup_compose_file_args to the Compose file selection. An operator who
# sets COMPOSE_FILE, either exported in the shell or in the repository-root
# `.env` that Compose reads from the project directory, keeps that selection:
# Compose reads the variable itself, so no -f is passed. Otherwise the
# repository's docker-compose.yml is used explicitly. The scripts do not take
# an --env-file option, so a variable only present in some other env file is
# not seen.
backup_compose_file_args() {
  local repo_root=$1
  if [[ -n "${COMPOSE_FILE:-}" ]] || backup_env_file_sets_compose_file "$repo_root/.env"; then
    backup_compose_file_args=()
  else
    backup_compose_file_args=(-f "$repo_root/docker-compose.yml")
  fi
}

# True when the env file assigns a non-empty COMPOSE_FILE.
backup_env_file_sets_compose_file() {
  local env_file=$1 line
  [[ -f "$env_file" && -r "$env_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?COMPOSE_FILE=[[:space:]]*([^[:space:]#].*)$ ]]; then
      local value=${BASH_REMATCH[2]}
      [[ "$value" != '""' && "$value" != "''" ]] && return 0
    fi
  done < "$env_file"
  return 1
}
