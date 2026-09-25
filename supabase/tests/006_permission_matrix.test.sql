-- Sprint 1 final acceptance: the seeded permission-to-position matrix is part of
-- the authorization model, not incidental seed data. This suite pins it.
--   1. Golden matrix: exact permission set per position and system role.
--      Changing the matrix means changing this file, a deliberate, reviewed act.
--   2. Boundary invariants that must hold regardless of future additions.
--   3. Drift guard: every permission named in a function or RLS policy exists.
-- Review notes and open decisions: docs/sprints/sprint-01-foundations/findings/permission-matrix-review.md
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(19);

-- Helper view: position → sorted permission array (C collation for stable order).
CREATE TEMP VIEW position_matrix AS
SELECT pos.name AS position,
       COALESCE(array_agg(perm.name ORDER BY perm.name COLLATE "C") FILTER (WHERE perm.name IS NOT NULL), '{}') AS perms
FROM public.positions pos
LEFT JOIN public.position_permissions pp ON pp.position_id = pos.id
LEFT JOIN public.permissions perm ON perm.id = pp.permission_id
GROUP BY pos.name;

CREATE TEMP VIEW system_role_matrix AS
SELECT sr.name AS role,
       COALESCE(array_agg(perm.name ORDER BY perm.name COLLATE "C") FILTER (WHERE perm.name IS NOT NULL), '{}') AS perms
FROM public.system_roles sr
LEFT JOIN public.system_role_permissions srp ON srp.role_id = sr.id
LEFT JOIN public.permissions perm ON perm.id = srp.permission_id
GROUP BY sr.name;

-- 1. Golden matrix ---------------------------------------------------------------
SELECT is(
  (SELECT perms FROM position_matrix WHERE position = 'Athlete'),
  '{}'::text[],
  'Athlete holds no permissions (own-record access comes from ownership predicates)'
);
SELECT is(
  (SELECT perms FROM position_matrix WHERE position = 'Leader'),
  ARRAY['members:view_all', 'training:view_org'],
  'Leader: member directory + organization-wide training visibility only'
);
SELECT is(
  (SELECT perms FROM position_matrix WHERE position = 'Coach'),
  ARRAY['members:view_all', 'skills:verify'],
  'Coach: member directory + skill verification (athlete scope comes from coach_assignments, Sprint 2)'
);
SELECT is(
  (SELECT perms FROM position_matrix WHERE position = 'Vice President'),
  ARRAY['audit:view', 'exercises:review', 'members:approve', 'members:invite', 'members:preassign_position',
        'members:view_all', 'positions:assign', 'skills:verify', 'training:view_org'],
  'Vice President: executive governance set'
);
SELECT is(
  (SELECT perms FROM position_matrix WHERE position = 'President'),
  ARRAY['audit:view', 'exercises:review', 'members:approve', 'members:invite', 'members:preassign_position',
        'members:view_all', 'positions:assign', 'skills:verify', 'training:view_org'],
  'President: executive governance set'
);
SELECT is(
  (SELECT perms FROM system_role_matrix WHERE role = 'System Administrator'),
  ARRAY['audit:view', 'system:configure', 'system_roles:assign', 'system_roles:view'],
  'System Administrator: technical permissions only'
);
SELECT is(
  (SELECT count(*) FROM public.positions),
  5::bigint,
  'no unexpected positions exist'
);
SELECT is(
  (SELECT count(*) FROM public.system_roles),
  1::bigint,
  'no unexpected system roles exist'
);

-- 2. Boundary invariants -----------------------------------------------------------
SELECT is_empty(
  $$ SELECT position FROM position_matrix
     WHERE perms && ARRAY['system:configure', 'system_roles:assign', 'system_roles:view'] $$,
  'no club position grants system-administration permissions (Rule A)'
);
SELECT is_empty(
  $$ SELECT role FROM system_role_matrix, unnest(perms) p
     WHERE p LIKE 'members:%' OR p LIKE 'positions:%' OR p LIKE 'training:%' OR p LIKE 'skills:%' OR p LIKE 'exercises:%' $$,
  'no system role grants club governance or training permissions (Rule A)'
);
SELECT is(
  (SELECT array_agg(position ORDER BY position) FROM position_matrix
   WHERE perms && ARRAY['members:approve', 'members:invite', 'members:preassign_position', 'positions:assign']),
  ARRAY['President', 'Vice President'],
  'membership governance (approve/invite/pre-assign/assign positions) is executive-only'
);
SELECT is(
  (SELECT array_agg(position ORDER BY position) FROM position_matrix WHERE 'audit:view' = ANY (perms)),
  ARRAY['President', 'Vice President'],
  'audit log visibility among club positions is executive-only'
);
SELECT is(
  (SELECT array_agg(position ORDER BY position) FROM position_matrix WHERE 'training:view_org' = ANY (perms)),
  ARRAY['Leader', 'President', 'Vice President'],
  'organization-wide training visibility: Leader, VP, President (Rule D)'
);
-- Forward guard for Rule E (session_private_feedback, Sprint 4): if a private-feedback
-- permission is ever introduced, only VP/President may hold it, never Leader.
SELECT is_empty(
  $$ SELECT position FROM position_matrix, unnest(perms) p
     WHERE p LIKE '%private_feedback%' AND position NOT IN ('Vice President', 'President') $$,
  'no position other than VP/President holds a private-feedback permission (Rule E)'
);

-- Behavioural check: the Leader cannot use governance RPCs even though they see org training.
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('77777777-7777-4777-8777-777777777777', 'leader@test.local', '{"full_name":"Leader"}'),
       ('11111111-1111-4111-8111-111111111111', 'applicant@test.local', '{"full_name":"Applicant"}');
UPDATE public.profiles SET status = 'active' WHERE id = '77777777-7777-4777-8777-777777777777';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT '77777777-7777-4777-8777-777777777777', id FROM public.positions WHERE name = 'Leader';

SELECT set_config('request.jwt.claims', '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.approve_member('11111111-1111-4111-8111-111111111111') $$,
  '42501', NULL,
  'Leader cannot approve members'
);
SELECT throws_ok(
  $$ SELECT public.create_invitation('someone@test.local') $$,
  '42501', NULL,
  'Leader cannot invite members'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.audit_logs $$,
  'Leader cannot read the audit log'
);
RESET ROLE;

-- 3. Drift guard ------------------------------------------------------------------
SELECT is_empty(
  $$ SELECT DISTINCT m[1]
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname IN ('public', 'app_private'),
          regexp_matches(p.prosrc, 'has_permission\(''([a-z_]+:[a-z_]+)''\)', 'g') AS m
     WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE name = m[1]) $$,
  'every permission named in a function body exists in the catalog'
);
SELECT is_empty(
  $$ SELECT DISTINCT m[1]
     FROM pg_policies pol,
          regexp_matches(COALESCE(pol.qual, '') || ' ' || COALESCE(pol.with_check, ''),
                         'has_permission\(''([a-z_]+:[a-z_]+)''', 'g') AS m
     WHERE pol.schemaname = 'public'
       AND NOT EXISTS (SELECT 1 FROM public.permissions WHERE name = m[1]) $$,
  'every permission named in an RLS policy exists in the catalog'
);

SELECT * FROM finish();
ROLLBACK;
