-- =============================================================================
-- 007_advisor_hardening.sql
-- Sprint 1 · Backlog refinement from the Supabase database advisors, run
-- against the hosted dev project after the live walking-skeleton verification.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Lint 0011 function_search_path_mutable
-- The verbatim baseline trigger function (004) does not pin search_path.
-- Pin it without touching the baseline body.
-- -----------------------------------------------------------------------------
ALTER FUNCTION app_private.prevent_audit_log_mutation() SET search_path = '';

-- -----------------------------------------------------------------------------
-- Lint 0001 unindexed_foreign_keys
-- Covering indexes keep FK checks and ON DELETE SET NULL / RESTRICT cascades
-- (e.g. deleting a profile that assigned positions) from scanning whole tables.
-- -----------------------------------------------------------------------------
CREATE INDEX member_positions_position_id_idx ON public.member_positions (position_id);
CREATE INDEX member_positions_assigned_by_idx ON public.member_positions (assigned_by);
CREATE INDEX member_positions_ended_by_idx ON public.member_positions (ended_by);

CREATE INDEX user_system_roles_role_id_idx ON public.user_system_roles (role_id);
CREATE INDEX user_system_roles_assigned_by_idx ON public.user_system_roles (assigned_by);
CREATE INDEX user_system_roles_ended_by_idx ON public.user_system_roles (ended_by);

CREATE INDEX invitations_claimed_by_idx ON public.invitations (claimed_by);
CREATE INDEX invitations_preassigned_position_id_idx ON public.invitations (preassigned_position_id);
