-- Read-only production acceptance queries for the medication-ledger cutover.
-- Do not run these against a live database without an explicit operator request.

-- Authority and schema marker.
SELECT schema_version, contract_version, ledger_activated,
       enforced_minimum_client_build, target_minimum_client_build
FROM public.deployment_manifest;

-- Activation blockers: every unresolved issue code is intentionally included.
SELECT issue_code, count(*) AS unresolved_count
FROM public.migration_issues
WHERE state = 'unresolved'
GROUP BY issue_code
ORDER BY issue_code;

-- Legacy writes that have not been mapped into immutable history.
SELECT count(*) AS uncovered_journal_rows
FROM public.medication_handoff_journal
WHERE coverage_state <> 'covered';

SELECT count(*) AS uncovered_legacy_history_rows
FROM public.legacy_medication_history
WHERE coverage_state <> 'covered';

-- Incomplete bridge retry claims / command bundles.
SELECT count(*) AS incomplete_bridge_receipts
FROM public.preactivation_medication_receipts
WHERE complete IS FALSE
   OR observed_subeffect_count <> expected_subeffect_count
   OR result_metadata IS NULL;

SELECT r.user_id, r.command_bundle_id, r.expected_subeffect_count,
       r.observed_subeffect_count, count(j.id) AS journal_rows
FROM public.preactivation_medication_receipts r
LEFT JOIN public.medication_handoff_journal j
  ON j.user_id = r.user_id AND j.command_bundle_id = r.command_bundle_id
WHERE r.complete IS TRUE
GROUP BY r.user_id, r.command_bundle_id,
         r.expected_subeffect_count, r.observed_subeffect_count
HAVING count(j.id) <> r.observed_subeffect_count;

-- Tracked pill balance must be fully represented by append-only inventory events.
SELECT p.id AS pill_id, pr.user_id, p.current_stock,
       coalesce(sum(e.delta), 0)::bigint AS ledger_balance
FROM public.pills p
JOIN public.profiles pr ON pr.id = p.profile_id
LEFT JOIN public.inventory_events e
  ON e.user_id = pr.user_id AND e.pill_id = p.id
WHERE p.current_stock IS NOT NULL
GROUP BY p.id, pr.user_id, p.current_stock
HAVING p.current_stock::bigint <> coalesce(sum(e.delta), 0)::bigint;

-- A user cannot have duplicate canonical occurrence identities.
SELECT user_id, occurrence_key, count(*) AS duplicate_count
FROM public.medication_occurrences
GROUP BY user_id, occurrence_key
HAVING count(*) > 1;

-- Occurrences still expected for a revision must not have been superseded.
SELECT id, user_id, schedule_id, schedule_revision, planned_local_date,
       superseded_at, superseded_by_occurrence_id
FROM public.medication_occurrences
WHERE source = 'scheduled' AND expected IS TRUE AND superseded_at IS NOT NULL
ORDER BY user_id, planned_local_date, id;

-- Verify every covered legacy history item points at its immutable sync entry.
SELECT h.history_entry_id, h.user_id, h.coverage_state, h.sync_change_id
FROM public.legacy_medication_history h
LEFT JOIN public.sync_changes c
  ON c.id = h.sync_change_id AND c.user_id = h.user_id
WHERE h.coverage_state = 'covered' AND c.id IS NULL;

-- Every committed compatibility-write journal revision has a typed identity mapping.
SELECT j.id, j.user_id, j.legacy_source_kind, j.legacy_source_id, j.source_revision
FROM public.medication_handoff_journal j
WHERE NOT EXISTS (
  SELECT 1 FROM public.sync_changes c
  WHERE c.user_id = j.user_id AND c.source_kind = 'bridge_mapping'
    AND c.source_id = j.legacy_source_id AND c.source_revision = j.source_revision
    AND c.entity_type = 'identity_mapping'
);
