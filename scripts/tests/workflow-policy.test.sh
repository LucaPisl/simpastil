#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/check-workflows.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-workflow-policy.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

copy_fixture() {
  local fixture="$scratch/repo"
  rm -rf -- "$fixture"
  mkdir -p "$fixture/.gitea"
  cp -R "$ROOT/.gitea/workflows" "$fixture/.gitea/workflows"
  [[ ! -d "$ROOT/.github/workflows" ]] || { mkdir -p "$fixture/.github"; cp -R "$ROOT/.github/workflows" "$fixture/.github/workflows"; }
  printf '%s\n' "$fixture"
}

expect_rejected() {
  local label="$1" fixture="$2"
  if "$CHECKER" "$fixture" >"$scratch/check.out" 2>&1; then
    fail "policy checker accepted $label"
  fi
}

fixture="$(copy_fixture)"
"$CHECKER" "$fixture" >"$scratch/check.out" 2>&1 || {
  sed -n '1,100p' "$scratch/check.out" >&2
  fail 'valid workflow policy fixture was rejected'
}

fixture="$(copy_fixture)"
awk '/^      - name: Require a protected-branch ancestor/ { in_step = 1 }
  in_step && /CHECKOUT_TOKEN: / { in_step = 0; next } { print }' \
  "$ROOT/.gitea/workflows/signing-preflight.yml" >"$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'a preflight fetch without the checkout token' "$fixture"

fixture="$(copy_fixture)"
sed -i 's/branches: \["main"\]/branches: ["release"]/' "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'validation that omits main post-merge runs' "$fixture"

fixture="$(copy_fixture)"
sed -i 's/branches: \["main"\]/branches: ["main", "**"]/' "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'validation that duplicates every feature-branch push' "$fixture"

fixture="$(copy_fixture)"
sed -i '/^  pull_request:/d' "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'validation without pull-request coverage' "$fixture"

fixture="$(copy_fixture)"
sed -i '/tags: \["smoke-\*"\]/a\  pull_request:' "$fixture/.gitea/workflows/smoke.yml"
expect_rejected 'the duplicate pull-request smoke workflow' "$fixture"

fixture="$(copy_fixture)"
sed -i '0,/timeout-minutes/{/timeout-minutes/d}' "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'a validation job without timeout-minutes' "$fixture"

fixture="$(copy_fixture)"
rm -f "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'a missing non-publishing production signing preflight' "$fixture"

fixture="$(copy_fixture)"
sed -i 's/tags: \["preflight-v\*"\]/tags: ["v*"]/' "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'a production signing preflight on release tags' "$fixture"

fixture="$(copy_fixture)"
sed -i '/git merge-base --is-ancestor/d' "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'a production signing preflight without protected-branch ancestry' "$fixture"

fixture="$(copy_fixture)"
sed -i 's/vars.ANDROID_SIGNING_CERT_SHA256/vars.WRONG_CERT_SHA256/' "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'a production signing preflight without the reviewed fingerprint' "$fixture"

fixture="$(copy_fixture)"
printf '\n# policy canary\nenv:\n  TOKEN: ${{ secrets.SERVER_REGISTRY_TOKEN }}\n' >> "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'registry publication credentials in the production signing preflight' "$fixture"

fixture="$(copy_fixture)"
printf '\n# policy canary\nenv:\n  TOKEN: ${{ secrets.GITEA_TOKEN }}\n' >> "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'release-asset publishing credentials in the production signing preflight' "$fixture"

fixture="$(copy_fixture)"
sed -i '/^permissions:$/a\  packages: write' "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'package-publish permission in the production signing preflight' "$fixture"

fixture="$(copy_fixture)"
printf '\n# policy canary\nrun: docker push private.example/image:tag\n' >> "$fixture/.gitea/workflows/signing-preflight.yml"
expect_rejected 'a server image publication command in the production signing preflight' "$fixture"

fixture="$(copy_fixture)"
sed -i '/tags: \["smoke-\*"\]/d' "$fixture/.gitea/workflows/smoke.yml"
expect_rejected 'a runner smoke workflow without its Gitea-compatible manual tag trigger' "$fixture"

fixture="$(copy_fixture)"
printf '\npermissions: write-all\n' >> "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'write-all token permissions' "$fixture"

fixture="$(copy_fixture)"
printf '\nuses: actions/checkout@v4\n' >> "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'a mutable action reference' "$fixture"

fixture="$(copy_fixture)"
printf '\n# policy canary\nenv:\n  LEAK: ${{ secrets.ANDROID_SIGNING_KEY_PASSWORD }}\n' >> "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'a release secret in validation' "$fixture"

fixture="$(copy_fixture)"
sed -i '/git merge-base --is-ancestor/d' "$fixture/.gitea/workflows/release.yml"
expect_rejected 'a tag release without protected-branch ancestry verification' "$fixture"

fixture="$(copy_fixture)"
sed -i '/trap cleanup EXIT HUP INT TERM/d' "$fixture/.gitea/workflows/release.yml"
expect_rejected 'release signing files without teardown' "$fixture"

fixture="$(copy_fixture)"
sed -i 's@DOCKER_HOST: unix:///var/run/docker.sock@DOCKER_HOST: unix:///run/other/docker.sock@' "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'a daemon-side socket path injected into jobs' "$fixture"

fixture="$(copy_fixture)"
sed -i "s@TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE: .*@TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE: /var/run/docker.sock@" "$fixture/.gitea/workflows/release.yml"
expect_rejected 'a Ryuk socket path that bypasses the runner variable' "$fixture"

fixture="$(copy_fixture)"
printf '\n# policy canary\ncontainer:\n  options: --privileged\n' >> "$fixture/.gitea/workflows/smoke.yml"
expect_rejected 'a privileged job container' "$fixture"

fixture="$(copy_fixture)"
printf '\n# policy canary\n  pull_request_target:\n' >> "$fixture/.gitea/workflows/validate.yml"
expect_rejected 'a pull_request_target trigger' "$fixture"

fixture="$(copy_fixture)"
mkdir -p "$fixture/.github/workflows"
printf 'name: ci\non: [push]\npermissions:\n  contents: write\njobs: {}\n' > "$fixture/.github/workflows/ci.yml"
expect_rejected 'a GitHub workflow with write permissions' "$fixture"

fixture="$(copy_fixture)"
mkdir -p "$fixture/.github/workflows"
printf 'name: ci\non: [push]\njobs: {}\n' > "$fixture/.github/workflows/ci.yml"
expect_rejected 'a GitHub workflow without read-only permissions' "$fixture"

printf 'PASS: workflow policy regression cases\n'
