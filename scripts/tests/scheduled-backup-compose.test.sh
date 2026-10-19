#!/usr/bin/env bash
# Pins the hardening and wiring of the long-running scheduled-backup service in
# docker-compose.yml. It is the one runtime service that holds the superuser
# database credential (DEPLOYMENT.md, "Scheduled backups"), so loosening any of
# these settings must fail here. Reads the rendered configuration only; it
# starts nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null && docker compose version >/dev/null 2>&1 || {
  printf 'SKIP: docker compose is not available\n'
  exit 0
}

secret_dir=/nonexistent/simpastil-secrets
env_vars=(
  "POSTGRES_PASSWORD_FILE=$secret_dir/postgres_password"
  "DATABASE_URL_SUPER_FILE=$secret_dir/database_url_super"
  "DATABASE_URL_FILE=$secret_dir/database_url_app"
  "DATABASE_URL_OUTBOX_FILE=$secret_dir/database_url_outbox"
  "APP_USER_PASSWORD_FILE=$secret_dir/app_user_password"
  "OUTBOX_USER_PASSWORD_FILE=$secret_dir/outbox_user_password"
  "JWT_PRIVATE_KEY_FILE=$secret_dir/jwt_private.pem"
  "JWT_PUBLIC_KEY_FILE=$secret_dir/jwt_public.pem"
  "TOTP_ENC_KEY_FILE=$secret_dir/totp_encryption_key"
  "DELIVERY_PAYLOAD_KEY_FILE=$secret_dir/delivery_payload_key"
  'PUBLIC_APP_URL=https://pills.example.test' 'CORS_ORIGIN=https://pills.example.test'
  'SMTP_HOST=smtp.example.test' 'SIMPASTIL_BACKUP_DIR=/nonexistent/simpastil-backups'
)

render() { # extra environment assignments
  env -i PATH="$PATH" HOME="${HOME:-/}" "${env_vars[@]}" "$@" \
    docker compose --project-name simpastil-policy -f "$ROOT/docker-compose.yml" config --format json
}

check() { # JSON on stdin
  node -e '
    let input = "";
    process.stdin.on("data", (c) => (input += c)).on("end", () => {
      const compose = JSON.parse(input);
      const service = compose.services["scheduled-backup"];
      const premigrate = compose.services["premigrate-backup"];
      const problems = [];
      const expect = (ok, text) => { if (!ok) problems.push(text); };
      expect(service, "scheduled-backup service is missing");
      if (!service) { console.error(problems.join("\n")); process.exit(1); }
      expect(service.image === premigrate.image, "must reuse the premigrate-backup image");
      expect(service.read_only === true, "root filesystem must be read-only");
      expect(JSON.stringify(service.cap_drop) === JSON.stringify(["ALL"]), "must drop every capability");
      expect((service.security_opt ?? []).includes("no-new-privileges:true"), "must set no-new-privileges");
      expect(!service.ports || service.ports.length === 0, "must publish no port");
      expect(!service.privileged, "must not be privileged");
      expect(Object.keys(service.networks ?? {}).join() === "pill-tracker-net", "must join only the database network");
      expect(service.restart === "unless-stopped", "must restart unless stopped");
      expect(service.user === premigrate.user, "must run as the backup user");
      expect(!(service.volumes ?? []).some((v) => v.target !== "/backups" && v.target !== "/ops/role-grants-rls.sql"),
        "must mount only the backup directory and the grants SQL");
      expect((service.volumes ?? []).some((v) => v.target === "/backups" && !v.read_only), "must write the backup directory");
      const secrets = (service.secrets ?? []).map((s) => s.source).sort().join();
      expect(secrets === ["database_url_super", "delivery_payload_key", "jwt_public_key", "tls_cert", "totp_encryption_key"].join(),
        "unexpected secrets: " + secrets);
      expect(service.depends_on?.postgres?.condition === "service_healthy", "must wait for a healthy database");
      expect(service.depends_on?.migrate?.condition === "service_completed_successfully", "must wait for the migrations");
      expect(service.healthcheck && !service.healthcheck.disable
        && service.healthcheck.test.join(" ").includes("scheduled-backup.js --healthcheck"),
        "must override the image health check with its own");
      const environment = service.environment ?? {};
      expect(environment.SIMPASTIL_SCHEDULED_BACKUP === "on", "scheduled backups must default to on");
      expect(environment.SIMPASTIL_BACKUP_INTERVAL === "24h", "interval must default to 24h");
      expect(environment.SIMPASTIL_SCHEDULED_BACKUP_KEEP === "7", "keep must default to 7");
      // No other long-running service may receive the superuser credential.
      for (const [name, other] of Object.entries(compose.services)) {
        const oneShot = ["premigrate-backup", "provision", "migrate", "backup", "restore", "scheduled-backup"].includes(name);
        const holdsSuper = (other.secrets ?? []).some((s) => s.source === "database_url_super");
        expect(oneShot || !holdsSuper, name + " must not hold the superuser credential");
      }
      if (problems.length) { console.error(problems.map((p) => "  - " + p).join("\n")); process.exit(1); }
    });
  '
}

render | check || fail 'scheduled-backup service policy'
printf 'PASS: scheduled-backup is hardened and wired after the migrations\n'

override=$(render SIMPASTIL_SCHEDULED_BACKUP=off SIMPASTIL_BACKUP_INTERVAL=6h SIMPASTIL_SCHEDULED_BACKUP_KEEP=3 \
  | node -e 'let i="";process.stdin.on("data",c=>i+=c).on("end",()=>{const e=JSON.parse(i).services["scheduled-backup"].environment;console.log([e.SIMPASTIL_SCHEDULED_BACKUP,e.SIMPASTIL_BACKUP_INTERVAL,e.SIMPASTIL_SCHEDULED_BACKUP_KEEP].join(" "))})')
[[ "$override" == 'off 6h 3' ]] || fail "settings do not flow from the environment: $override"
printf 'PASS: scheduled backup settings come from the Compose environment\n'
