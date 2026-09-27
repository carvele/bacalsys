-- =============================================================================
-- training_view_private_feedback_permission
-- Roadmap v1.2 · Sprint 4 · Task 4.1 (Section 11, "Frozen Permission Decisions")
--
--   training:view_private_feedback   Vice President, President ONLY
--
-- Deliberately excluded: Athlete, Leader, Coach (even the current primary
-- coach, who instead sees private feedback via app_private.current_coach_can_view
-- ownership/relationship, not this permission), and System Administrator (Rule
-- A: a technical system role grants no training/feedback access by itself).
-- Reference data, so it lives in a migration and reaches every environment; the
-- position mapping is repeated in seed.sql for a fresh local database, same
-- idempotent pattern as 20260926120420_workout_permissions.
-- =============================================================================

SELECT set_config('bacalsys.actor_type', 'migration', true);

INSERT INTO public.permissions (name, description) VALUES
  ('training:view_private_feedback', 'View sensitive athlete discomfort notes, discomfort areas and medical substitution reasons across the organization (Sprint 4).')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.position_permissions (position_id, permission_id)
SELECT pos.id, perm.id
FROM (VALUES
  ('Vice President', 'training:view_private_feedback'),
  ('President',      'training:view_private_feedback')
) AS m(position_name, permission_name)
JOIN public.positions pos ON pos.name = m.position_name
JOIN public.permissions perm ON perm.name = m.permission_name
ON CONFLICT (position_id, permission_id) DO NOTHING;
