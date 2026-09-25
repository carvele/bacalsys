-- =============================================================================
-- 001_security_baseline.sql
-- Roadmap v1.2 · Sprint 1 · Task 1.4
--
-- Establishes the security boundaries every later migration relies on:
--   * app_private: unexposed schema for SECURITY DEFINER authorization logic.
--     It is NOT listed in supabase/config.toml [api].schemas, so PostgREST never
--     serves it. USAGE is granted to `authenticated` only so RLS policies can
--     evaluate app_private.* helpers.
--   * Default EXECUTE on new public functions is revoked; every public RPC must
--     be granted explicitly.
--   * Search-path / object-creation protections on public.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Private security schema
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app_private;

REVOKE ALL ON SCHEMA app_private FROM PUBLIC;
REVOKE ALL ON SCHEMA app_private FROM anon;
GRANT USAGE ON SCHEMA app_private TO authenticated;

COMMENT ON SCHEMA app_private IS
  'Private BaCalSys security schema. Never exposed through the Data API. '
  'Holds SECURITY DEFINER authorization helpers, internal RPC implementations and triggers.';

-- Functions created in app_private must never be callable by PUBLIC by default;
-- the few helpers RLS needs are granted to `authenticated` individually.
ALTER DEFAULT PRIVILEGES IN SCHEMA app_private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- Baseline function privileges (verbatim from Roadmap v1.2 §1)
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

-- ADR-002: EXECUTE-for-PUBLIC is a *global* built-in default that per-schema
-- default privileges cannot remove, so the statement above alone leaves new
-- functions callable by every role via PUBLIC. Revoke it globally for the
-- migration role; intended RPCs are always granted explicitly.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Tables and sequences follow the same explicit-grant rule (backlog refinement:
-- mirrors the function baseline so that no future public table is reachable
-- through the Data API without a deliberate GRANT in its migration).
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;

-- -----------------------------------------------------------------------------
-- Search-path protections
-- Only migration roles may create objects in public; this prevents a client
-- role from planting a shadowing function/operator that a SECURITY DEFINER
-- function could resolve. All BaCalSys SECURITY DEFINER functions additionally
-- pin `SET search_path = ''` and schema-qualify every reference.
-- -----------------------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM anon, authenticated;
