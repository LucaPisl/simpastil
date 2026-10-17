#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${SIMPASTIL_ACCEPTANCE_SCOPE:-}" == disposable-compose ]] || {
  printf 'Set SIMPASTIL_ACCEPTANCE_SCOPE=disposable-compose to confirm this isolated Compose project.\n' >&2
  exit 2
}
for command in docker openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command is unavailable: %s\n' "$command" >&2
    exit 2
  }
done

project="simpastil-acceptance-compose-$(date +%s)-${BASHPID}-${RANDOM}"
[[ "$project" =~ ^simpastil-acceptance-compose-[0-9]+-[0-9]+-[0-9]+$ ]] || {
  printf 'Generated Compose project name is outside the disposable namespace.\n' >&2
  exit 2
}
secret_dir=$(mktemp -d "${TMPDIR:-/tmp}/simpastil-acceptance.XXXXXX")
chmod 700 "$secret_dir"
env_file="$secret_dir/compose.env"
compose_safe_to_remove=false

cleanup() {
  if [[ "$compose_safe_to_remove" == true && -f "$env_file" ]]; then
    docker compose --project-name "$project" --env-file "$env_file" \
      -f "$repo_root/docker-compose.yml" \
      -f "$repo_root/scripts/acceptance/recovery-proxy.compose.yml" \
      down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -f "$secret_dir"/compose.env "$secret_dir"/postgres_password \
    "$secret_dir"/app_user_password "$secret_dir"/outbox_user_password \
    "$secret_dir"/smtp_password "$secret_dir"/totp_encryption_key \
    "$secret_dir"/delivery_payload_key "$secret_dir"/smtp_user \
    "$secret_dir"/jwt_private_key "$secret_dir"/jwt_public_key \
    "$secret_dir"/database_url_super "$secret_dir"/database_url_app \
    "$secret_dir"/database_url_outbox "$secret_dir"/nginx-certs/cert.pem \
    "$secret_dir"/nginx-certs/key.pem
  rmdir "$secret_dir"/nginx-certs 2>/dev/null || true
  rmdir "$secret_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_unused_project() {
  local resource found
  for resource in containers volumes networks; do
    case "$resource" in
      containers) found=$(docker ps -aq --filter "label=com.docker.compose.project=$project") ;;
      volumes) found=$(docker volume ls -q --filter "label=com.docker.compose.project=$project") ;;
      networks) found=$(docker network ls -q --filter "label=com.docker.compose.project=$project") ;;
    esac
    [[ -z "$found" ]] || {
      printf 'Refusing to reuse existing Compose %s for %s.\n' "$resource" "$project" >&2
      exit 2
    }
  done
}

assert_unused_project
compose_safe_to_remove=true

for secret_name in postgres_password app_user_password outbox_user_password smtp_password; do
  openssl rand -hex 32 > "$secret_dir/$secret_name"
done
openssl rand -hex 32 > "$secret_dir/totp_encryption_key"
openssl rand -hex 32 > "$secret_dir/delivery_payload_key"
printf 'acceptance-user\n' > "$secret_dir/smtp_user"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$secret_dir/jwt_private_key" 2>/dev/null
openssl pkey -in "$secret_dir/jwt_private_key" -pubout -out "$secret_dir/jwt_public_key" 2>/dev/null
mkdir "$secret_dir/nginx-certs"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$secret_dir/nginx-certs/key.pem" \
  -out "$secret_dir/nginx-certs/cert.pem" -days 1 -subj "/CN=nginx" \
  -addext "subjectAltName=DNS:nginx" 2>/dev/null

# File-backed Compose secrets preserve host file permissions. Keep the fixture
# directory host-private while making each mounted secret readable in-container.
chmod 0444 "$secret_dir/postgres_password" "$secret_dir/app_user_password" \
  "$secret_dir/outbox_user_password" "$secret_dir/smtp_password" \
  "$secret_dir/totp_encryption_key" "$secret_dir/delivery_payload_key" \
  "$secret_dir/smtp_user" "$secret_dir/jwt_private_key" "$secret_dir/jwt_public_key" \
  "$secret_dir/nginx-certs/cert.pem" "$secret_dir/nginx-certs/key.pem"

postgres_password=$(<"$secret_dir/postgres_password")
app_user_password=$(<"$secret_dir/app_user_password")
outbox_user_password=$(<"$secret_dir/outbox_user_password")
printf 'postgresql://postgres:%s@postgres:5432/simpastil\n' "$postgres_password" > "$secret_dir/database_url_super"
printf 'postgresql://app_user:%s@postgres:5432/simpastil\n' "$app_user_password" > "$secret_dir/database_url_app"
printf 'postgresql://outbox_user:%s@postgres:5432/simpastil\n' "$outbox_user_password" > "$secret_dir/database_url_outbox"
unset postgres_password app_user_password outbox_user_password
chmod 0444 "$secret_dir/database_url_super" "$secret_dir/database_url_app" \
  "$secret_dir/database_url_outbox"

printf '%s\n' \
  "POSTGRES_PASSWORD_FILE=$secret_dir/postgres_password" \
  "DATABASE_URL_SUPER_FILE=$secret_dir/database_url_super" \
  "DATABASE_URL_FILE=$secret_dir/database_url_app" \
  "DATABASE_URL_OUTBOX_FILE=$secret_dir/database_url_outbox" \
  "APP_USER_PASSWORD_FILE=$secret_dir/app_user_password" \
  "OUTBOX_USER_PASSWORD_FILE=$secret_dir/outbox_user_password" \
  "JWT_PRIVATE_KEY_FILE=$secret_dir/jwt_private_key" \
  "JWT_PUBLIC_KEY_FILE=$secret_dir/jwt_public_key" \
  "TOTP_ENC_KEY_FILE=$secret_dir/totp_encryption_key" \
  "DELIVERY_PAYLOAD_KEY_FILE=$secret_dir/delivery_payload_key" \
  "SMTP_USER_FILE=$secret_dir/smtp_user" \
  "SMTP_PASS_FILE=$secret_dir/smtp_password" \
  "SIMPASTIL_ACCEPTANCE_CERT_DIR=$secret_dir/nginx-certs" \
  'POSTGRES_USER=postgres' \
  'POSTGRES_DB=simpastil' \
  'PUBLIC_APP_URL=https://nginx:34857/deep/link' \
  'CORS_ORIGIN=https://nginx:34857' \
  'NGINX_HOST_IP=127.0.0.1' \
  'NGINX_HTTP_PORT=0' \
  'NGINX_HTTPS_PORT=0' \
  'SMTP_HOST=127.0.0.1' \
  'SMTP_PORT=587' \
  'SMTP_FROM=noreply@example.test' \
  'SHUTDOWN_TIMEOUT_MS=10000' \
  'OUTBOX_SHUTDOWN_TIMEOUT_MS=10000' > "$env_file"

compose=(docker compose --project-name "$project" --env-file "$env_file" \
  -f "$repo_root/docker-compose.yml" \
  -f "$repo_root/scripts/acceptance/recovery-proxy.compose.yml")
"${compose[@]}" up --build --detach api outbox nginx

migration_ready=false
for _ in $(seq 1 60); do
  if "${compose[@]}" exec --no-TTY postgres psql -U postgres -d simpastil -At -v ON_ERROR_STOP=1 -c "
    SELECT
      (SELECT count(*) = 1 AND bool_and(
        schema_version = 15 AND release_id = 'migration-0015'
        AND enforced_minimum_client_build = 1 AND target_minimum_client_build = 2
        AND NOT ledger_activated
      ) FROM public.deployment_manifest)
      AND (SELECT count(*) = 5 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND NOT t.tgisinternal
          AND ((c.relname = 'dose_logs' AND t.tgname IN (
            'dose_logs_authority_lock', 'dose_logs_handoff_journal', 'dose_logs_activation_guard'
          )) OR (c.relname = 'pills' AND t.tgname IN (
            'pills_stock_authority_lock', 'pills_stock_handoff_journal'
          ))));
  " 2>/dev/null | grep -qx t; then
    migration_ready=true
    break
  fi
  sleep 1
done
if [[ "$migration_ready" != true ]]; then
  printf 'Schema 0015 authority triggers were not installed before readiness polling.\n' >&2
  exit 1
fi

ready=false
for _ in $(seq 1 60); do
  if "${compose[@]}" exec --no-TTY api node --input-type=module -e '
    const response = await fetch("http://127.0.0.1:8080/api/v1/health/ready");
    process.exit(response.status === 200 ? 0 : 1);
  ' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  printf 'API did not become ready in the disposable Compose project.\n' >&2
  exit 1
fi

"${compose[@]}" exec --no-TTY api node --input-type=module -e '
  import postgres from "postgres";
  import { readFileSync } from "node:fs";
  const sql = postgres(readFileSync(process.env.DATABASE_URL_FILE, "utf8").trim());
  try {
    const [role] = await sql`SELECT current_user AS name, r.rolsuper, r.rolbypassrls FROM pg_roles r WHERE r.rolname = current_user`;
    if (!role || role.name !== "app_user" || role.rolsuper || role.rolbypassrls) process.exitCode = 1;
    let denied = false;
    try { await sql.unsafe("SELECT encrypted_delivery_payload FROM public.outbox_messages LIMIT 1"); }
    catch (error) { denied = error.code === "42501"; }
    if (!denied) process.exitCode = 1;
  } finally { await sql.end(); }
'

"${compose[@]}" exec --no-TTY outbox node --input-type=module -e '
  import postgres from "postgres";
  import { readFileSync } from "node:fs";
  const sql = postgres(readFileSync(process.env.DATABASE_URL_OUTBOX_FILE, "utf8").trim());
  try {
    const [role] = await sql`SELECT current_user AS name, r.rolsuper, r.rolbypassrls FROM pg_roles r WHERE r.rolname = current_user`;
    if (!role || role.name !== "outbox_user" || role.rolsuper || role.rolbypassrls) process.exitCode = 1;
    let denied = false;
    try { await sql.unsafe("SELECT id FROM public.users LIMIT 1"); }
    catch (error) { denied = error.code === "42501"; }
    if (!denied) process.exitCode = 1;
  } finally { await sql.end(); }
'

# Exercise the actual generated fragment URL against the built SPA and proxy.
# The SMTP worker is stopped first; its envelope stays queued for the isolated
# outbox_user one-shot opener below, and the API role never reads that payload.
"${compose[@]}" stop --timeout 10 outbox >/dev/null
api_key=$(openssl rand -hex 32)
api_key_hash=$(printf '%s' "$api_key" | openssl dgst -sha256 | sed 's/^.*= //')
"${compose[@]}" exec --no-TTY postgres psql -U postgres -d simpastil \
  -v ON_ERROR_STOP=1 \
  -c "INSERT INTO public.api_keys (key_hash, label) VALUES ('$api_key_hash', 'recovery-proxy-acceptance');" >/dev/null

printf '%s\n' "$api_key" | "${compose[@]}" exec --no-TTY api node --input-type=module -e '
let apiKey = "";
for await (const chunk of process.stdin) apiKey += chunk;
apiKey = apiKey.trim();
const base = "https://nginx:34857/api/v1";
const registered = await fetch(`${base}/auth/register`, {
  method: "POST",
  headers: { "content-type": "application/json", "x-api-key": apiKey },
  body: JSON.stringify({ email: "recovery-proxy@example.invalid", password: "proxy-original-password-123" }),
});
if (registered.status !== 201) throw new Error(`Registration through Nginx failed: ${registered.status}`);
const requested = await fetch(`${base}/auth/forgot-password`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ email: "recovery-proxy@example.invalid" }),
});
if (requested.status !== 200) throw new Error(`Reset request through Nginx failed: ${requested.status}`);
'

reset_link=$("${compose[@]}" run --rm --no-TTY --no-deps outbox node --input-type=module -e '
import { readFileSync } from "node:fs";
import postgres from "postgres";
import { createDeliveryPayloadOpener } from "./dist/lib/delivery-payload-crypto.js";
import { buildRecoveryLink } from "./dist/lib/recovery-links.js";
const sql = postgres(readFileSync(process.env.DATABASE_URL_OUTBOX_FILE, "utf8").trim());
try {
  const [row] = await sql`
    SELECT encrypted_delivery_payload FROM public.outbox_messages
    WHERE recipient_ref = ${"recovery-proxy@example.invalid"}
      AND message_type = ${"password-reset"}
    ORDER BY created_at DESC LIMIT 1
  `;
  if (!row?.encrypted_delivery_payload) throw new Error("No queued recovery envelope was found");
  const key = readFileSync(process.env.DELIVERY_PAYLOAD_KEY_FILE, "utf8").trim();
  const payload = JSON.parse(createDeliveryPayloadOpener(key).open(row.encrypted_delivery_payload));
  if (typeof payload.token !== "string") throw new Error("Recovery envelope did not contain a token");
  process.stdout.write(buildRecoveryLink(process.env.PUBLIC_APP_URL, "reset-password", payload.token));
} finally { await sql.end(); }
')

printf '%s\n%s\n' "$reset_link" "$api_key" | "${compose[@]}" exec --no-TTY api node --input-type=module -e '
let input = "";
for await (const chunk of process.stdin) input += chunk;
const [linkText, apiKey] = input.trim().split("\n");
const link = new URL(linkText);
if (link.origin !== "https://nginx:34857") throw new Error("Delivered link used the wrong configured origin");
const fragment = new URL(link.hash.slice(1), link.origin);
if (fragment.pathname !== "/reset-password") throw new Error("Delivered link did not target the reset route");
const token = fragment.searchParams.get("token");
if (!token) throw new Error("Delivered link fragment did not contain the token");

// Fetching the exact browser link exercises the built SPA; URL fragments are
// excluded from the HTTP request, so Nginx receives only GET /.
const page = await fetch(link);
if (page.status !== 200 || !page.url.endsWith("/")) throw new Error(`Recovery SPA request failed: ${page.status}`);
const html = await page.text();
if (!html.includes("<div id=\"app\"") || html.includes(token)) throw new Error("Built recovery page is missing or exposed the token");
const scriptPath = html.match(/<script[^>]+src=\"([^\"]+\.js)\"/)?.[1];
if (!scriptPath) throw new Error("Built recovery JavaScript bundle was not referenced");
const script = await fetch(new URL(scriptPath, link.origin));
if (script.status !== 200) throw new Error(`Built recovery bundle failed: ${script.status}`);

const root = await fetch("http://127.0.0.1:8080/");
if (root.status !== 404) throw new Error(`Direct API root must stay 404, got ${root.status}`);
const reset = await fetch("https://nginx:34857/api/v1/auth/reset-password", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token, newPassword: "proxy-reset-password-456" }),
});
if (reset.status !== 200) throw new Error(`Recovery token exchange through Nginx failed: ${reset.status}`);
const login = await fetch("https://nginx:34857/api/v1/auth/login", {
  method: "POST",
  headers: { "content-type": "application/json", "x-api-key": apiKey },
  body: JSON.stringify({ email: "recovery-proxy@example.invalid", password: "proxy-reset-password-456" }),
});
if (login.status !== 200) throw new Error(`Post-reset login through Nginx failed: ${login.status}`);
'

reset_token=${reset_link##*token=}
if "${compose[@]}" logs --no-color nginx | grep -Fq "$reset_token"; then
  printf 'Nginx diagnostics exposed a recovery token.\n' >&2
  exit 1
fi
unset api_key api_key_hash reset_link reset_token

"${compose[@]}" stop --timeout 50 api outbox
for service in api outbox; do
  container_id=$("${compose[@]}" ps --all --quiet "$service")
  exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container_id")
  if [[ "$exit_code" != 0 ]]; then
    printf 'Service did not drain cleanly: %s (exit %s)\n' "$service" "$exit_code" >&2
    exit 1
  fi
done
printf 'Disposable Compose readiness, role isolation, recovery proxy exchange, and bounded-stop exercise passed: %s\n' "$project"
