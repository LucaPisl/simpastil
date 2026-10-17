#!/usr/bin/env bash
# Workflow policy gate for .gitea/workflows and .github/workflows: triggers,
# token permissions, immutable action references, secret separation, job
# timeouts, and the release/preflight/smoke invariants. It reads no runner
# files, so it passes on a tree without .gitea/runner; the operator-runner
# checks are in check-runner.sh.
set -euo pipefail

ROOT="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_file() { [[ -s "$ROOT/$1" ]] || fail "required workflow file is missing or empty: $1"; }

for path in \
  .gitea/workflows/validate.yml \
  .gitea/workflows/release.yml \
  .gitea/workflows/signing-preflight.yml \
  .gitea/workflows/smoke.yml; do
  require_file "$path"
done

workflows="$ROOT/.gitea/workflows"
release_workflow="$workflows/release.yml"
preflight_workflow="$workflows/signing-preflight.yml"
smoke_workflow="$workflows/smoke.yml"

assert_trigger_block() {
  local workflow="$1" expected="$2" actual
  actual="$(awk '
    /^on:[[:space:]]*$/ { in_triggers = 1; print; next }
    in_triggers && /^permissions:[[:space:]]*$/ { exit }
    in_triggers { print }
  ' "$workflows/$workflow")"
  [[ "$actual" == "$expected" ]] ||
    fail "$workflow has an unsupported trigger policy; expected:\n$expected\nactual:\n$actual"
}

assert_trigger_block validate.yml 'on:
  push:
    branches: ["master"]
  pull_request:'
assert_trigger_block smoke.yml 'on:
  push:
    tags: ["smoke-*"]'

if grep -REn '(^|[[:space:]])write-all([[:space:]#]|$)' "$workflows"; then
  fail 'workflow token permissions must be explicitly scoped'
fi

while IFS= read -r action_ref; do
  [[ -n "$action_ref" ]] || continue
  [[ "$action_ref" =~ @([a-f0-9]{40})$ ]] || fail "action is not pinned to a full commit SHA: $action_ref"
done < <(grep -RhoE '^[[:space:]]*uses:[[:space:]]*[^[:space:]#]+' "$workflows" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//')

for runner_label in simpastil-node simpastil-flutter simpastil-docker; do
  grep -RFq "runs-on: $runner_label" "$workflows" || fail "workflow never selects required runner label: $runner_label"
done
if grep -REn 'DOCKER_HOST:' "$workflows" | grep -Fv 'DOCKER_HOST: unix:///var/run/docker.sock'; then
  fail 'workflow Docker clients must use the mounted job-side socket'
fi
# The daemon-side socket comes from a variable with a neutral default, never a
# machine-specific literal.
for path in validate.yml release.yml; do
  grep -Fq "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE: \${{ vars.SIMPASTIL_DAEMON_DOCKER_SOCKET || '/var/run/docker.sock' }}" "$workflows/$path" ||
    fail "$path must take the Ryuk socket path from SIMPASTIL_DAEMON_DOCKER_SOCKET"
done
if grep -REn '/var/run/user/[0-9]' "$workflows"; then
  fail 'workflows must not hard-code a per-user daemon socket path'
fi
if grep -REn '^[[:space:]]*options:.*--privileged|^[[:space:]]*privileged:[[:space:]]*true' "$workflows"; then
  fail 'workflow job containers must not be privileged'
fi
if grep -REn 'pull_request_target' "$workflows"; then
  fail 'workflows must not use pull_request_target'
fi
if [[ -d "$ROOT/.github/workflows" ]]; then
  if grep -REn 'pull_request_target|secrets\.' "$ROOT/.github/workflows"; then
    fail 'GitHub workflows must not use pull_request_target or secrets'
  fi
  if grep -REn '(^|[[:space:]])write-all([[:space:]#]|$)|^[[:space:]]*[a-z-]+:[[:space:]]*write([[:space:]#]|$)' "$ROOT/.github/workflows"; then
    fail 'GitHub workflows must stay read-only'
  fi
  for gh in "$ROOT"/.github/workflows/*.yml; do
    { grep -Eq '^permissions:$' "$gh" && grep -Eq '^  contents: read$' "$gh"; } ||
      fail "${gh#"$ROOT"/} must declare top-level permissions: contents: read"
  done
fi
for path in validate.yml smoke.yml; do
  if grep -Ein 'secrets\.|ANDROID_SIGNING_(KEYSTORE_B64|KEY_ALIAS|STORE_PASSWORD|KEY_PASSWORD)|SERVER_REGISTRY_(USER|TOKEN)|GITEA_TOKEN' "$workflows/$path"; then
    fail "release credentials must not be referenced by $path"
  fi
done

for path in validate.yml smoke.yml; do
  jobs="$(grep -Ec '^    runs-on:' "$workflows/$path")"
  bounded="$(grep -Ec '^    timeout-minutes: [0-9]+$' "$workflows/$path")"
  [ "$jobs" = "$bounded" ] || fail "every job in $path must set timeout-minutes"
done

grep -Fq 'tags: ["v*"]' "$release_workflow" ||
  fail 'release workflow must be tag-triggered only for v* tags'
grep -Fq 'SIMPASTIL_DEFAULT_BRANCH' "$release_workflow" || fail 'release workflow must name the protected default branch'
grep -Fq 'git merge-base --is-ancestor' "$release_workflow" ||
  fail 'release workflow must prove tag ancestry from the protected default branch'
grep -Fq 'trap cleanup EXIT HUP INT TERM' "$release_workflow" ||
  fail 'release signing material must have exit and signal teardown'
grep -Fq 'shred' "$release_workflow" || fail 'release cleanup must shred temporary signing files when supported'
grep -Fq 'rm -rf -- "$release_dir"' "$release_workflow" || fail 'release cleanup must remove the job-private signing directory'
for secret_name in \
  ANDROID_SIGNING_KEYSTORE_B64 \
  ANDROID_SIGNING_KEY_ALIAS \
  ANDROID_SIGNING_STORE_PASSWORD \
  ANDROID_SIGNING_KEY_PASSWORD; do
  grep -Fq "secrets.$secret_name" "$release_workflow" || fail "release workflow does not consume $secret_name"
done
for secret_name in SERVER_REGISTRY_USER SERVER_REGISTRY_TOKEN; do
  grep -Fq "secrets.$secret_name" "$release_workflow" || fail "release workflow does not consume package-only $secret_name"
done
grep -Fq 'git merge-base --is-ancestor "$release_commit" "refs/remotes/origin/' "$release_workflow" ||
  fail 'release workflow ancestry direction must prove the tag commit is contained in the protected branch'

grep -Fq 'tags: ["preflight-v*"]' "$preflight_workflow" ||
  fail 'production signing preflight must use its separate preflight-v* tag trigger'
grep -Fq 'refs/tags/preflight-v*' "$preflight_workflow" ||
  fail 'production signing preflight must reject non-preflight refs'
grep -Fq 'SIMPASTIL_DEFAULT_BRANCH' "$preflight_workflow" ||
  fail 'production signing preflight must identify the protected default branch'
grep -Fq 'git merge-base --is-ancestor "$preflight_commit" "refs/remotes/origin/' "$preflight_workflow" ||
  fail 'production signing preflight must prove the tag commit is contained in the protected branch'
grep -Fq '[[ "$preflight_commit" == "$GITHUB_SHA" ]]' "$preflight_workflow" ||
  fail 'production signing preflight must bind its tag to the triggering commit'
grep -Fq 'preflight-v$app_version' "$preflight_workflow" ||
  fail 'production signing preflight must match the application version'
grep -Fq 'scripts/verify-android-signer.sh' "$preflight_workflow" ||
  fail 'production signing preflight must verify the built APK certificate'
grep -Fq 'vars.ANDROID_SIGNING_CERT_SHA256' "$preflight_workflow" ||
  fail 'production signing preflight must use the reviewed certificate fingerprint'
grep -Fq 'trap cleanup EXIT HUP INT TERM' "$preflight_workflow" ||
  fail 'production signing preflight must clean up on exit and signals'
grep -Fq 'shred' "$preflight_workflow" ||
  fail 'production signing preflight must shred temporary signing files when supported'
grep -Fq 'rm -rf -- "$repo_root/flutter_app/build" "$preflight_dir"' "$preflight_workflow" ||
  fail 'production signing preflight must remove its signed build output and private temporary directory'
for secret_name in \
  ANDROID_SIGNING_KEYSTORE_B64 \
  ANDROID_SIGNING_KEY_ALIAS \
  ANDROID_SIGNING_STORE_PASSWORD \
  ANDROID_SIGNING_KEY_PASSWORD; do
  grep -Fq "secrets.$secret_name" "$preflight_workflow" || fail "production signing preflight does not consume $secret_name"
done
grep -Fq 'contents: read' "$preflight_workflow" ||
  fail 'production signing preflight must use read-only repository token permissions'
if grep -Ein '^[[:space:]]*(contents|packages|releases|actions):[[:space:]]*write([[:space:]#]|$)|SERVER_REGISTRY_(USER|TOKEN)|GITEA_TOKEN|secrets\.(SERVER_REGISTRY_|GITEA_TOKEN)|docker[[:space:]]+push|--push([[:space:]]|$)|upload-artifact|/api/v1/repos/.*/releases' "$preflight_workflow"; then
  fail 'production signing preflight must not receive publishing credentials or publish artifacts/images'
fi
grep -Fq 'tags: ["smoke-*"]' "$smoke_workflow" ||
  fail 'secret-free runner smoke workflow must have its Gitea-compatible smoke-* tag trigger'
if grep -Fq 'workflow_dispatch:' "$smoke_workflow"; then
  fail 'runner smoke workflow must not depend on unsupported workflow_dispatch on the minimum Gitea version'
fi

if grep -REni 'TODO|FIXME|replace-this-token|example\.com/[[:alnum:]_-]+/[[:alnum:]_-]+' "$workflows"; then
  fail 'workflow configuration contains an unresolved placeholder'
fi

printf 'PASS: workflow separation, immutable inputs, and release ancestry/teardown\n'
