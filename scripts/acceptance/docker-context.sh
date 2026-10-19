#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "${SIMPASTIL_ACCEPTANCE_SCOPE:-}" == disposable-docker-context ]] \
  || fail 'set SIMPASTIL_ACCEPTANCE_SCOPE=disposable-docker-context to confirm this isolated context check'
command -v docker >/dev/null 2>&1 || fail 'docker is required'
docker buildx version >/dev/null 2>&1 || fail 'docker buildx is required'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-docker-context.XXXXXX")"
trap 'rm -rf -- "$scratch"' 0 HUP INT TERM
token="simpastil-context-sentinel-$$"

make_root_context() {
  root_context="$scratch/root-context"
  mkdir -p "$root_context"
  git -C "$ROOT" archive HEAD | tar -x -C "$root_context"
  cp "$ROOT/.dockerignore" "$root_context/.dockerignore"
  cp "$ROOT/nginx/Dockerfile" "$root_context/nginx/Dockerfile"

  for path in \
    node_modules/sentinel \
    server/node_modules/sentinel \
    server/admin/node_modules/sentinel \
    server/dist/sentinel \
    server/admin/dist/sentinel \
    server/admin/coverage/sentinel \
    server/src/test/e2e/remediation-acceptance.test.ts \
    server/public/sentinel \
    flutter_app/build/sentinel \
    flutter_app/test/integration/bridge_rollout_test.dart \
    .git/config \
    docs/_private/sentinel \
    tmp-notes/sentinel \
    scratch/sentinel \
    .env \
    .env.test \
    server/.env.production \
    server/private.pem \
    server/private.key \
    server/src/db/migrations/backups/backup.sql \
    .idea/workspace.xml \
    .vscode/settings.json; do
    mkdir -p "$root_context/$(dirname "$path")"
    printf '%s\n' "$token" > "$root_context/$path"
  done
  printf '%s\n' 'FROM scratch' 'COPY . /context/' > "$root_context/.context-probe.Dockerfile"
}

make_server_context() {
  server_context="$scratch/server-context"
  mkdir -p "$server_context"
  git -C "$ROOT" archive HEAD server | tar -x --strip-components=1 -C "$server_context"
  cp "$ROOT/server/.dockerignore" "$server_context/.dockerignore"
  cp "$ROOT/server/Dockerfile" "$server_context/Dockerfile"

  for path in \
    node_modules/sentinel \
    dist/sentinel \
    coverage/sentinel \
    admin/node_modules/sentinel \
    admin/dist/sentinel \
    admin/coverage/sentinel \
    admin/.env \
    .env \
    .env.test \
    private.pem \
    private.key \
    src/test/e2e/remediation-acceptance.test.ts \
    src/db/migrations/backups/backup.sql \
    src/db/acceptance/fixture.json \
    src/test/fixtures/fixture.json; do
    mkdir -p "$server_context/$(dirname "$path")"
    printf '%s\n' "$token" > "$server_context/$path"
  done
  printf '%s\n' 'FROM scratch' 'COPY . /context/' > "$server_context/.context-probe.Dockerfile"
}

assert_absent() {
  export_dir="$1"
  shift
  for path in "$@"; do
    [ ! -e "$export_dir/context/$path" ] || fail "excluded path leaked into Docker context: $path"
  done
  if grep -R -l -F "$token" "$export_dir" >/dev/null 2>&1; then
    fail "hostile sentinel content leaked into Docker context: $export_dir"
  fi
}

export_context() {
  context_arg="$1"
  export_dir_arg="$2"
  mkdir -p "$export_dir_arg"
  (
    cd "$context_arg"
    docker buildx build --progress=quiet --file .context-probe.Dockerfile \
      --output "type=local,dest=$export_dir_arg" .
  )
}

make_root_context
root_export="$scratch/root-export"
export_context "$root_context" "$root_export"
assert_absent "$root_export" \
  node_modules server/node_modules server/admin/node_modules \
  server/dist server/admin/dist server/admin/coverage server/public \
  server/src/test flutter_app .git tmp-notes scratch docs .env .env.test \
  server/.env.production server/private.pem server/private.key \
  server/src/db/migrations/backups .idea .vscode
[ -f "$root_export/context/nginx/nginx.conf" ] || fail 'nginx configuration is missing from root context'
[ ! -e "$root_export/context/server" ] || fail 'server sources must not be part of the nginx build context'

make_server_context
server_export="$scratch/server-export"
export_context "$server_context" "$server_export"
assert_absent "$server_export" \
  node_modules dist coverage .env .env.test private.pem private.key \
  src/db/migrations/backups src/db/acceptance src/test \
  admin/node_modules admin/dist admin/coverage admin/.env admin/src/dashboard.test.ts \
  admin/vitest.config.ts
[ -f "$server_export/context/package-lock.json" ] || fail 'server npm lock is missing from server context'
[ -f "$server_export/context/admin/package-lock.json" ] || fail 'admin npm lock is missing from server context'
[ -f "$server_export/context/admin/src/main.ts" ] || fail 'admin console sources are missing from server context'
[ -f "$server_export/context/src/index.ts" ] || fail 'server entrypoint is missing from server context'

printf 'PASS: hostile files are excluded from root and server Docker contexts\n'
