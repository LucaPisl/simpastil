-- =============================================================================
-- Migration 0012 — auth recovery, transactional outbox, and deployment state
--
-- The ordered 0000–0011 SQL remains authoritative for its historical objects.
-- This file contains only the additive 0012 objects and the reviewed
-- generator-gap semantics for those objects. Every statement is safe to replay
-- on a disposable upgrade fixture.
-- =============================================================================

-- ─── 1. Session versions ─────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS session_version BIGINT NOT NULL DEFAULT 1;
--> statement-breakpoint
ALTER TABLE admin_config
  ADD COLUMN IF NOT EXISTS session_version BIGINT NOT NULL DEFAULT 1;
--> statement-breakpoint

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_session_version_check'
  ) THEN
    ALTER TABLE users
      ADD CONSTRAINT users_session_version_check CHECK (session_version > 0);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'admin_config_session_version_check'
  ) THEN
    ALTER TABLE admin_config
      ADD CONSTRAINT admin_config_session_version_check CHECK (session_version > 0);
  END IF;
END $$;
--> statement-breakpoint

-- ─── 2. Runtime roles used by the API and the isolated worker ────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = 'outbox_user'
  ) THEN
    CREATE ROLE outbox_user
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOINHERIT
      NOLOGIN
      PASSWORD NULL;
  END IF;
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = 'deployment_authority_owner'
  ) THEN
    CREATE ROLE deployment_authority_owner
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOINHERIT
      NOLOGIN
      PASSWORD NULL;
  END IF;
END $$;
--> statement-breakpoint
GRANT USAGE ON SCHEMA public TO outbox_user;
GRANT USAGE ON SCHEMA public TO deployment_authority_owner;
--> statement-breakpoint

-- ─── 3. Single-use bootstrap proof ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS admin_bootstrap_state (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton_key BOOLEAN NOT NULL DEFAULT TRUE,
  token_hash TEXT NOT NULL UNIQUE,
  generation BIGINT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  CONSTRAINT admin_bootstrap_state_token_hash_unique UNIQUE (token_hash),
  CONSTRAINT admin_bootstrap_state_singleton_key UNIQUE (singleton_key),
  CONSTRAINT admin_bootstrap_state_singleton_check CHECK (singleton_key IS TRUE),
  CONSTRAINT admin_bootstrap_state_generation_check CHECK (generation > 0)
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS admin_bootstrap_state_expires_at_idx
  ON admin_bootstrap_state(expires_at);
--> statement-breakpoint

-- Existing configured installations have already completed bootstrap. The
-- deterministic value is a validation hash, never a recoverable token.
INSERT INTO admin_bootstrap_state (
  singleton_key, token_hash, generation, created_at, expires_at, consumed_at
)
SELECT
  TRUE,
  md5('migration-0012:' || ac.id::text) || md5('bootstrap:' || ac.id::text),
  1,
  ac.created_at,
  ac.created_at,
  now()
FROM admin_config ac
WHERE NOT EXISTS (SELECT 1 FROM admin_bootstrap_state);
--> statement-breakpoint

-- Clean installations receive one short-lived proof. Only the hash is stored.
INSERT INTO admin_bootstrap_state (
  singleton_key, token_hash, generation, created_at, expires_at
)
SELECT
  TRUE,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text),
  1,
  now(),
  now() + interval '30 minutes'
WHERE NOT EXISTS (SELECT 1 FROM admin_bootstrap_state);
--> statement-breakpoint

-- ─── 4. Hash-only invitation proofs ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS invitation_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash TEXT NOT NULL,
  recipient_email TEXT NOT NULL,
  api_key_id UUID NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT invitation_tokens_token_hash_unique UNIQUE (token_hash),
  CONSTRAINT invitation_tokens_api_key_id_api_keys_id_fk
    FOREIGN KEY (api_key_id) REFERENCES api_keys(id) ON DELETE RESTRICT
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS invitation_tokens_api_key_id_idx
  ON invitation_tokens(api_key_id);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS invitation_tokens_expires_at_idx
  ON invitation_tokens(expires_at);
--> statement-breakpoint

-- ─── 5. Envelope-only transactional outbox ──────────────────────────────────

CREATE TABLE IF NOT EXISTS outbox_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_type TEXT NOT NULL,
  recipient_ref TEXT NOT NULL,
  encrypted_delivery_payload TEXT,
  state TEXT NOT NULL DEFAULT 'queued',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  safe_error_category TEXT,
  correlation_id TEXT,
  lease_expires_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT outbox_messages_state_check
    CHECK (state IN ('queued', 'sending', 'retrying', 'sent', 'failedPermanent')),
  CONSTRAINT outbox_messages_attempt_count_check CHECK (attempt_count >= 0),
  CONSTRAINT outbox_messages_payload_state_check CHECK (
    (state IN ('queued', 'sending', 'retrying') AND encrypted_delivery_payload IS NOT NULL)
    OR state IN ('sent', 'failedPermanent')
  )
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS outbox_messages_claim_idx
  ON outbox_messages(state, next_attempt_at);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS outbox_messages_expires_at_idx
  ON outbox_messages(expires_at);
--> statement-breakpoint

-- API may enqueue only a fresh queued envelope. The worker alone can claim,
-- retry, deliver, or erase ciphertext.
ALTER TABLE outbox_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox_messages FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
DROP POLICY IF EXISTS outbox_app_insert_policy ON outbox_messages;
CREATE POLICY outbox_app_insert_policy ON outbox_messages
  FOR INSERT TO app_user
  WITH CHECK (
    state = 'queued'
    AND attempt_count = 0
    AND encrypted_delivery_payload IS NOT NULL
  );
--> statement-breakpoint
DROP POLICY IF EXISTS outbox_worker_select_policy ON outbox_messages;
CREATE POLICY outbox_worker_select_policy ON outbox_messages
  FOR SELECT TO outbox_user USING (true);
--> statement-breakpoint
DROP POLICY IF EXISTS outbox_worker_update_policy ON outbox_messages;
CREATE POLICY outbox_worker_update_policy ON outbox_messages
  FOR UPDATE TO outbox_user USING (true) WITH CHECK (true);
--> statement-breakpoint

-- ─── 6. Deployment release/authority state ───────────────────────────────────

CREATE TABLE IF NOT EXISTS deployment_manifest (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton_key BOOLEAN NOT NULL DEFAULT TRUE,
  schema_version INTEGER NOT NULL DEFAULT 12,
  contract_version BIGINT NOT NULL DEFAULT 1,
  ledger_activated BOOLEAN NOT NULL DEFAULT FALSE,
  enforced_minimum_client_build INTEGER NOT NULL DEFAULT 1,
  target_minimum_client_build INTEGER NOT NULL DEFAULT 2,
  release_id TEXT NOT NULL DEFAULT 'migration-0012',
  server_image_digest TEXT NOT NULL DEFAULT 'unknown',
  migration_completed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT deployment_manifest_singleton_key UNIQUE (singleton_key),
  CONSTRAINT deployment_manifest_singleton_check CHECK (singleton_key IS TRUE),
  CONSTRAINT deployment_manifest_schema_version_check CHECK (schema_version > 0),
  CONSTRAINT deployment_manifest_contract_version_check CHECK (contract_version > 0),
  CONSTRAINT deployment_manifest_enforced_build_check CHECK (enforced_minimum_client_build > 0),
  CONSTRAINT deployment_manifest_target_build_check CHECK (target_minimum_client_build = 2)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS deployment_authority_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL,
  old_contract_version BIGINT NOT NULL,
  new_contract_version BIGINT NOT NULL,
  old_ledger_activated BOOLEAN NOT NULL,
  new_ledger_activated BOOLEAN NOT NULL,
  old_enforced_minimum_client_build INTEGER NOT NULL,
  new_enforced_minimum_client_build INTEGER NOT NULL,
  change_reference TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT deployment_authority_events_type_check
    CHECK (event_type IN ('ledger_activation', 'minimum_client_build')),
  CONSTRAINT deployment_authority_events_contract_version_check
    CHECK (old_contract_version > 0 AND new_contract_version >= old_contract_version),
  CONSTRAINT deployment_authority_events_build_check
    CHECK (old_enforced_minimum_client_build > 0 AND new_enforced_minimum_client_build > 0),
  CONSTRAINT deployment_authority_events_transition_check
    CHECK (
      (
        event_type = 'ledger_activation'
        AND old_ledger_activated IS FALSE
        AND new_ledger_activated IS TRUE
        AND old_enforced_minimum_client_build = new_enforced_minimum_client_build
      ) OR (
        event_type = 'minimum_client_build'
        AND old_ledger_activated = new_ledger_activated
        AND old_contract_version = new_contract_version
      )
    ),
  CONSTRAINT deployment_authority_events_reference_check
    CHECK (length(change_reference) BETWEEN 1 AND 256)
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS deployment_authority_events_created_at_idx
  ON deployment_authority_events(created_at);
--> statement-breakpoint

INSERT INTO deployment_manifest (
  singleton_key, schema_version, contract_version, ledger_activated,
  enforced_minimum_client_build, target_minimum_client_build,
  release_id, server_image_digest, migration_completed_at
)
SELECT TRUE, 12, 1, FALSE, 1, 2, 'migration-0012', 'unknown', now()
WHERE NOT EXISTS (SELECT 1 FROM deployment_manifest);
--> statement-breakpoint

-- The bootstrap row is consumed by the API but rotated only by the privileged
-- operator role. Runtime UPDATE privilege is restricted to the one-way claim.
CREATE OR REPLACE FUNCTION protect_admin_bootstrap_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF current_user = 'deployment_authority_owner' THEN
    IF NEW.singleton_key IS NOT TRUE OR NEW.generation <= OLD.generation THEN
      RAISE EXCEPTION 'bootstrap rotation must preserve the singleton and advance generation';
    END IF;
    RETURN NEW;
  END IF;

  IF current_user = 'app_user'
     AND OLD.consumed_at IS NULL
     AND NEW.consumed_at IS NOT NULL
     AND NEW.id = OLD.id
     AND NEW.singleton_key = OLD.singleton_key
     AND NEW.token_hash = OLD.token_hash
     AND NEW.generation = OLD.generation
     AND NEW.created_at = OLD.created_at
     AND NEW.expires_at = OLD.expires_at THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'bootstrap state may only be consumed once or rotated by the operator';
END;
$$;
--> statement-breakpoint
DROP TRIGGER IF EXISTS admin_bootstrap_state_guard ON admin_bootstrap_state;
CREATE TRIGGER admin_bootstrap_state_guard
  BEFORE UPDATE ON admin_bootstrap_state
  FOR EACH ROW EXECUTE FUNCTION protect_admin_bootstrap_state();
--> statement-breakpoint

-- Deletion is never a valid authority operation. Row triggers do not fire for
-- TRUNCATE, so both paths are guarded explicitly for the bootstrap singleton
-- and the deployment authority tables.
CREATE OR REPLACE FUNCTION prevent_authority_state_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'deletion of authority state is forbidden for %', TG_TABLE_NAME;
END;
$$;
--> statement-breakpoint
DROP TRIGGER IF EXISTS admin_bootstrap_state_delete_guard ON admin_bootstrap_state;
CREATE TRIGGER admin_bootstrap_state_delete_guard
  BEFORE DELETE ON admin_bootstrap_state
  FOR EACH ROW EXECUTE FUNCTION prevent_authority_state_deletion();
--> statement-breakpoint
DROP TRIGGER IF EXISTS admin_bootstrap_state_truncate_guard ON admin_bootstrap_state;
CREATE TRIGGER admin_bootstrap_state_truncate_guard
  BEFORE TRUNCATE ON admin_bootstrap_state
  FOR EACH STATEMENT EXECUTE FUNCTION prevent_authority_state_deletion();
--> statement-breakpoint

-- Authority tables are owned by a no-login role. The security-definer
-- transition function is the only path that can insert an audit event and
-- update the manifest in one transaction.
ALTER TABLE admin_bootstrap_state OWNER TO deployment_authority_owner;
ALTER TABLE deployment_manifest OWNER TO deployment_authority_owner;
ALTER TABLE deployment_authority_events OWNER TO deployment_authority_owner;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION protect_deployment_manifest()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF current_user <> 'deployment_authority_owner' THEN
    RAISE EXCEPTION 'deployment authority must use the audited transition function';
  END IF;
  IF OLD.target_minimum_client_build <> NEW.target_minimum_client_build
     OR NEW.target_minimum_client_build <> 2 THEN
    RAISE EXCEPTION 'deployment release target is immutable';
  END IF;
  IF OLD.ledger_activated AND NOT NEW.ledger_activated THEN
    RAISE EXCEPTION 'ledger activation cannot be rolled back';
  END IF;
  IF NEW.contract_version < OLD.contract_version THEN
    RAISE EXCEPTION 'deployment contract version cannot be rolled back';
  END IF;
  RETURN NEW;
END;
$$;
--> statement-breakpoint
DROP TRIGGER IF EXISTS deployment_manifest_authority_guard ON deployment_manifest;
CREATE TRIGGER deployment_manifest_authority_guard
  BEFORE UPDATE ON deployment_manifest
  FOR EACH ROW EXECUTE FUNCTION protect_deployment_manifest();
--> statement-breakpoint
DROP TRIGGER IF EXISTS deployment_manifest_delete_guard ON deployment_manifest;
CREATE TRIGGER deployment_manifest_delete_guard
  BEFORE DELETE ON deployment_manifest
  FOR EACH ROW EXECUTE FUNCTION prevent_authority_state_deletion();
--> statement-breakpoint
DROP TRIGGER IF EXISTS deployment_manifest_truncate_guard ON deployment_manifest;
CREATE TRIGGER deployment_manifest_truncate_guard
  BEFORE TRUNCATE ON deployment_manifest
  FOR EACH STATEMENT EXECUTE FUNCTION prevent_authority_state_deletion();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION prevent_deployment_authority_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND current_user = 'deployment_authority_owner' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'deployment authority events are append-only';
END;
$$;
--> statement-breakpoint
DROP TRIGGER IF EXISTS deployment_authority_events_append_only ON deployment_authority_events;
CREATE TRIGGER deployment_authority_events_append_only
  BEFORE INSERT OR UPDATE OR DELETE ON deployment_authority_events
  FOR EACH ROW EXECUTE FUNCTION prevent_deployment_authority_event_mutation();
--> statement-breakpoint
DROP TRIGGER IF EXISTS deployment_authority_events_truncate_guard ON deployment_authority_events;
CREATE TRIGGER deployment_authority_events_truncate_guard
  BEFORE TRUNCATE ON deployment_authority_events
  FOR EACH STATEMENT EXECUTE FUNCTION prevent_authority_state_deletion();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION set_deployment_authority(
  p_new_contract_version BIGINT,
  p_new_ledger_activated BOOLEAN,
  p_new_enforced_minimum_client_build INTEGER,
  p_event_type TEXT,
  p_change_reference TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  current_manifest deployment_manifest%ROWTYPE;
BEGIN
  IF length(p_change_reference) NOT BETWEEN 1 AND 256 THEN
    RAISE EXCEPTION 'deployment authority change reference is invalid';
  END IF;

  SELECT * INTO STRICT current_manifest
  FROM deployment_manifest
  FOR UPDATE;

  IF p_new_contract_version < current_manifest.contract_version THEN
    RAISE EXCEPTION 'deployment contract version cannot be rolled back';
  END IF;
  IF current_manifest.ledger_activated AND NOT p_new_ledger_activated THEN
    RAISE EXCEPTION 'ledger activation cannot be rolled back';
  END IF;

  IF p_event_type = 'ledger_activation' THEN
    IF current_manifest.ledger_activated
       OR NOT p_new_ledger_activated
       OR p_new_enforced_minimum_client_build <> current_manifest.enforced_minimum_client_build THEN
      RAISE EXCEPTION 'ledger activation must be a one-way audited transition';
    END IF;
  ELSIF p_event_type = 'minimum_client_build' THEN
    IF p_new_ledger_activated <> current_manifest.ledger_activated
       OR p_new_contract_version <> current_manifest.contract_version THEN
      RAISE EXCEPTION 'minimum client build transition changed unrelated authority';
    END IF;
  ELSE
    RAISE EXCEPTION 'unknown deployment authority event type';
  END IF;

  INSERT INTO deployment_authority_events (
    event_type,
    old_contract_version,
    new_contract_version,
    old_ledger_activated,
    new_ledger_activated,
    old_enforced_minimum_client_build,
    new_enforced_minimum_client_build,
    change_reference
  ) VALUES (
    p_event_type,
    current_manifest.contract_version,
    p_new_contract_version,
    current_manifest.ledger_activated,
    p_new_ledger_activated,
    current_manifest.enforced_minimum_client_build,
    p_new_enforced_minimum_client_build,
    p_change_reference
  );

  UPDATE deployment_manifest
  SET contract_version = p_new_contract_version,
      ledger_activated = p_new_ledger_activated,
      enforced_minimum_client_build = p_new_enforced_minimum_client_build,
      updated_at = now()
  WHERE id = current_manifest.id;
END;
$$;
--> statement-breakpoint
ALTER FUNCTION set_deployment_authority(BIGINT, BOOLEAN, INTEGER, TEXT, TEXT)
  OWNER TO deployment_authority_owner;
ALTER FUNCTION protect_admin_bootstrap_state() OWNER TO deployment_authority_owner;
ALTER FUNCTION protect_deployment_manifest() OWNER TO deployment_authority_owner;
ALTER FUNCTION prevent_deployment_authority_event_mutation() OWNER TO deployment_authority_owner;
ALTER FUNCTION prevent_authority_state_deletion() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION set_deployment_authority(BIGINT, BOOLEAN, INTEGER, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION protect_admin_bootstrap_state() FROM PUBLIC;
REVOKE ALL ON FUNCTION protect_deployment_manifest() FROM PUBLIC;
REVOKE ALL ON FUNCTION prevent_deployment_authority_event_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION prevent_authority_state_deletion() FROM PUBLIC;
--> statement-breakpoint

-- ─── 7. Explicit grants: no authority mutation or API outbox reads ──────────

REVOKE ALL ON admin_bootstrap_state, invitation_tokens, outbox_messages,
  deployment_manifest, deployment_authority_events FROM app_user, outbox_user;
--> statement-breakpoint
GRANT SELECT, UPDATE (consumed_at) ON admin_bootstrap_state TO app_user;
GRANT SELECT ON invitation_tokens TO app_user;
GRANT INSERT (token_hash, recipient_email, api_key_id, expires_at) ON invitation_tokens TO app_user;
GRANT UPDATE (consumed_at, revoked_at) ON invitation_tokens TO app_user;
GRANT SELECT ON deployment_manifest, deployment_authority_events TO app_user;
--> statement-breakpoint
GRANT INSERT (
  message_type, recipient_ref, encrypted_delivery_payload, state, attempt_count,
  next_attempt_at, safe_error_category, correlation_id, expires_at
) ON outbox_messages TO app_user;
--> statement-breakpoint

GRANT SELECT (
  id, message_type, recipient_ref, encrypted_delivery_payload, state, attempt_count,
  next_attempt_at, safe_error_category, correlation_id, lease_expires_at, sent_at,
  expires_at, created_at, updated_at
) ON outbox_messages TO outbox_user;
GRANT UPDATE (
  encrypted_delivery_payload, state, attempt_count, next_attempt_at,
  safe_error_category, correlation_id, lease_expires_at, sent_at, updated_at
) ON outbox_messages TO outbox_user;
--> statement-breakpoint

-- Keep the worker role isolated even if a later provisioning step grants it
-- login. It receives no application-domain table privileges here.
REVOKE ALL ON users, profiles, pills, schedules, dose_logs, refresh_tokens,
  password_reset_tokens, api_keys, admin_config, admin_refresh_tokens,
  audit_logs, backup_codes FROM outbox_user;
