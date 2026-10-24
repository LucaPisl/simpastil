#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ "${SIMPASTIL_ACCEPTANCE_SCOPE:-}" == disposable-compose-restore ]] \
  || fail 'set SIMPASTIL_ACCEPTANCE_SCOPE=disposable-compose-restore to confirm the named stacks are disposable'
for tool in docker git openssl node tar cmp; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done

repo_root="$(git -C "$ROOT" rev-parse --show-toplevel)"
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
  || fail 'run this acceptance driver from a clean committed checkout'
bash "$ROOT/scripts/tests/backup-common.test.sh"

scratch="$(mktemp -d /tmp/simpastil-backup-restore.XXXXXX)"
[[ "$scratch" == /tmp/simpastil-backup-restore.* ]] || fail 'temporary directory did not match its private acceptance prefix'
chmod 700 "$scratch"
fixture_repo="$scratch/repository"
mkdir -p "$fixture_repo"
git -C "$repo_root" archive HEAD | tar -x -C "$fixture_repo"
mkdir -p "$fixture_repo/nginx/certs"

source_project="simpastil-acceptance-backup-${BASHPID}-$(date +%s)-${RANDOM}"
restore_project="simpastil-acceptance-restore-${BASHPID}-$(date +%s)-${RANDOM}"
[[ "$source_project" =~ ^simpastil-acceptance-backup-[0-9]+-[0-9]+-[0-9]+$ \
  && "$restore_project" =~ ^simpastil-acceptance-restore-[0-9]+-[0-9]+-[0-9]+$ ]] \
  || fail 'generated project names are outside the disposable namespace'
source_secrets="$scratch/source-secrets"
restore_secrets="$scratch/restore-secrets"
bundle="$scratch/backup-bundle"
source_env="$scratch/source-compose.env"
restore_env="$scratch/restore-compose.env"

assert_unused_project() {
  local project=$1
  local found
  found="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
  [[ -z "$found" ]] || fail "refusing to use an existing acceptance project: $project"
  found="$(docker volume ls -q --filter "label=com.docker.compose.project=$project")"
  [[ -z "$found" ]] || fail "refusing to use an existing acceptance volume: $project"
  found="$(docker network ls -q --filter "label=com.docker.compose.project=$project")"
  [[ -z "$found" ]] || fail "refusing to use an existing acceptance network: $project"
}

compose() {
  local project=$1
  local env_file=$2
  shift 2
  docker compose --project-name "$project" --env-file "$env_file" -f "$fixture_repo/docker-compose.yml" "$@"
}

cleanup() {
  if [[ -f "$source_env" ]]; then
    docker compose --project-name "$source_project" --env-file "$source_env" \
      -f "$fixture_repo/docker-compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -f "$restore_env" ]]; then
    docker compose --project-name "$restore_project" --env-file "$restore_env" \
      -f "$fixture_repo/docker-compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

make_secrets() {
  local directory=$1
  local env_file=$2
  local copy_from=${3:-}
  mkdir -m 700 "$directory"
  for name in postgres_password app_user_password outbox_user_password smtp_password; do
    openssl rand -hex 32 > "$directory/$name"
  done
  printf 'acceptance-user\n' > "$directory/smtp_user"
  if [[ -n "$copy_from" ]]; then
    for name in jwt_private_key jwt_public_key totp_encryption_key delivery_payload_key; do
      cp -- "$copy_from/$name" "$directory/$name"
    done
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$directory/jwt_private_key" 2>/dev/null
    openssl pkey -in "$directory/jwt_private_key" -pubout -out "$directory/jwt_public_key" 2>/dev/null
    openssl rand -hex 32 > "$directory/totp_encryption_key"
    openssl rand -hex 32 > "$directory/delivery_payload_key"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
      -keyout "$fixture_repo/nginx/certs/key.pem" \
      -out "$fixture_repo/nginx/certs/cert.pem" \
      -subj '/CN=simpastil-acceptance.invalid' >/dev/null 2>&1
  fi

  local postgres_password app_password outbox_password
  postgres_password="$(<"$directory/postgres_password")"
  app_password="$(<"$directory/app_user_password")"
  outbox_password="$(<"$directory/outbox_user_password")"
  printf 'postgresql://postgres:%s@postgres:5432/simpastil\n' "$postgres_password" > "$directory/database_url_super"
  printf 'postgresql://app_user:%s@postgres:5432/simpastil\n' "$app_password" > "$directory/database_url_app"
  printf 'postgresql://outbox_user:%s@postgres:5432/simpastil\n' "$outbox_password" > "$directory/database_url_outbox"
  unset postgres_password app_password outbox_password

  # Compose bind-mounts file-backed secrets without changing their mode. The
  # parent directory remains host-private; mounted files must be container-readable.
  chmod 0444 "$directory/postgres_password" "$directory/app_user_password" \
    "$directory/outbox_user_password" "$directory/smtp_password" \
    "$directory/smtp_user" "$directory/jwt_private_key" "$directory/jwt_public_key" \
    "$directory/totp_encryption_key" "$directory/delivery_payload_key" \
    "$directory/database_url_super" "$directory/database_url_app" \
    "$directory/database_url_outbox"

  printf '%s\n' \
    "POSTGRES_PASSWORD_FILE=$directory/postgres_password" \
    "DATABASE_URL_SUPER_FILE=$directory/database_url_super" \
    "DATABASE_URL_FILE=$directory/database_url_app" \
    "DATABASE_URL_OUTBOX_FILE=$directory/database_url_outbox" \
    "APP_USER_PASSWORD_FILE=$directory/app_user_password" \
    "OUTBOX_USER_PASSWORD_FILE=$directory/outbox_user_password" \
    "JWT_PRIVATE_KEY_FILE=$directory/jwt_private_key" \
    "JWT_PUBLIC_KEY_FILE=$directory/jwt_public_key" \
    "TOTP_ENC_KEY_FILE=$directory/totp_encryption_key" \
    "DELIVERY_PAYLOAD_KEY_FILE=$directory/delivery_payload_key" \
    "SMTP_USER_FILE=$directory/smtp_user" \
    "SMTP_PASS_FILE=$directory/smtp_password" \
    'POSTGRES_USER=postgres' \
    'POSTGRES_DB=simpastil' \
    'PUBLIC_APP_URL=https://simpastil.example.invalid' \
    'CORS_ORIGIN=https://simpastil.example.invalid' \
    'SMTP_HOST=127.0.0.1' \
    'SMTP_PORT=2525' \
    'SMTP_FROM=acceptance@example.invalid' \
    'SHUTDOWN_TIMEOUT_MS=10000' \
    'OUTBOX_SHUTDOWN_TIMEOUT_MS=10000' > "$env_file"
  chmod 600 "$env_file"
}

wait_for_ready() {
  local project=$1
  local env_file=$2
  local ready=false
  for _ in $(seq 1 60); do
    if compose "$project" "$env_file" exec -T api node --input-type=module -e \
      'const response = await fetch("http://127.0.0.1:8080/api/v1/health/ready"); process.exit(response.status === 200 ? 0 : 1);' \
      >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  [[ "$ready" == true ]] || fail "API readiness failed for isolated project $project"
}

count_acceptance_rows() {
  local project=$1
  local env_file=$2
  compose "$project" "$env_file" exec -T postgres psql -At -v ON_ERROR_STOP=1 \
    -U postgres -d simpastil -F ':' -c \
    "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM profiles), (SELECT count(*) FROM pills), (SELECT count(*) FROM schedules), (SELECT count(*) FROM dose_logs), (SELECT count(*) FROM inventory_events), (SELECT count(*) FROM password_reset_tokens), (SELECT count(*) FROM invitation_tokens), (SELECT count(*) FROM outbox_messages), (SELECT count(*) FROM migration_issues), (SELECT count(*) FROM api_keys), (SELECT count(*) FROM deployment_manifest), (SELECT count(*) FROM backup_codes), (SELECT count(*) FROM refresh_tokens), (SELECT count(*) FROM medication_handoff_journal), (SELECT count(*) FROM sync_changes)"
}

capture_acceptance_state() {
  local project=$1
  local env_file=$2
  compose "$project" "$env_file" exec -T postgres psql -XAtq -v ON_ERROR_STOP=1 -U postgres -d simpastil <<'SQL'
SELECT jsonb_build_object(
  'users', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, email, session_version::text, totp_enabled, totp_secret IS NOT NULL) ORDER BY id) FROM users), '[]'::jsonb),
  'backupCodes', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text) ORDER BY id) FROM backup_codes), '[]'::jsonb),
  'refreshTokens', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, family_id::text, expires_at::text, revoked) ORDER BY id) FROM refresh_tokens), '[]'::jsonb),
  'profiles', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, name, is_active) ORDER BY id) FROM profiles), '[]'::jsonb),
  'pills', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, profile_id::text, name, current_stock, low_stock_threshold) ORDER BY id) FROM pills), '[]'::jsonb),
  'schedules', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, pill_id::text, frequency, hour, minute, is_active, time_zone_status, time_zone) ORDER BY id) FROM schedules), '[]'::jsonb),
  'doseLogs', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, schedule_id::text, status, scheduled_at::text, taken_at::text) ORDER BY id) FROM dose_logs), '[]'::jsonb),
  'inventoryEvents', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, pill_id::text, kind, delta, server_sequence::text) ORDER BY id) FROM inventory_events), '[]'::jsonb),
  'apiKeys', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, label, encrypted_key IS NOT NULL, revoked_at::text) ORDER BY id) FROM api_keys), '[]'::jsonb),
  'passwordResets', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, expires_at::text, used) ORDER BY id) FROM password_reset_tokens), '[]'::jsonb),
  'invitations', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, recipient_email, api_key_id::text, expires_at::text, consumed_at IS NOT NULL, revoked_at IS NOT NULL) ORDER BY id) FROM invitation_tokens), '[]'::jsonb),
  'outbox', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, message_type, recipient_ref, state, attempt_count, encrypted_delivery_payload IS NOT NULL, next_attempt_at::text, expires_at::text) ORDER BY id) FROM outbox_messages), '[]'::jsonb),
  'migrationIssues', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, entity_type, entity_id::text, issue_code, revision::text, state, safe_snapshot) ORDER BY id) FROM migration_issues), '[]'::jsonb),
  'handoffJournal', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, journal_sequence::text, command_bundle_id::text, subeffect_ordinal, subeffect_kind, legacy_source_kind, legacy_source_id::text, source_revision::text, coverage_state) ORDER BY user_id, journal_sequence) FROM medication_handoff_journal), '[]'::jsonb),
  'syncChanges', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, user_id::text, component, entity_type, entity_id::text, operation, source_kind, source_id::text, source_revision::text, server_sequence::text) ORDER BY user_id, server_sequence) FROM sync_changes), '[]'::jsonb),
  'manifest', COALESCE((SELECT jsonb_agg(jsonb_build_array(id::text, schema_version, contract_version::text, ledger_activated, enforced_minimum_client_build, target_minimum_client_build, release_id, server_image_digest, migration_completed_at::text) ORDER BY id) FROM deployment_manifest), '[]'::jsonb)
)::text;
SQL
}

hash_api_key() {
  ACCEPTANCE_API_KEY="$1" node --input-type=module <<'NODE'
import { createHash } from 'node:crypto';
process.stdout.write(createHash('sha256').update(process.env.ACCEPTANCE_API_KEY).digest('hex'));
NODE
}

assert_inventory_projection() {
  local project=$1
  local env_file=$2
  local mismatches
  mismatches="$(compose "$project" "$env_file" exec -T postgres psql -At -v ON_ERROR_STOP=1 -U postgres -d simpastil -c \
    "SELECT count(*) FROM pills p JOIN profiles pr ON pr.id = p.profile_id WHERE p.current_stock IS DISTINCT FROM (SELECT COALESCE(sum(event.delta), 0) FROM inventory_events event WHERE event.user_id = pr.user_id AND event.pill_id = p.id)")"
  [[ "$mismatches" == 0 ]] || fail "pill stock does not match its preserved inventory-event projection in $project"
}

read_api_key_ciphertext() {
  compose "$1" "$2" exec -T postgres psql -XAtq -v ON_ERROR_STOP=1 \
    -v user_id="$3" -v key_label="$4" -U postgres -d simpastil <<'SQL'
SELECT encrypted_key FROM api_keys WHERE user_id = :'user_id'::uuid AND label = :'key_label';
SQL
}

read_outbox_ciphertext() {
  compose "$1" "$2" exec -T postgres psql -XAtq -v ON_ERROR_STOP=1 \
    -v outbox_id="$3" -U postgres -d simpastil <<'SQL'
SELECT encrypted_delivery_payload FROM outbox_messages WHERE id = :'outbox_id'::uuid;
SQL
}

seal_value() {
  local key_file=$1
  local plaintext=$2
  ACCEPTANCE_ENCRYPTION_KEY="$(<"$key_file")" ACCEPTANCE_PLAINTEXT="$plaintext" node --input-type=module <<'NODE'
import { createCipheriv, randomBytes } from 'node:crypto';
const key = Buffer.from(process.env.ACCEPTANCE_ENCRYPTION_KEY, 'hex');
if (key.length !== 32) process.exit(2);
const iv = randomBytes(12);
const cipher = createCipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
const ciphertext = Buffer.concat([cipher.update(process.env.ACCEPTANCE_PLAINTEXT, 'utf8'), cipher.final()]);
process.stdout.write(`${iv.toString('base64')}:${ciphertext.toString('base64')}:${cipher.getAuthTag().toString('base64')}`);
NODE
}

assert_sealed_value() {
  local key_file=$1
  local ciphertext=$2
  local expected=$3
  ACCEPTANCE_ENCRYPTION_KEY="$(<"$key_file")" ACCEPTANCE_CIPHERTEXT="$ciphertext" \
    ACCEPTANCE_EXPECTED="$expected" node --input-type=module <<'NODE'
import { createDecipheriv } from 'node:crypto';
try {
  const key = Buffer.from(process.env.ACCEPTANCE_ENCRYPTION_KEY, 'hex');
  const [iv, body, tag] = process.env.ACCEPTANCE_CIPHERTEXT.split(':').map((part) => Buffer.from(part, 'base64'));
  if (key.length !== 32 || !iv || !body || !tag) process.exit(1);
  const decipher = createDecipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
  decipher.setAuthTag(tag);
  const plaintext = decipher.update(body) + decipher.final('utf8');
  if (plaintext !== process.env.ACCEPTANCE_EXPECTED) process.exit(1);
} catch {
  process.exit(1);
}
NODE
}

assert_project_resources_absent() {
  local project=$1
  local found
  found="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
  [[ -z "$found" ]] || fail "disposable source containers remain after destruction: $project"
  found="$(docker volume ls -q --filter "label=com.docker.compose.project=$project")"
  [[ -z "$found" ]] || fail "disposable source volumes remain after destruction: $project"
  found="$(docker network ls -q --filter "label=com.docker.compose.project=$project")"
  [[ -z "$found" ]] || fail "disposable source networks remain after destruction: $project"
}

exercise_auth_and_totp() {
  local project=$1
  local env_file=$2
  local mode=$3
  local api_key_a=$4
  local api_key_b=$5
  local password=$6
  local totp_secret=${7:-}
  compose "$project" "$env_file" exec -T \
    -e "ACCEPTANCE_API_KEY_A=$api_key_a" \
    -e "ACCEPTANCE_API_KEY_B=$api_key_b" \
    -e "ACCEPTANCE_PASSWORD=$password" \
    -e "ACCEPTANCE_TOTP_SECRET=$totp_secret" \
    -e "ACCEPTANCE_MODE=$mode" api node --input-type=module - <<'NODE'
import { TOTP, Secret } from 'otpauth';

const base = 'http://127.0.0.1:8080/api/v1';
const emailA = 'restore-a@example.invalid';
const emailB = 'restore-b@example.invalid';
const password = process.env.ACCEPTANCE_PASSWORD;
const keyA = process.env.ACCEPTANCE_API_KEY_A;
const keyB = process.env.ACCEPTANCE_API_KEY_B;

async function post(path, apiKey, payload, accessToken) {
  const headers = { 'x-api-key': apiKey };
  if (payload !== undefined) headers['content-type'] = 'application/json';
  if (accessToken) headers.authorization = `Bearer ${accessToken}`;
  const response = await fetch(`${base}${path}`, {
    method: 'POST', headers, ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
  });
  let body;
  try { body = await response.json(); } catch { body = {}; }
  if (!response.ok) throw new Error(`${path} returned ${response.status} (${body.error?.code ?? body.code ?? 'no-code'})`);
  return body;
}

async function login(email, apiKey) {
  return post('/auth/login', apiKey, { email, password });
}

if (process.env.ACCEPTANCE_MODE === 'seed') {
  await post('/auth/register', keyA, { email: emailA, password });
  await post('/auth/register', keyB, { email: emailB, password });
  const initial = await login(emailA, keyA);
  if (!initial.accessToken) throw new Error('user A initial login did not return an access token');
  const setup = await post('/auth/2fa/setup', keyA, undefined, initial.accessToken);
  const secret = setup.secret;
  if (typeof secret !== 'string' || !secret) throw new Error('TOTP setup returned no secret');
  const code = new TOTP({ issuer: 'Simpastil', label: emailA, secret: Secret.fromBase32(secret), digits: 6, period: 30 }).generate();
  await post('/auth/2fa/enable', keyA, { code }, initial.accessToken);
  const userB = await login(emailB, keyB);
  if (!userB.accessToken || !userB.refreshToken || userB.requires2fa) throw new Error('source user B API-key authentication did not return sessions');
  console.log(JSON.stringify({ ok: true, totpSecret: secret }));
} else if (process.env.ACCEPTANCE_MODE === 'restore') {
  const challenge = await login(emailA, keyA);
  if (challenge.requires2fa !== true || !challenge.challengeToken) throw new Error('restored user A login did not require TOTP');
  const secret = process.env.ACCEPTANCE_TOTP_SECRET;
  if (!secret) throw new Error('restored TOTP fixture seed is unavailable');
  const code = new TOTP({ issuer: 'Simpastil', label: emailA, secret: Secret.fromBase32(secret), digits: 6, period: 30 }).generate();
  const tokens = await post('/auth/2fa/challenge', keyA, { challengeToken: challenge.challengeToken, code });
  if (!tokens.accessToken || !tokens.refreshToken) throw new Error('restored TOTP challenge did not return sessions');
  const userB = await login(emailB, keyB);
  if (!userB.accessToken || !userB.refreshToken || userB.requires2fa) throw new Error('restored user B API-key authentication did not return sessions');
  console.log(JSON.stringify({ ok: true }));
} else {
  throw new Error('unknown fixture auth mode');
}
NODE
}

assert_unused_project "$source_project"
assert_unused_project "$restore_project"
make_secrets "$source_secrets" "$source_env"
make_secrets "$restore_secrets" "$restore_env" "$source_secrets"
openssl rand -hex 32 > "$source_secrets/api_key_a"
openssl rand -hex 32 > "$source_secrets/api_key_b"
openssl rand -hex 24 > "$scratch/fixture_password"
chmod 600 "$source_secrets/api_key_a" "$source_secrets/api_key_b" "$scratch/fixture_password"
source_api_key_a="$(<"$source_secrets/api_key_a")"
source_api_key_b="$(<"$source_secrets/api_key_b")"
fixture_password="$(<"$scratch/fixture_password")"
for name in postgres_password app_user_password outbox_user_password; do
  if cmp -s -- "$source_secrets/$name" "$restore_secrets/$name"; then
    fail "restore stack must use a fresh $name"
  fi
done

compose "$source_project" "$source_env" up --detach --build api outbox nginx
wait_for_ready "$source_project" "$source_env"
api_key_hash_a="$(hash_api_key "$source_api_key_a")"
api_key_hash_b="$(hash_api_key "$source_api_key_b")"
compose "$source_project" "$source_env" exec -T postgres psql -v ON_ERROR_STOP=1 \
  -v key_hash_a="$api_key_hash_a" -v key_hash_b="$api_key_hash_b" \
  -U postgres -d simpastil <<'SQL' >/dev/null
INSERT INTO api_keys (id, user_id, key_hash, label) VALUES
  ('91000000-0000-4000-8000-000000000001', NULL, :'key_hash_a', 'restore-fixture-a'),
  ('91000000-0000-4000-8000-000000000002', NULL, :'key_hash_b', 'restore-fixture-b');
SQL

auth_seed_result="$(exercise_auth_and_totp "$source_project" "$source_env" seed \
  "$source_api_key_a" "$source_api_key_b" "$fixture_password")"
fixture_totp_secret="$(ACCEPTANCE_AUTH_RESULT="$auth_seed_result" node --input-type=module <<'NODE'
const result = JSON.parse(process.env.ACCEPTANCE_AUTH_RESULT);
if (result.ok !== true || typeof result.totpSecret !== 'string' || !result.totpSecret) process.exit(1);
process.stdout.write(result.totpSecret);
NODE
)"

source_user_a="$(compose "$source_project" "$source_env" exec -T postgres psql -At -v ON_ERROR_STOP=1 -U postgres -d simpastil -c "SELECT id FROM users WHERE email = 'restore-a@example.invalid'")"
source_user_b="$(compose "$source_project" "$source_env" exec -T postgres psql -At -v ON_ERROR_STOP=1 -U postgres -d simpastil -c "SELECT id FROM users WHERE email = 'restore-b@example.invalid'")"
[[ "$source_user_a" =~ ^[0-9a-f-]{36}$ && "$source_user_b" =~ ^[0-9a-f-]{36}$ && "$source_user_a" != "$source_user_b" ]] \
  || fail 'source fixture did not create two distinct tenant accounts'

encrypted_api_key_a="$(seal_value "$source_secrets/totp_encryption_key" "$source_api_key_a")"
encrypted_api_key_b="$(seal_value "$source_secrets/totp_encryption_key" "$source_api_key_b")"
outbox_payload_a='{"purpose":"acceptance","tenant":"a","token":"fixture-a"}'
outbox_payload_b='{"purpose":"acceptance","tenant":"b","token":"fixture-b"}'
encrypted_outbox_a="$(seal_value "$source_secrets/delivery_payload_key" "$outbox_payload_a")"
encrypted_outbox_b="$(seal_value "$source_secrets/delivery_payload_key" "$outbox_payload_b")"
compose "$source_project" "$source_env" exec -T postgres psql -v ON_ERROR_STOP=1 \
  -v user_a="$source_user_a" -v user_b="$source_user_b" \
  -v encrypted_api_key_a="$encrypted_api_key_a" -v encrypted_api_key_b="$encrypted_api_key_b" \
  -v encrypted_outbox_a="$encrypted_outbox_a" -v encrypted_outbox_b="$encrypted_outbox_b" \
  -U postgres -d simpastil <<'SQL' >/dev/null
BEGIN;
SELECT set_config('app.current_user_id', :'user_a', true);
UPDATE api_keys SET encrypted_key = :'encrypted_api_key_a' WHERE user_id = :'user_a'::uuid AND label = 'restore-fixture-a';
INSERT INTO profiles (id, user_id, name, avatar_emoji) VALUES
  ('92000000-0000-4000-8000-000000000001', :'user_a'::uuid, 'Tenant A profile', '🅰️');
INSERT INTO pills (id, profile_id, name, dosage, current_stock, low_stock_threshold) VALUES
  ('93000000-0000-4000-8000-000000000001', '92000000-0000-4000-8000-000000000001', 'Fixture medicine A', '10 mg', 9, 2);
INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, time_zone_status, time_zone) VALUES
  ('94000000-0000-4000-8000-000000000001', '93000000-0000-4000-8000-000000000001', 8, 0, 'daily', NULL, 'known', 'UTC');
INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, note) VALUES
  ('95000000-0000-4000-8000-000000000001', '94000000-0000-4000-8000-000000000001', now() - interval '1 day', now() - interval '1 day' + interval '10 minutes', 'taken', 'acceptance history A');
INSERT INTO inventory_events (id, user_id, pill_id, command_id, kind, delta, provenance, server_sequence, note) VALUES
  ('96000000-0000-4000-8000-000000000001', :'user_a'::uuid, '93000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000001', 'opening', 10, 'legacy_backfill', 1, 'opening stock'),
  ('96000000-0000-4000-8000-000000000002', :'user_a'::uuid, '93000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000002', 'dose', -1, 'legacy_backfill', 2, 'historical dose');
INSERT INTO migration_issues (id, user_id, entity_type, entity_id, issue_code, safe_snapshot) VALUES
  ('97000000-0000-4000-8000-000000000001', :'user_a'::uuid, 'schedule', '94000000-0000-4000-8000-000000000001', 'legacy_timezone_review', '{"origin":"acceptance-fixture","tenant":"a"}'::jsonb);
INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, used) VALUES
  ('98000000-0000-4000-8000-000000000001', :'user_a'::uuid, repeat('a', 64), now() + interval '30 days', false);
INSERT INTO invitation_tokens (id, token_hash, recipient_email, api_key_id, expires_at) VALUES
  ('99000000-0000-4000-8000-000000000001', repeat('c', 64), 'invite-a@example.invalid', '91000000-0000-4000-8000-000000000001', now() + interval '30 days');
INSERT INTO outbox_messages (id, message_type, recipient_ref, encrypted_delivery_payload, state, next_attempt_at, expires_at) VALUES
  ('a1000000-0000-4000-8000-000000000001', 'password_reset', 'restore-a@example.invalid', :'encrypted_outbox_a', 'queued', '2099-01-01T00:00:00Z', '2099-02-01T00:00:00Z');

SELECT set_config('app.current_user_id', :'user_b', true);
UPDATE api_keys SET encrypted_key = :'encrypted_api_key_b' WHERE user_id = :'user_b'::uuid AND label = 'restore-fixture-b';
INSERT INTO profiles (id, user_id, name, avatar_emoji) VALUES
  ('92000000-0000-4000-8000-000000000002', :'user_b'::uuid, 'Tenant B profile', '🅱️');
INSERT INTO pills (id, profile_id, name, dosage, current_stock, low_stock_threshold) VALUES
  ('93000000-0000-4000-8000-000000000002', '92000000-0000-4000-8000-000000000002', 'Fixture medicine B', '20 mg', 9, 3);
INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, time_zone_status, time_zone) VALUES
  ('94000000-0000-4000-8000-000000000002', '93000000-0000-4000-8000-000000000002', 20, 30, 'daily', NULL, 'known', 'UTC');
INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, note) VALUES
  ('95000000-0000-4000-8000-000000000002', '94000000-0000-4000-8000-000000000002', now() - interval '2 days', now() - interval '2 days' + interval '5 minutes', 'taken', 'acceptance history B');
INSERT INTO inventory_events (id, user_id, pill_id, command_id, kind, delta, provenance, server_sequence, note) VALUES
  ('96000000-0000-4000-8000-000000000003', :'user_b'::uuid, '93000000-0000-4000-8000-000000000002', '96100000-0000-4000-8000-000000000003', 'opening', 10, 'legacy_backfill', 1, 'opening stock'),
  ('96000000-0000-4000-8000-000000000004', :'user_b'::uuid, '93000000-0000-4000-8000-000000000002', '96100000-0000-4000-8000-000000000004', 'dose', -1, 'legacy_backfill', 2, 'historical dose');
INSERT INTO migration_issues (id, user_id, entity_type, entity_id, issue_code, safe_snapshot) VALUES
  ('97000000-0000-4000-8000-000000000002', :'user_b'::uuid, 'schedule', '94000000-0000-4000-8000-000000000002', 'legacy_timezone_review', '{"origin":"acceptance-fixture","tenant":"b"}'::jsonb);
INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, used) VALUES
  ('98000000-0000-4000-8000-000000000002', :'user_b'::uuid, repeat('b', 64), now() - interval '1 day', true);
INSERT INTO invitation_tokens (id, token_hash, recipient_email, api_key_id, expires_at, consumed_at) VALUES
  ('99000000-0000-4000-8000-000000000002', repeat('d', 64), 'invite-b@example.invalid', '91000000-0000-4000-8000-000000000002', now() + interval '30 days', now());
INSERT INTO outbox_messages (id, message_type, recipient_ref, encrypted_delivery_payload, state, attempt_count, safe_error_category, next_attempt_at, expires_at) VALUES
  ('a1000000-0000-4000-8000-000000000002', 'invitation', 'restore-b@example.invalid', :'encrypted_outbox_b', 'retrying', 1, 'smtp_unavailable', '2099-01-01T00:00:00Z', '2099-02-01T00:00:00Z');
COMMIT;
SQL

source_counts="$(count_acceptance_rows "$source_project" "$source_env")"
[[ "$source_counts" == 2:2:2:2:2:4:2:2:2:2:2:1:8:2:4:7 ]] \
  || fail "disposable source fixture row matrix is incomplete (got $source_counts)"
assert_inventory_projection "$source_project" "$source_env"
source_state="$(capture_acceptance_state "$source_project" "$source_env")"

for tenant in a b; do
  if [[ "$tenant" == a ]]; then user_id=$source_user_a; expected_key=$source_api_key_a; label=restore-fixture-a; expected_outbox=$outbox_payload_a; outbox_id=a1000000-0000-4000-8000-000000000001
  else user_id=$source_user_b; expected_key=$source_api_key_b; label=restore-fixture-b; expected_outbox=$outbox_payload_b; outbox_id=a1000000-0000-4000-8000-000000000002
  fi
  api_cipher="$(read_api_key_ciphertext "$source_project" "$source_env" "$user_id" "$label")"
  assert_sealed_value "$source_secrets/totp_encryption_key" "$api_cipher" "$expected_key" \
    || fail "source API-key reveal ciphertext is not usable for tenant $tenant"
  outbox_cipher="$(read_outbox_ciphertext "$source_project" "$source_env" "$outbox_id")"
  assert_sealed_value "$source_secrets/delivery_payload_key" "$outbox_cipher" "$expected_outbox" \
    || fail "source queued outbox payload is not decryptable for tenant $tenant"
done

set -a
source "$source_env"
set +a
"$fixture_repo/scripts/backup.sh" \
  --project "$source_project" \
  --output-dir "$bundle" \
  --jwt-public-key "$source_secrets/jwt_public_key" \
  --totp-key "$source_secrets/totp_encryption_key" \
  --outbox-key "$source_secrets/delivery_payload_key" \
  --tls-cert "$fixture_repo/nginx/certs/cert.pem"
unset POSTGRES_PASSWORD_FILE DATABASE_URL_SUPER_FILE DATABASE_URL_FILE DATABASE_URL_OUTBOX_FILE \
  APP_USER_PASSWORD_FILE OUTBOX_USER_PASSWORD_FILE JWT_PRIVATE_KEY_FILE JWT_PUBLIC_KEY_FILE \
  TOTP_ENC_KEY_FILE DELIVERY_PAYLOAD_KEY_FILE SMTP_USER_FILE SMTP_PASS_FILE

# The bundle is complete; destroy only the explicitly named disposable source stack and its volume.
compose "$source_project" "$source_env" down --volumes --remove-orphans
assert_project_resources_absent "$source_project"
set -a
source "$restore_env"
set +a
"$fixture_repo/scripts/restore.sh" \
  --project "$restore_project" \
  --input-dir "$bundle" \
  --jwt-public-key "$restore_secrets/jwt_public_key" \
  --totp-key "$restore_secrets/totp_encryption_key" \
  --outbox-key "$restore_secrets/delivery_payload_key" \
  --tls-cert "$fixture_repo/nginx/certs/cert.pem"

wait_for_ready "$restore_project" "$restore_env"
restore_counts="$(count_acceptance_rows "$restore_project" "$restore_env")"
[[ "$restore_counts" == "$source_counts" ]] || fail 'clean restore row counts or tenant state differ from the source backup'
assert_inventory_projection "$restore_project" "$restore_env"
restore_state="$(capture_acceptance_state "$restore_project" "$restore_env")"
[[ "$restore_state" == "$source_state" ]] || fail 'clean restore IDs, auth state, medication history, stock, or operational states differ from the source backup'

for tenant in a b; do
  if [[ "$tenant" == a ]]; then user_id=$source_user_a; expected_key=$source_api_key_a; label=restore-fixture-a; expected_outbox=$outbox_payload_a; outbox_id=a1000000-0000-4000-8000-000000000001
  else user_id=$source_user_b; expected_key=$source_api_key_b; label=restore-fixture-b; expected_outbox=$outbox_payload_b; outbox_id=a1000000-0000-4000-8000-000000000002
  fi
  api_cipher="$(read_api_key_ciphertext "$restore_project" "$restore_env" "$user_id" "$label")"
  assert_sealed_value "$restore_secrets/totp_encryption_key" "$api_cipher" "$expected_key" \
    || fail "restored API-key reveal ciphertext is not usable for tenant $tenant"
  outbox_cipher="$(read_outbox_ciphertext "$restore_project" "$restore_env" "$outbox_id")"
  assert_sealed_value "$restore_secrets/delivery_payload_key" "$outbox_cipher" "$expected_outbox" \
    || fail "restored queued outbox payload is not decryptable for tenant $tenant"
done

auth_restore_result="$(exercise_auth_and_totp "$restore_project" "$restore_env" restore \
  "$source_api_key_a" "$source_api_key_b" "$fixture_password" "$fixture_totp_secret")"
[[ "$(ACCEPTANCE_AUTH_RESULT="$auth_restore_result" node --input-type=module -e 'process.stdout.write(JSON.parse(process.env.ACCEPTANCE_AUTH_RESULT).ok === true ? "pass" : "fail")')" == pass ]] \
  || fail 'restored API-key login or working TOTP challenge failed'

ACCEPTANCE_SOURCE_PROJECT="$source_project" ACCEPTANCE_RESTORE_PROJECT="$restore_project" \
  ACCEPTANCE_ROW_COUNTS="$restore_counts" node --input-type=module <<'NODE'
const names = ['users', 'profiles', 'pills', 'schedules', 'doseLogs', 'inventoryEvents', 'passwordResetTokens', 'invitationTokens', 'outboxMessages', 'migrationIssues', 'apiKeys', 'deploymentManifest', 'backupCodes', 'refreshTokens', 'handoffJournal', 'syncChanges'];
const values = process.env.ACCEPTANCE_ROW_COUNTS.split(':').map(Number);
if (values.length !== names.length || values.some((value) => !Number.isSafeInteger(value))) process.exit(1);
const rowCounts = Object.fromEntries(names.map((name, index) => [name, values[index]]));
console.log(JSON.stringify({
  formatVersion: 1,
  scenario: 'two-tenant-disposable-compose-backup-clean-restore',
  result: 'pass',
  sourceProject: process.env.ACCEPTANCE_SOURCE_PROJECT,
  restoreProject: process.env.ACCEPTANCE_RESTORE_PROJECT,
  sourceStackAndVolumeDestroyedBeforeRestore: true,
  rowCounts,
  checks: {
    sourceAndRestoreHaveTwoTenants: true,
    rowIdsAndEffectiveStatesMatch: true,
    medicationHistoryAndInventoryProjectionMatch: true,
    resetInvitationOutboxAndMigrationIssueStatesMatch: true,
    externalApiKeyAndOutboxCiphertextsRemainUsable: true,
    apiKeyAuthenticationAndTotpChallengeWorkAfterRestore: true,
    runtimeRolePasswordsWereRotated: true,
    manifestAndRoleRlsPostureWereVerified: true,
    restoredApiReadinessPassed: true,
  },
  encryptionAndAccessControl: 'operator-owned; backup storage must remain encrypted and access-controlled outside Git',
}));
NODE
