#!/usr/bin/env bash
# Exercises scripts/check-migrations.sh against a copy of the real migrations
# plus one synthetic next migration per case.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpastil-check-migrations.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

next_number="$(find "$ROOT/server/src/db/migrations" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]_*.sql' | wc -l)"
next_count=$((next_number + 1))
next_file="$(printf '%04d_case.sql' "$next_number")"

run_case() {
  local name="$1" expected="$2" sql="$3" fixture="$TMP/$1"
  mkdir -p "$fixture/server/src/db"
  cp -R "$ROOT/server/src/db/migrations" "$fixture/server/src/db/migrations"
  printf '%s\n' "$sql" >"$fixture/server/src/db/migrations/$next_file"
  node -e '
    const fs = require("fs"); const path = process.argv[1];
    const journal = JSON.parse(fs.readFileSync(path, "utf8"));
    const last = journal.entries.at(-1);
    journal.entries.push({ ...last, idx: last.idx + 1, when: last.when + 1, tag: process.argv[2] });
    fs.writeFileSync(path, JSON.stringify(journal, null, 2));
  ' "$fixture/server/src/db/migrations/meta/_journal.json" "${next_file%.sql}"
  local output status=0
  output="$(bash "$ROOT/scripts/check-migrations.sh" "$fixture" 2>&1)" || status=$?
  if [[ "$expected" == pass && "$status" != 0 ]]; then fail "$name should pass: $output"; fi
  if [[ "$expected" != pass ]]; then
    [[ "$status" != 0 ]] || fail "$name should fail"
    grep -Fq "$expected" <<<"$output" || fail "$name failed for the wrong reason: $output"
  fi
}

bash "$ROOT/scripts/check-migrations.sh" "$ROOT" >/dev/null || fail 'the shipped migrations must pass'

run_case expand-add pass '-- compat: expand
ALTER TABLE "pills" ADD COLUMN "note" text;'
run_case expand-drop-constraint pass '-- compat: expand
ALTER TABLE "pills" DROP CONSTRAINT "pills_name_check";'
run_case undeclared 'exactly one' 'ALTER TABLE "pills" ADD COLUMN "note" text;'
run_case declared-late 'must start with' 'ALTER TABLE "pills" ADD COLUMN "note" text;
-- compat: expand'
run_case declared-twice 'exactly one' '-- compat: expand
-- compat: breaking
SELECT 1;'
run_case expand-drop-column 'declared expand but contains' '-- compat: expand
ALTER TABLE "pills" DROP COLUMN "note";'
run_case expand-rename 'declared expand but contains' '-- compat: expand
ALTER TABLE "pills" RENAME COLUMN "note" TO "notes";'
run_case expand-type-split-lines 'declared expand but contains' '-- compat: expand
ALTER TABLE "pills"
  ALTER COLUMN "note"
  SET DATA TYPE varchar(20);'
run_case expand-not-null 'declared expand but contains' '-- compat: expand
ALTER TABLE "pills" ALTER COLUMN "note" SET NOT NULL;'
run_case expand-raises-floor 'raises the compatibility floor' "-- compat: expand
SELECT public.raise_migration_compatibility_floor($next_count);"
run_case breaking-without-floor 'does not call' '-- compat: breaking
ALTER TABLE "pills" DROP COLUMN "note";'
run_case breaking-wrong-floor 'does not call' "-- compat: breaking
ALTER TABLE \"pills\" DROP COLUMN \"note\";
SELECT public.raise_migration_compatibility_floor($next_number);"
run_case breaking-with-floor pass "-- compat: breaking
ALTER TABLE \"pills\" DROP COLUMN \"note\";
SELECT public.raise_migration_compatibility_floor($next_count);"
run_case comment-mentions-drop pass '-- compat: expand
-- A later contract release will DROP COLUMN "legacy" once nothing reads it.
ALTER TABLE "pills" ADD COLUMN "note" text;'
run_case block-comment-floor 'does not call' "-- compat: breaking
ALTER TABLE \"pills\" DROP COLUMN \"note\";
/* SELECT public.raise_migration_compatibility_floor($next_count); */"
run_case block-comment-mentions-drop pass '-- compat: expand
/* Later: DROP TABLE "legacy"
   once nothing reads it. */
ALTER TABLE "pills" ADD COLUMN "note" text;'

printf 'PASS: check-migrations policy tests\n'
