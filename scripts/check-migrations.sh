#!/usr/bin/env bash
# Migration compatibility gate (docs/decisions/migration-compatibility.md).
#
# Every migration from 0024 on declares, on its first line, whether an image
# built before it can still run on the migrated database:
#
#   -- compat: expand     older images keep working (rollback by image only)
#   -- compat: breaking   older images must not run; the migration raises the
#                         compatibility floor to its own migration count
#
# An expand migration may not contain statements that remove or reshape what an
# older image reads. Dropping a constraint or an index stays allowed: it only
# widens what the database accepts. A clean pass does not prove compatibility: new states or
# enum values that older code cannot handle are breaking too, and reviewers
# decide that. This gate only makes the declaration explicit and catches the
# shapes that are never expand.
set -euo pipefail

ROOT="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
MIGRATIONS="$ROOT/server/src/db/migrations"
FIRST_DECLARED=24
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -d "$MIGRATIONS" ]] || fail "migration directory is missing: $MIGRATIONS"
mapfile -t files < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' -printf '%f\n' | sort)
[[ "${#files[@]}" -gt 0 ]] || fail 'no migrations found'

journal_count="$(node -e "console.log(require(process.argv[1]).entries.length)" "$MIGRATIONS/meta/_journal.json")"
[[ "$journal_count" == "${#files[@]}" ]] ||
  fail "journal lists $journal_count migrations but ${#files[@]} SQL files exist"

for index in "${!files[@]}"; do
  file="${files[$index]}"
  number=$((10#${file%%_*}))
  [[ "$number" == "$index" ]] || fail "migration numbering has a gap or duplicate at $file"
  (( number >= FIRST_DECLARED )) || continue

  path="$MIGRATIONS/$file"
  count=$((index + 1))
  declarations="$(grep -cE '^--[[:space:]]*compat:' "$path" || true)"
  [[ "$declarations" == 1 ]] || fail "$file must carry exactly one '-- compat: expand|breaking' line"
  first_line="$(head -n 1 "$path")"
  [[ "$first_line" =~ ^--[[:space:]]*compat:[[:space:]]*(expand|breaking)[[:space:]]*$ ]] ||
    fail "$file must start with '-- compat: expand' or '-- compat: breaking'"
  kind="${BASH_REMATCH[1]}"

  # Comments removed and the file flattened, so a statement split over lines still matches.
  body="$(perl -0777 -pe 's{/\*.*?\*/}{ }gs; s/--[^\n]*//g' "$path" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  floor_call="raise_migration_compatibility_floor[[:space:]]*\\([[:space:]]*$count[[:space:]]*\\)"

  if [[ "$kind" == expand ]]; then
    if grep -qiE 'raise_migration_compatibility_floor[[:space:]]*\([[:space:]]*[0-9]' <<<"$body"; then
      fail "$file is declared expand but raises the compatibility floor"
    fi
    for pattern in \
      'DROP (TABLE|COLUMN|VIEW|MATERIALIZED VIEW|FUNCTION|TYPE|SCHEMA|SEQUENCE)' \
      'RENAME' \
      'SET NOT NULL' \
      'ALTER COLUMN [^;]* (SET DATA )?TYPE' \
      'TRUNCATE'; do
      if match="$(grep -oiE "$pattern" <<<"$body" | head -n 1)" && [[ -n "$match" ]]; then
        fail "$file is declared expand but contains '${match:0:80}'; split it into expand and contract releases or declare it breaking"
      fi
    done
  else
    grep -qiE "$floor_call" <<<"$body" ||
      fail "$file is declared breaking but does not call public.raise_migration_compatibility_floor($count)"
  fi
done

printf 'PASS: migration compatibility declarations (%s migrations)\n' "${#files[@]}"
