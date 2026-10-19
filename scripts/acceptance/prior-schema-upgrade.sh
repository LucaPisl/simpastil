#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ "${SIMPASTIL_ACCEPTANCE_SCOPE:-}" == disposable-testcontainers ]] \
  || fail 'set SIMPASTIL_ACCEPTANCE_SCOPE=disposable-testcontainers to confirm this isolated test run'
command -v docker >/dev/null 2>&1 || fail 'docker is required for the isolated PostgreSQL test container'
command -v npm >/dev/null 2>&1 || fail 'npm is required'

TEST_POSTGRES_IMAGE="${TEST_POSTGRES_IMAGE:-docker.io/library/postgres:16.15-alpine3.24@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea}"
[[ "$TEST_POSTGRES_IMAGE" == *@sha256:* ]] || fail 'TEST_POSTGRES_IMAGE must be pinned by sha256 digest'
export TEST_POSTGRES_IMAGE

cd "$ROOT/server"
npm test -- src/test/e2e/migration-upgrade-baselines.test.ts -t '0011 upgrade quarantines'
