# Migration compatibility and rollback

Status: accepted 2026-10-16, from migration 0024 on.

## Decision

Database migrations follow expand/contract. A release may only add what older
images can ignore; removing or reshaping something older images read happens in
a later release, once no supported image reads it any more.

Every migration from `0024` on starts with one declaration line:

```sql
-- compat: expand
```

or

```sql
-- compat: breaking
SELECT public.raise_migration_compatibility_floor(<this migration's count>);
```

The count is the migration's position in the journal, starting at 1: `0024` is
count 25, `0025` is count 26.

- **expand**: an image built before this migration keeps working on the
  migrated database. The API of that older image reports ready, so rolling back
  is only a matter of starting the older image (`scripts/rollback.sh`).
- **breaking**: older images must not serve this database. The migration raises
  the compatibility floor in `deployment_manifest`, and every image whose
  bundled migration count is below the floor reports not ready. Going back past
  a breaking migration means restoring the automatic pre-migration backup into
  a fresh Compose project.

`scripts/check-migrations.sh` enforces the declaration in CI and in the
repository gates. It rejects an `expand` migration that drops a table, column,
view, function, type, schema or sequence, renames anything, sets `NOT NULL`,
changes a column type or truncates, and a `breaking` migration that does not
raise the floor to its own count. Dropping a constraint or an index stays
allowed in `expand`.

## Reviewer rule

The lint checks shapes, not meaning, so the declaration is a review item. A
migration is breaking whenever an older image could misread what the new code
writes, even if every statement is additive. Examples:

- a new value in a status, kind or enum-like column that older code switches on
  (0023 widened `dose_logs` to accept `missed`; an older image does not know
  that state);
- a new row shape that older readers aggregate or count;
- a function older images call whose behavior changes under `CREATE OR
  REPLACE`.

When in doubt, declare it breaking. A breaking migration only costs the
image-only rollback; a wrong `expand` lets an older image serve data it does
not understand.

## How readiness uses it

Readiness (`/api/v1/health/ready`) is ready when the database is at exactly the
image's bundled migration head, as before. Images from 0024 on are also ready
when the database is ahead, provided all of these hold
(`public.read_migration_compatibility`):

- the image's own bundled head is applied, with the same hash and timestamp;
- every migration up to the bundled head is applied in order;
- the compatibility floor is at or below the image's bundled count.

Images older than 0024 cannot read the floor and stay strict. The first
image-only rollback is therefore from a release after 1.0.0 back to 1.0.0 or
later.

## Related

- `migrate` holds a PostgreSQL advisory lock while it applies migrations and
  records the image version in `deployment_manifest.server_image_digest`.
- Every `docker compose up` runs `premigrate-backup` first. When the image
  bundles migrations the database does not have, it writes a `restore.sh`
  bundle to `SIMPASTIL_BACKUP_DIR` and fails closed. See
  [Upgrade](../../DEPLOYMENT.md#upgrade) and [Rollback](../../DEPLOYMENT.md#rollback).
