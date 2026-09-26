-- =============================================================================
-- sprint2_permission_matrix
-- Roadmap v1.2 · Sprint 2 · Task 2.2 (frozen decisions D1–D4, Section 9)
--
--   D1  workout:assign            Leader, Coach, Vice President, President
--   D3  coaches:assign            Vice President, President
--   D3  members:assign_president  President only
--   D3  permissions:manage        President only
--   D4  exercises:approve         Coach, Vice President, President
--
-- The permission catalog is reference data and must reach every environment,
-- so it lives here rather than in seed.sql (which hosted projects never run).
-- Position mappings are inserted by name: on an existing database (hosted dev)
-- they land now; on a fresh local database the positions do not exist yet and
-- seed.sql applies the same mappings. Both paths are idempotent.
--
-- D4 supersedes the Sprint 1 placeholder `exercises:review` (never referenced by
-- any function or policy). It is renamed in place, so the existing VP/President
-- grants carry over under the new name.
-- =============================================================================

SELECT set_config('bacalsys.actor_type', 'migration', true);

UPDATE public.permissions
SET name = 'exercises:approve',
    description = 'Approve or reject custom exercise submissions (D4).'
WHERE name = 'exercises:review';

INSERT INTO public.permissions (name, description) VALUES
  ('exercises:approve',        'Approve or reject custom exercise submissions (D4).'),
  ('coaches:assign',           'Assign and reassign an athlete''s primary coach (D3).'),
  ('workout:assign',           'Assign workouts to athletes within scope (D1).'),
  ('members:assign_president', 'Appoint or remove the President (D3, President-only governance).'),
  ('permissions:manage',       'Change the position-to-permission matrix (D3, President-only governance).')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.position_permissions (position_id, permission_id)
SELECT pos.id, perm.id
FROM (VALUES
  ('Leader',         'workout:assign'),

  ('Coach',          'workout:assign'),
  ('Coach',          'exercises:approve'),

  ('Vice President', 'workout:assign'),
  ('Vice President', 'coaches:assign'),
  ('Vice President', 'exercises:approve'),

  ('President',      'workout:assign'),
  ('President',      'coaches:assign'),
  ('President',      'exercises:approve'),
  ('President',      'members:assign_president'),
  ('President',      'permissions:manage')
) AS m(position_name, permission_name)
JOIN public.positions pos ON pos.name = m.position_name
JOIN public.permissions perm ON perm.name = m.permission_name
ON CONFLICT (position_id, permission_id) DO NOTHING;
