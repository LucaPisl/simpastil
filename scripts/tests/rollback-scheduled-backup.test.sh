#!/usr/bin/env bash
# Checks that scripts/rollback.sh stops the 1.2.0 scheduled-backup service when
# the target release has no such command (while this checkout's compose file
# still defines the service), and leaves it alone otherwise. Runs the real
# script against a stub `docker`; nothing touches a real Docker daemon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-rollback.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  "image inspect --format"*) echo sha256:target ;;
  "image inspect"*) ;;
  "run --rm --network none --entrypoint node"*"package.json"*) echo "$STUB_VERSION" ;;
  "run --rm --network none --entrypoint node"*"_journal.json"*) echo 26 ;;
  "run --rm --network none --entrypoint node"*"scheduled-backup.js"*) [[ "$STUB_HAS_SCHEDULED" == 1 ]] || exit 1 ;;
  "compose"*"config --services"*) printf '%s\n' postgres api outbox scheduled-backup ;;
  "compose"*"exec"*) echo "26 20" ;;
  "compose"*"ps --quiet api"*) if [[ -f "$STUB_STARTED" ]]; then echo container-1; fi ;;
  "compose"*" up "*) : > "$STUB_STARTED" ;;
  "inspect --format {{.State.Health.Status}}"*) echo healthy ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

run_rollback() { # target version, whether it bundles scheduled-backup
  export STUB_LOG="$TMP/log-$1-$2" STUB_STARTED="$TMP/started-$1-$2" STUB_VERSION="$1" STUB_HAS_SCHEDULED="$2"
  : > "$STUB_LOG"; rm -f "$STUB_STARTED"
  PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/rollback.sh" --to "$1" --project test-project 2>&1
}

output=$(run_rollback 1.1.1 0) || fail "rollback to 1.1.1 failed: $output"
stop_line=$(grep -n 'compose --project-name test-project stop scheduled-backup' "$TMP/log-1.1.1-0" | cut -d: -f1) \
  || fail 'rollback to a pre-1.2 release did not stop scheduled-backup'
up_line=$(grep -n 'compose --project-name test-project up --detach --no-build --no-deps --force-recreate api outbox' \
  "$TMP/log-1.1.1-0" | cut -d: -f1) || fail 'rollback to 1.1.1 did not recreate api and outbox'
(( stop_line < up_line )) || fail 'scheduled-backup must be stopped before api and outbox are recreated'
grep -q 'not a bare `up`' <<<"$output" || fail 'the pre-1.2 rollback must tell the operator not to run a bare up'
printf 'PASS: rollback to a pre-1.2 release stops scheduled-backup first\n'

output=$(run_rollback 1.2.1 1) || fail "rollback to 1.2.1 failed: $output"
! grep -q 'stop scheduled-backup' "$TMP/log-1.2.1-1" || fail 'a target that has scheduled-backup must keep the service'
grep -q 'force-recreate api outbox' "$TMP/log-1.2.1-1" || fail 'rollback to 1.2.1 did not recreate api and outbox'
printf 'PASS: rollback to a release with scheduled-backup leaves it running\n'

output=$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log-dry" STUB_VERSION=1.1.1 STUB_HAS_SCHEDULED=0 STUB_STARTED="$TMP/s" \
  bash "$ROOT/scripts/rollback.sh" --to 1.1.1 --dry-run 2>&1) || fail "dry run failed: $output"
! grep -q 'stop \|up ' "$TMP/log-dry" || fail '--dry-run must not stop or start anything'
printf 'PASS: --dry-run changes nothing\n'
