-- Sprint 1 DoD #5, #6, #11 — RBAC schema, temporal validity, access context.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(28);

-- Fixtures (as postgres) ------------------------------------------------------
-- President: seed user 00000000-0000-4000-8000-00000000a001
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('11111111-1111-4111-8111-111111111111', 'athlete@test.local', '{"full_name":"Test Athlete"}'),
  ('44444444-4444-4444-8444-444444444444', 'sysadmin@test.local', '{"full_name":"Test SysAdmin"}'),
  ('55555555-5555-4555-8555-555555555555', 'coach@test.local', '{"full_name":"Test Coach"}'),
  ('66666666-6666-4666-8666-666666666666', 'pending@test.local', '{"full_name":"Test Pending"}');

UPDATE public.profiles SET status = 'active'
WHERE id IN ('11111111-1111-4111-8111-111111111111', '44444444-4444-4444-8444-444444444444',
             '55555555-5555-4555-8555-555555555555');

INSERT INTO public.member_positions (profile_id, position_id)
SELECT '11111111-1111-4111-8111-111111111111', id FROM public.positions WHERE name = 'Athlete';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT '55555555-5555-4555-8555-555555555555', id FROM public.positions WHERE name IN ('Athlete', 'Coach');
INSERT INTO public.user_system_roles (user_id, role_id)
SELECT '44444444-4444-4444-8444-444444444444', id FROM public.system_roles WHERE name = 'System Administrator';

-- Schema ----------------------------------------------------------------------
SELECT is_empty(
  $$ SELECT c FROM unnest(ARRAY['id','profile_id','position_id','assigned_at','assigned_by','ended_at','ended_by','end_reason']) c
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = 'member_positions' AND column_name = c) $$,
  'member_positions has all temporal columns'
);
SELECT is_empty(
  $$ SELECT c FROM unnest(ARRAY['id','user_id','role_id','assigned_at','assigned_by','ended_at','ended_by','end_reason']) c
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = 'user_system_roles' AND column_name = c) $$,
  'user_system_roles has all temporal columns'
);
SELECT is(
  (SELECT array_agg(name ORDER BY rank) FROM public.positions),
  ARRAY['Athlete', 'Leader', 'Coach', 'Vice President', 'President'],
  'the five organizational positions are seeded in rank order'
);
SELECT throws_ok(
  $$ INSERT INTO public.member_positions (profile_id, position_id)
     SELECT '11111111-1111-4111-8111-111111111111', id FROM public.positions WHERE name = 'Athlete' $$,
  '23505', NULL,
  'a member cannot hold the same position twice concurrently'
);

-- President -------------------------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT ok(app_private.has_permission('members:approve'), 'President has members:approve');
-- Permission order follows the database collation and is not part of the
-- contract; compare it as a set (normalized to C-collation order).
SELECT is(
  (SELECT ctx || jsonb_build_object('permissions', COALESCE(
     (SELECT jsonb_agg(x ORDER BY x COLLATE "C") FROM jsonb_array_elements_text(ctx -> 'permissions') x), '[]'::jsonb))
   FROM (SELECT public.get_my_access_context() AS ctx) s),
  jsonb_build_object(
    'positions', jsonb_build_array('President'),
    'permissions', jsonb_build_array(
      'audit:view', 'coaches:assign', 'exercises:approve', 'members:approve',
      'members:assign_president', 'members:invite', 'members:preassign_position',
      'members:view_all', 'permissions:manage', 'positions:assign',
      'skills:verify', 'training:view_org', 'training:view_private_feedback',
      'workout:assign', 'workouts:manage_org', 'workouts:publish_org'),
    'is_system_admin', false
  ),
  'President access context has exact positions, permissions and is_system_admin'
);
RESET ROLE;

-- Athlete ---------------------------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT ok(NOT app_private.has_permission('members:approve'), 'Athlete lacks members:approve');
SELECT is(
  public.get_my_access_context(),
  '{"positions":["Athlete"],"permissions":[],"is_system_admin":false}'::jsonb,
  'Athlete access context: Athlete position, no permissions'
);
RESET ROLE;

-- System Administrator (system role, no club position) -------------------------
SELECT set_config('request.jwt.claims', '{"sub":"44444444-4444-4444-8444-444444444444","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT ctx || jsonb_build_object('permissions', COALESCE(
     (SELECT jsonb_agg(x ORDER BY x COLLATE "C") FROM jsonb_array_elements_text(ctx -> 'permissions') x), '[]'::jsonb))
   FROM (SELECT public.get_my_access_context() AS ctx) s),
  '{"positions":[],"permissions":["audit:view","system:configure","system_roles:assign","system_roles:view"],"is_system_admin":true}'::jsonb,
  'System Administrator context: no positions, system permissions, is_system_admin'
);
SELECT ok(NOT app_private.has_permission('members:approve'), 'system role does not imply club authority');
RESET ROLE;

-- Temporal validity: ending a position revokes its permissions -----------------
SELECT set_config('request.jwt.claims', '{"sub":"55555555-5555-4555-8555-555555555555","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.has_permission('skills:verify'), 'active Coach has skills:verify');
RESET ROLE;

UPDATE public.member_positions
SET ended_at = now(), end_reason = 'Stepped down'
WHERE profile_id = '55555555-5555-4555-8555-555555555555'
  AND position_id = (SELECT id FROM public.positions WHERE name = 'Coach');

SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.has_permission('skills:verify'), 'ended Coach position no longer grants skills:verify');
SELECT is(
  public.get_my_access_context() -> 'positions',
  '["Athlete"]'::jsonb,
  'ended position disappears from access context'
);
RESET ROLE;

-- Pending member & unauthenticated caller ------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"66666666-6666-4666-8666-666666666666","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  public.get_my_access_context(),
  '{"positions":[],"permissions":[],"is_system_admin":false}'::jsonb,
  'pending member has an empty access context'
);
RESET ROLE;

-- ADR-003 (Option A-revised): position permissions require an active profile;
-- system roles stay independent of club membership status --------------------
--   77… suspended VP · 88… suspended Coach + active System Administrator
--   99… pending System Administrator · aa… rejected Coach
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('77777777-7777-4777-8777-777777777777', 'suspended.vp@test.local', '{"full_name":"Suspended VP"}'),
  ('88888888-8888-4888-8888-888888888888', 'suspended.sysadmin@test.local', '{"full_name":"Suspended SysAdmin"}'),
  ('99999999-9999-4999-8999-999999999999', 'pending.sysadmin@test.local', '{"full_name":"Pending SysAdmin"}'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'rejected.coach@test.local', '{"full_name":"Rejected Coach"}');
UPDATE public.profiles SET status = 'suspended'
WHERE id IN ('77777777-7777-4777-8777-777777777777', '88888888-8888-4888-8888-888888888888');
UPDATE public.profiles SET status = 'rejected' WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id
FROM (VALUES
  ('77777777-7777-4777-8777-777777777777', 'Vice President'),
  ('88888888-8888-4888-8888-888888888888', 'Coach'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Coach')
) AS f(profile_id, position_name)
JOIN public.positions pos ON pos.name = f.position_name;
INSERT INTO public.user_system_roles (user_id, role_id)
SELECT u.id, sr.id
FROM (VALUES ('88888888-8888-4888-8888-888888888888'::uuid), ('99999999-9999-4999-8999-999999999999'::uuid)) AS u(id)
CROSS JOIN public.system_roles sr WHERE sr.name = 'System Administrator';

SELECT set_config('request.jwt.claims', '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.has_permission('members:approve'), 'suspended VP: active VP position no longer grants members:approve');
SELECT ok(NOT app_private.has_permission('audit:view'), 'suspended VP: no audit:view without an active system role');
SELECT is(
  public.get_my_access_context(),
  '{"positions":[],"permissions":[],"is_system_admin":false}'::jsonb,
  'suspended VP access context: no positions, no position-derived permissions'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"88888888-8888-4888-8888-888888888888","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.has_permission('system_roles:view'), 'suspended System Administrator keeps system_roles:view (system role)');
SELECT ok(app_private.has_permission('audit:view'), 'suspended System Administrator keeps audit:view (system role)');
SELECT ok(NOT app_private.has_permission('skills:verify'), 'suspended System Administrator loses Coach-position skills:verify');
SELECT ok(NOT app_private.has_permission('members:approve'), 'suspended System Administrator has no club governance authority');
SELECT is(
  (SELECT ctx || jsonb_build_object('permissions', COALESCE(
     (SELECT jsonb_agg(x ORDER BY x COLLATE "C") FROM jsonb_array_elements_text(ctx -> 'permissions') x), '[]'::jsonb))
   FROM (SELECT public.get_my_access_context() AS ctx) s),
  '{"positions":[],"permissions":["audit:view","system:configure","system_roles:assign","system_roles:view"],"is_system_admin":true}'::jsonb,
  'suspended System Administrator context: no positions, only system-role permissions, is_system_admin'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.has_permission('system:configure'), 'pending System Administrator keeps system:configure (system role)');
SELECT is(
  (public.get_my_access_context() -> 'is_system_admin'),
  'true'::jsonb,
  'pending System Administrator context still reports is_system_admin'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.has_permission('skills:verify'), 'rejected Coach: no position-derived permissions');
RESET ROLE;

-- Status is the gate, not the position row: reinstatement restores authority.
UPDATE public.profiles SET status = 'active' WHERE id = '77777777-7777-4777-8777-777777777777';
SELECT set_config('request.jwt.claims', '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.has_permission('members:approve'), 'reinstated (active) VP regains members:approve');
RESET ROLE;

SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE authenticated;
SELECT is(
  public.get_my_access_context(),
  '{"error":"Unauthenticated"}'::jsonb,
  'no JWT subject → Unauthenticated'
);
SELECT ok(NOT app_private.has_permission('members:view_all'), 'no JWT subject → has_permission is false');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
