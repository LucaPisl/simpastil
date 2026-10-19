#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_tracked_lock() {
  local path="$1"
  # In an exported tree without git metadata only existence can be checked.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ "$(git rev-parse --show-toplevel)" == "$ROOT" ]]; then
    git ls-files --error-unmatch "$path" >/dev/null 2>&1 || fail "$path is not tracked"
    git check-ignore -q "$path" && fail "$path is still ignored"
  fi
  [[ -s "$path" ]] || fail "$path is missing or empty"
}

validate_digest_ref() {
  local name="$1"
  local reference="$2"
  [[ "$reference" =~ ^docker\.io/library/[a-z0-9._-]+:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}$ ]] ||
    fail "$name is not an exact Docker Official Image tag plus SHA-256 digest: $reference"
  [[ "$reference" != *:latest@* ]] || fail "$name must not use the mutable latest tag"
}

require_tracked_lock flutter_app/pubspec.lock
require_tracked_lock server/package-lock.json
require_tracked_lock server/admin/package-lock.json

timezone_constraint="$(sed -nE 's/^[[:space:]]*timezone:[[:space:]]*([^[:space:]]+).*$/\1/p' flutter_app/pubspec.yaml | head -n 1)"
timezone_locked="$(awk '$1 == "timezone:" { found = 1; next } found && $1 == "version:" { print $2; exit }' flutter_app/pubspec.lock | tr -d '\"')"
[[ -n "$timezone_constraint" && "$timezone_constraint" != any && "$timezone_constraint" != '*' ]] ||
  fail 'timezone dependency must have a bounded version'
[[ "$timezone_constraint" == "$timezone_locked" ]] ||
  fail "timezone constraint $timezone_constraint does not match lock $timezone_locked"

flutter_version="$(sed -nE 's/^[[:space:]]*"flutter":[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*$/\1/p' .fvmrc)"
[[ -n "$flutter_version" ]] || fail '.fvmrc must pin an exact Flutter version'
grep -Eq "^[[:space:]]*sdk:[[:space:]]*['\"]>=[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+<4\.0\.0['\"][[:space:]]*$" flutter_app/pubspec.yaml ||
  fail 'Flutter app Dart SDK range is missing or unbounded'

(cd third_party/sqlite3mc && sha256sum --check --strict --quiet SHA256SUMS) ||
  fail 'vendored SQLite3 Multiple Ciphers sources do not match third_party/sqlite3mc/SHA256SUMS'
grep -Eq '^[[:space:]]*path:[[:space:]]*\.\./third_party/sqlite3mc/sqlite3mc_amalgamation\.c[[:space:]]*$' flutter_app/pubspec.yaml ||
  fail 'flutter_app/pubspec.yaml must build SQLite3 Multiple Ciphers from third_party/sqlite3mc'
if grep -Eq '^[[:space:]]*source:[[:space:]]*sqlite3mc[[:space:]]*$' flutter_app/pubspec.yaml; then
  fail 'sqlite3mc must be compiled from source, not downloaded as a prebuilt binary'
fi

node_ref="$(sed -nE 's/^ARG NODE_IMAGE=([^[:space:]]+)$/\1/p' server/Dockerfile)"
nginx_ref="$(sed -nE 's/^ARG NGINX_IMAGE=([^[:space:]]+)$/\1/p' nginx/Dockerfile)"
validate_digest_ref 'server Node base' "$node_ref"
validate_digest_ref 'nginx base' "$nginx_ref"
grep -Fq '24.22.0' <<<"$node_ref" || fail 'Node image must expose its exact version in the tag'

server_version="$(node -p "require('./server/package.json').version")"
while IFS= read -r image_ref; do
  [[ -n "$image_ref" ]] || continue
  case "$image_ref" in
    simpastil-server:* | simpastil-server-backup:*)
      # Server images are tagged by release so older ones survive for rollback.
      [[ "$image_ref" == "${image_ref%%:*}:\${SIMPASTIL_VERSION:-$server_version}" ]] ||
        fail "server image must be tagged \${SIMPASTIL_VERSION:-$server_version} (server/package.json): $image_ref"
      ;;
    simpastil-*)
      [[ "$image_ref" != *:latest ]] || fail "local production image uses latest: $image_ref"
      ;;
    *) validate_digest_ref 'production Compose image' "$image_ref" ;;
  esac
done < <(sed -nE 's/^[[:space:]]*image:[[:space:]]*([^[:space:]]+).*$/\1/p' docker-compose.yml)

if grep -Eq '^[[:space:]]*FROM[[:space:]]+[[:alnum:]_./-]+:[^@[:space:]]+([[:space:]]|$)' server/Dockerfile nginx/Dockerfile; then
  fail 'Dockerfile FROM instruction contains an unpinned direct image reference'
fi
grep -Fq 'RUN npm ci' server/Dockerfile || fail 'server image must install from its npm lock with npm ci'
# The API image builds and serves the admin console from the same pinned Node
# base; the nginx image carries no application code and no Node toolchain.
grep -Eq '^FROM \$\{NODE_IMAGE\} AS admin-builder$' server/Dockerfile ||
  fail 'server image must build the admin console in a pinned admin-builder stage'
grep -Fq 'COPY admin/package-lock.json' server/Dockerfile || fail 'admin console must install from its npm lock'
grep -Fq 'COPY --from=admin-builder /build/public' server/Dockerfile || fail 'server image must ship the built admin console'
if grep -Eq 'NODE_IMAGE|admin-builder|npm ' nginx/Dockerfile; then
  fail 'nginx image must not build the admin console'
fi
grep -Fq 'SIMPASTIL_BUILD_PROFILE=production' server/Dockerfile || fail 'production build profile is missing'
grep -Fq 'SIMPASTIL_BUILD_PROFILE=compatibility' server/Dockerfile || fail 'compatibility build profile is missing'
grep -Fq 'io.simpastil.build-profile="production"' server/Dockerfile || fail 'production profile label is missing'
grep -Fq 'io.simpastil.build-profile="compatibility"' server/Dockerfile || fail 'compatibility profile label is missing'
migration_head="$(find server/src/db/migrations -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' -print | sort | tail -n 1 | xargs -r basename)"
[[ -n "$migration_head" ]] || fail 'migration head cannot be determined'
migration_version="${migration_head%%_*}"
schema_range="${migration_version}..${migration_version}"
grep -Fq "io.simpastil.compatible-schema-range=\"$schema_range\"" server/Dockerfile ||
  fail "Docker build profiles are not explicitly bounded to the current schema range $schema_range"

gradle_version="$(sed -nE 's/^distributionUrl=.*gradle-([0-9]+\.[0-9]+\.[0-9]+)-all\.zip$/\1/p' flutter_app/android/gradle/wrapper/gradle-wrapper.properties)"
gradle_sha="$(sed -nE 's/^distributionSha256Sum=([a-f0-9]{64})$/\1/p' flutter_app/android/gradle/wrapper/gradle-wrapper.properties)"
[[ -n "$gradle_version" && -n "$gradle_sha" ]] || fail 'Gradle wrapper version and distribution SHA-256 must both be exact'
grep -Fq 'JavaVersion.VERSION_17' flutter_app/android/app/build.gradle.kts ||
  fail 'Android Java compile target must be explicitly recorded'

server_node_engine="$(node -p "require('./server/package.json').engines.node")"
admin_node_engine="$(node -p "require('./server/admin/package.json').engines.node")"
[[ "$server_node_engine" == 24.22.0 && "$admin_node_engine" == 24.22.0 ]] ||
  fail 'server and admin package manifests must require the exact Node image version'

for workflow_dir in .gitea/workflows .github/workflows; do
  [[ -d "$workflow_dir" ]] || continue
  while IFS= read -r action_ref; do
    [[ -n "$action_ref" ]] || continue
    [[ "$action_ref" =~ @([0-9a-f]{40})$ ]] ||
      fail "workflow action is not pinned to a full commit SHA: $action_ref"
  done < <(grep -RhoE '^[[:space:]]*uses:[[:space:]]*[^[:space:]#]+' "$workflow_dir" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//')
done

printf 'PASS: lock, toolchain, and digest policy\n'
printf 'source_commit=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
printf 'retrieved_at=2026-10-19 (Docker Official Images and Gradle release checksum reference)\n'
printf 'flutter=%s\n' "$flutter_version"
printf 'node=%s\n' "$node_ref"
printf 'nginx=%s\n' "$nginx_ref"
printf 'postgres=%s\n' "$(sed -nE 's/^[[:space:]]*image:[[:space:]]*(docker\.io\/library\/postgres[^[:space:]]+).*$/\1/p' docker-compose.yml | head -n 1)"
printf 'java_runtime=21.0.9 java_compile_target=17 gradle=%s gradle_sha256=%s\n' "$gradle_version" "$gradle_sha"
printf 'migration_head=%s compatible_schema_range=%s\n' "$migration_head" "$schema_range"

for local_image in "simpastil-server:$server_version" "simpastil-server-backup:$server_version" simpastil-server:compatibility simpastil-nginx:1.2.0-1; do
  if command -v docker >/dev/null 2>&1 && image_id="$(docker image inspect --format '{{.Id}}' "$local_image" 2>/dev/null)"; then
    printf 'local_image_config_digest.%s=%s\n' "$local_image" "$image_id"
  elif [[ "${REQUIRE_LOCAL_IMAGE_DIGESTS:-0}" == 1 ]]; then
    fail "required local image has not been built: $local_image"
  else
    printf 'local_image_config_digest.%s=not-built\n' "$local_image"
  fi
done
