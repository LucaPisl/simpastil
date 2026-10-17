# Recoverable refresh rotation

The old refresh protocol revokes a predecessor and creates a random successor in one server transaction. If the response is lost, the client cannot distinguish a consumed refresh from a request that never arrived. Its durable `sending` journal correctly refuses blind replay, but this can require another sign-in after an ordinary interruption.

The additive protocol advertises `contracts.refreshRecovery: 1` and uses `POST /api/v1/auth/refresh/recoverable`. Before dispatch, the client generates a 256-bit successor, writes it to a private secure slot, completes the Android secure-preference durability barrier, and publishes a journal binding the predecessor slot to that proposal. Both secrets are sent over the existing HTTPS, installation-key protected path.

The server locks the user session and predecessor row. First use records the hash of the exact successor and inserts it atomically. An exact retry can obtain a fresh access token only while that successor remains active and unexpired in the same family. A different successor proposal remains refresh-token reuse and revokes the family. A subsequent rotation, logout (including logout with the consumed predecessor), password change, or other session revocation cannot be undone by recovery. No plaintext refresh secret is stored on the server.

The client never downgrades a journaled recoverable attempt to the legacy endpoint. Discovery transport failures do not start an attempt. Older servers without the capability continue using the existing conservative protocol; an old uncertain journal without a durable proposal still requires intervention. This change cannot retroactively recover a successor whose secret was never preserved.

A returned credential bundle is separately staged and journaled before the active pointer changes. Interrupted publication resumes from the staged response. A truncated unpublished `.next` file does not supersede the valid atomically published journal. A corrupt primary journal remains fail-closed.

## Rollout

Production rollout requires explicit operator authorization. Deploy migration `0018_recoverable_refresh.sql` and the server before expecting automatic recovery on a client. It adds receipt hashes/rotation times and makes refresh token hashes unique. Check for duplicate hash groups before applying the unique index; do not delete or rewrite a duplicate merely to make migration pass. Use one appropriate fresh database backup for the approved rollout.

Old clients and the legacy endpoint remain supported. Recovery receipts are retained for the successor's 30-day lifetime, based on rotation time rather than predecessor creation time. Token GC no longer attempts an unscoped deletion of medical tombstones: the legacy medication authority trigger rejects it, even with no matching rows. Medical retention requires its own reviewed authority path; historical rows remain retained.

## Verification

Synthetic server tests cover lost responses, concurrent identical requests, mismatched replay, consumed-predecessor logout, expired and already-rotated successors, password-change revocation, and retention of an old predecessor rotated recently. Client regressions cover durable retries across coordinator restart, refused retries without downgrade, capability transport failure, legacy-server fallback, response publication recovery, truncated unpublished journal, and a failed secure-storage durability barrier preventing network dispatch.

Native/profile build and local-server acceptance are recorded separately. Passing these checks does not establish that an older production server has this protocol.

### Production acceptance — October 9, 2026

The operator authorized and executed the guarded rollout of a merged pull request,
revision `d5050214d26310eb6914f8ce765629ec0db44725`. The reported checks passed:
no duplicate refresh-token hash groups, one fresh database/global-role backup
with archive and checksum validation, migration 0018 applied once with its hash
verified and existing deployment authority preserved, and API/outbox startup on
the same pinned image. The image digest is
`sha256:d771d2033d833bf378453574f47b0f1319f0cbc041386da9ddceaee3592c4c0e`.
The database container and loopback API binding were preserved. Backup validation
here means archive readability and checksums, not a full restore rehearsal.

A separate public-endpoint check after the operator's result confirmed readiness
and `refreshRecovery: 1`. Existing PRN command/sync contracts remain 1/5 and the
medication ledger remains inactive. The production protocol is therefore now
available. Natural phone refresh/interruption behavior still requires ongoing
acceptance; this rollout cannot recover an old uncertain journal without its
durable successor proposal or resolve ambiguous medication history.
