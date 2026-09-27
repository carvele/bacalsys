-- =============================================================================
-- workout_permissions
-- Roadmap v1.2 · Sprint 3 · Task 3.1 (frozen Decision D5, Section 10)
--
--   workouts:publish_org  Coach, Vice President, President
--   workouts:manage_org   Vice President, President
--
-- Athlete and Leader receive neither (Leader keeps workout:assign from D1).
-- Reference data, so it lives in a migration and reaches every environment.
-- Position mappings are inserted by name: on an existing database (hosted dev)
-- they land now; on a fresh local database the positions do not exist yet and
-- seed.sql applies the same mappings. Both paths are idempotent.
-- =============================================================================

SELECT set_config('bacalsys.actor_type', 'migration', true);

INSERT INTO public.permissions (name, description) VALUES
  ('workouts:publish_org', 'Author organization-visible workout templates or promote private templates to organization visibility (D5).'),
  ('workouts:manage_org',  'Edit metadata, publish versions of, or archive another member''s organization-visible workout template (D5).')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.position_permissions (position_id, permission_id)
SELECT pos.id, perm.id
FROM (VALUES
  ('Coach',          'workouts:publish_org'),

  ('Vice President', 'workouts:publish_org'),
  ('Vice President', 'workouts:manage_org'),

  ('President',      'workouts:publish_org'),
  ('President',      'workouts:manage_org')
) AS m(position_name, permission_name)
JOIN public.positions pos ON pos.name = m.position_name
JOIN public.permissions perm ON perm.name = m.permission_name
ON CONFLICT (position_id, permission_id) DO NOTHING;
