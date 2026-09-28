-- =============================================================================
-- skills_permissions
-- Roadmap v1.2 · Sprint 6 · Task 6.1 (Section 13, "Frozen Permission Decisions")
--
--   skills:verify   Coach, Vice President, President   (verify / revoke achievements)
--   skills:manage   Coach, Vice President, President   (create / edit progression criteria)
--
-- Deliberately excluded: Athlete and Leader (a Leader's org-wide training
-- visibility is not skill-verification authority) and System Administrator
-- (Rule A: a technical system role grants no training access by itself).
--
-- `skills:verify` was already part of the Sprint 1 seed catalog. It is repeated
-- here idempotently so it also reaches hosted projects that never ran seed.sql
-- (same reference-data pattern as 20260927130227). Nothing here can fail on an
-- environment that already has it.
--
-- The idempotency ledger gains exactly the six skill mutation types (F-S6-P05),
-- preserving the eight accepted Sprint 4/5 types.
-- =============================================================================

SELECT set_config('bacalsys.actor_type', 'migration', true);

INSERT INTO public.permissions (name, description) VALUES
  ('skills:verify', 'Verify or revoke athlete calisthenics skill milestone achievements (Sprint 6).'),
  ('skills:manage', 'Create and edit club skill trees and progression criteria (Sprint 6).')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.position_permissions (position_id, permission_id)
SELECT pos.id, perm.id
FROM (VALUES
  ('Coach',          'skills:verify'),
  ('Vice President', 'skills:verify'),
  ('President',      'skills:verify'),
  ('Coach',          'skills:manage'),
  ('Vice President', 'skills:manage'),
  ('President',      'skills:manage')
) AS m(position_name, permission_name)
JOIN public.positions pos ON pos.name = m.position_name
JOIN public.permissions perm ON perm.name = m.permission_name
ON CONFLICT (position_id, permission_id) DO NOTHING;

-- Idempotency mutation types (F-S6-P05): the 8 accepted types + the 6 skill types.
ALTER TABLE app_private.idempotency_keys
  DROP CONSTRAINT IF EXISTS idempotency_keys_mutation_type_check;

ALTER TABLE app_private.idempotency_keys
  ADD CONSTRAINT idempotency_keys_mutation_type_check CHECK (
    mutation_type IN (
      'START_SESSION', 'RECORD_SET', 'SUBSTITUTE_EXERCISE', 'COMPLETE_SESSION', 'SYNC_BUNDLE',
      'CREATE_ASSIGNMENT', 'CANCEL_ASSIGNMENT', 'MIGRATE_ASSIGNMENT_VERSION',
      'SET_SKILL_STATUS', 'LOG_SKILL_ATTEMPT', 'REVIEW_SKILL_ATTEMPT', 'VERIFY_SKILL', 'REVOKE_SKILL', 'UPDATE_PROGRESSION'
    )
  );
