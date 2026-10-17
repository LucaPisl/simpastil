-- =============================================================================
-- Migration 0000 — No-op (superseded by 0001)
--
-- This migration originally created tables with IF NOT EXISTS. Migration 0001
-- recreates the same tables without IF NOT EXISTS, causing fresh-install
-- failures (0000 creates → 0001 collides). Replaced with a no-op so the
-- migration chain works on both fresh and existing databases.
--
-- Existing installations: this file is already recorded in __drizzle_migrations
-- so Drizzle skips it. Content change has no effect.
--
-- Fresh installations: runs this no-op, then 0001 creates everything.
-- =============================================================================

SELECT 1;
