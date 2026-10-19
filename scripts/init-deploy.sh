#!/usr/bin/env bash
# init-deploy.sh — Prepare a new Docker Compose install in one step.
#
# Usage:
#   scripts/init-deploy.sh --domain HOST [--smtp-host HOST] [options]
#
# Options:
#   --secrets-dir DIR   secret files and compose.env (default /secure/simpastil)
#   --backup-dir DIR    automatic pre-migration backups (default /secure/simpastil-backups)
#   --https-port PORT   public HTTPS port (default 34857; 443 gives a portless URL)
#   --project NAME      Compose project name (default simpastil-production)
#   --tls MODE          certificate mode, one of:
#       provided     (default) --cert and --key are installed for the bundled nginx
#       host-proxy   a reverse proxy on this host terminates TLS and forwards to
#                    the API on 127.0.0.1:PORT; --cert names the certificate it serves
#       self-signed  a throwaway certificate for a browser trial; the Android app
#                    refuses it, so phones cannot sync with this mode
#   --cert FILE --key FILE   certificate chain and private key (see --tls)
#
# It writes every secret file, compose.env and the TLS files, creates the
# backup directory owned by you, and prints the commands that remain. It never
# overwrites an existing secret, key or certificate: rerunning it on an
# existing install fails before changing anything.
#
# Requirements: openssl, node (for the backup scripts later), docker compose
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { printf 'init-deploy: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

domain='' smtp_host='' secrets_dir=/secure/simpastil backup_dir=/secure/simpastil-backups
https_port=34857 project=simpastil-production tls=provided cert='' key=''
while [[ $# -gt 0 ]]; do
  [[ "$1" == -h || "$1" == --help ]] && usage
  [[ $# -ge 2 ]] || fail "$1 needs a value"
  case "$1" in
    --domain) domain="$2" ;;
    --smtp-host) smtp_host="$2" ;;
    --secrets-dir) secrets_dir="$2" ;;
    --backup-dir) backup_dir="$2" ;;
    --https-port) https_port="$2" ;;
    --project) project="$2" ;;
    --tls) tls="$2" ;;
    --cert) cert="$2" ;;
    --key) key="$2" ;;
    *) fail "unknown option: $1" ;;
  esac
  shift 2
done

[[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail '--domain must be a DNS name such as pills.example.org'
[[ -z "$smtp_host" || "$smtp_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail '--smtp-host must be a DNS name or address; omit it to run without email'
[[ "$https_port" =~ ^[0-9]+$ ]] && (( https_port >= 1 && https_port <= 65535 )) || fail '--https-port must be 1-65535'
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail '--project must be lowercase letters, digits, - or _'
[[ "$secrets_dir" == /* && "$backup_dir" == /* ]] || fail '--secrets-dir and --backup-dir must be absolute paths'
case "$secrets_dir/" in "$ROOT"/*) fail '--secrets-dir must be outside the checkout' ;; esac
case "$backup_dir/" in "$ROOT"/* | "${secrets_dir%/}"/*) fail '--backup-dir must be outside the checkout and the secrets directory' ;; esac
command -v openssl >/dev/null || fail 'openssl is required'

certs_dir="$ROOT/nginx/certs"
case "$tls" in
  provided)
    [[ -f "$cert" && -f "$key" ]] || fail '--tls provided needs --cert and --key files'
    openssl x509 -in "$cert" -noout 2>/dev/null || fail "$cert is not a PEM certificate"
    ;;
  host-proxy)
    [[ -f "$cert" ]] || fail '--tls host-proxy needs --cert, the certificate your host proxy serves'
    openssl x509 -in "$cert" -noout 2>/dev/null || fail "$cert is not a PEM certificate"
    [[ -z "$key" ]] || fail '--tls host-proxy takes no --key; the host proxy keeps it'
    ;;
  self-signed) [[ -z "$cert$key" ]] || fail '--tls self-signed takes no --cert or --key' ;;
  *) fail '--tls must be provided, host-proxy or self-signed' ;;
esac

secret_names=(postgres_password app_user_password outbox_user_password totp_encryption_key
  delivery_payload_key jwt_private.pem jwt_public.pem database_url_super database_url_app
  database_url_outbox compose.env)
for name in "${secret_names[@]}"; do
  [[ ! -e "$secrets_dir/$name" && ! -L "$secrets_dir/$name" ]] ||
    fail "$secrets_dir/$name already exists; this install is already initialised, nothing was changed"
done
if [[ "$tls" != host-proxy ]]; then
  for name in cert.pem key.pem; do
    [[ ! -e "$certs_dir/$name" ]] || fail "$certs_dir/$name already exists; nothing was changed"
  done
fi
if [[ -e "$backup_dir" ]] && [[ -n "$(find "$backup_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "$backup_dir is not empty; choose a new --backup-dir"
fi

umask 077
mkdir -p "$secrets_dir"
chmod 0700 "$secrets_dir"
cd "$secrets_dir"

for name in postgres_password app_user_password outbox_user_password totp_encryption_key delivery_payload_key; do
  openssl rand -hex 32 >"$name"
done
bash "$ROOT/scripts/generate-keys.sh" "$secrets_dir" >/dev/null
printf 'postgres://postgres:%s@postgres:5432/simpastil' "$(cat postgres_password)" >database_url_super
printf 'postgres://app_user:%s@postgres:5432/simpastil' "$(cat app_user_password)" >database_url_app
printf 'postgres://outbox_user:%s@postgres:5432/simpastil' "$(cat outbox_user_password)" >database_url_outbox
# Readable by the container users (UID 1001 and the backup user); the 0700
# directory keeps other host users out.
chmod 0444 postgres_password app_user_password outbox_user_password totp_encryption_key \
  delivery_payload_key database_url_super database_url_app database_url_outbox

mkdir -p "$backup_dir"
chmod 0700 "$backup_dir"

compose_file="$ROOT/docker-compose.yml"
case "$tls" in
  provided)
    install -d -m 0755 "$certs_dir"
    install -m 0644 "$cert" "$certs_dir/cert.pem"
    install -m 0600 "$key" "$certs_dir/key.pem"
    tls_cert_file="$certs_dir/cert.pem"
    ;;
  self-signed)
    install -d -m 0755 "$certs_dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
      -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" \
      -keyout "$certs_dir/key.pem" -out "$certs_dir/cert.pem" 2>/dev/null
    chmod 0644 "$certs_dir/cert.pem"
    tls_cert_file="$certs_dir/cert.pem"
    ;;
  host-proxy)
    compose_file="$ROOT/docker-compose.yml:$ROOT/docker-compose.host-proxy.yml"
    tls_cert_file="$(cd "$(dirname "$cert")" && pwd -P)/$(basename "$cert")"
    ;;
esac

origin="https://$domain"
[[ "$https_port" == 443 ]] || origin="$origin:$https_port"
{
  printf '# Written by scripts/init-deploy.sh. Paths only, never secret values.\n'
  printf 'COMPOSE_PROJECT_NAME=%s\n' "$project"
  printf 'COMPOSE_FILE=%s\n' "$compose_file"
  printf 'PUBLIC_APP_URL=%s\nCORS_ORIGIN=%s\n' "$origin" "$origin"
  printf 'SMTP_HOST=%s\n' "$smtp_host"
  printf '# Optional SMTP authentication: create both files, then uncomment.\n'
  printf '# SMTP_USER_FILE=%s/smtp_user\n# SMTP_PASS_FILE=%s/smtp_password\n' "$secrets_dir" "$secrets_dir"
  for pair in POSTGRES_PASSWORD_FILE:postgres_password DATABASE_URL_SUPER_FILE:database_url_super \
    DATABASE_URL_FILE:database_url_app DATABASE_URL_OUTBOX_FILE:database_url_outbox \
    APP_USER_PASSWORD_FILE:app_user_password OUTBOX_USER_PASSWORD_FILE:outbox_user_password \
    JWT_PRIVATE_KEY_FILE:jwt_private.pem JWT_PUBLIC_KEY_FILE:jwt_public.pem \
    TOTP_ENC_KEY_FILE:totp_encryption_key DELIVERY_PAYLOAD_KEY_FILE:delivery_payload_key; do
    printf '%s=%s/%s\n' "${pair%%:*}" "$secrets_dir" "${pair#*:}"
  done
  printf 'TLS_CERT_FILE=%s\n' "$tls_cert_file"
  printf 'SIMPASTIL_BACKUP_DIR=%s\n' "$backup_dir"
  printf 'SIMPASTIL_BACKUP_UID=%s\nSIMPASTIL_BACKUP_GID=%s\n' "$(id -u)" "$(id -g)"
  if [[ "$tls" == host-proxy ]]; then
    printf 'API_HOST_PORT=%s\n' "$https_port"
  else
    printf 'NGINX_HTTPS_PORT=%s\n' "$https_port"
  fi
} >compose.env
chmod 0600 compose.env

env_file="$secrets_dir/compose.env"
printf 'Wrote the secrets and %s\n' "$env_file"
printf 'Keep a protected copy of %s away from this server:\n' "$secrets_dir"
printf 'losing totp_encryption_key locks out every two-factor user.\n\n'
if [[ "$tls" == self-signed ]]; then
  printf 'WARNING: the certificate is self-signed. Browsers warn and the Android app\n'
  printf 'refuses it. Replace nginx/certs/cert.pem and key.pem with a CA-issued pair\n'
  printf 'before anyone uses the app.\n\n'
fi
if [[ "$tls" == host-proxy ]]; then
  printf 'Point your host proxy at http://127.0.0.1:%s for %s and have it send\n' "$https_port" "$origin"
  printf 'X-Forwarded-For (see DEPLOYMENT.md, "Topology and prerequisites").\n\n'
fi
# The Android app pins this public key and shows the same value on first connect.
# SHA-256 over the DER SubjectPublicKeyInfo of the leaf, as colon-separated hex.
fingerprint=$(openssl x509 -in "$tls_cert_file" -pubkey -noout | openssl pkey -pubin -outform der |
  openssl dgst -sha256 -binary | od -An -tx1 -v | tr -d ' \n' | tr a-f A-F | sed 's/../&:/g; s/:$//') || fingerprint=''
if [[ -n "$fingerprint" ]]; then
  printf 'Certificate fingerprint (SHA-256 of the public key). The Android app shows this\n'
  printf 'on first connect; compare it before trusting the server:\n  %s\n\n' "$fingerprint"
fi
printf 'Next, from %s:\n\n' "$ROOT"
printf '  docker compose --env-file %s up --detach --build\n' "$env_file"
printf '  docker compose --env-file %s run --rm provision rotate-bootstrap\n\n' "$env_file"
printf 'Open %s/#/setup and enter the printed one-time proof within 30 minutes.\n' "$origin"
