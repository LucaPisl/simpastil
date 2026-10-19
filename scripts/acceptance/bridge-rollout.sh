#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ "${SIMPASTIL_ACCEPTANCE_SCOPE:-}" == disposable-testcontainers ]] \
  || fail 'set SIMPASTIL_ACCEPTANCE_SCOPE=disposable-testcontainers to confirm this isolated test run'
for tool in docker npm flutter; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done

TEST_POSTGRES_IMAGE="${TEST_POSTGRES_IMAGE:-docker.io/library/postgres:16.15-alpine3.24@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea}"
[[ "$TEST_POSTGRES_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || fail 'TEST_POSTGRES_IMAGE must be pinned by sha256 digest'
export TEST_POSTGRES_IMAGE

cd "$ROOT/server"
npm test -- \
  src/test/e2e/capabilities.test.ts \
  src/test/e2e/client-build-gate.test.ts \
  src/test/e2e/minimum-client-authority.test.ts

cd "$ROOT/flutter_app"
flutter test test/integration/bridge_rollout_test.dart
