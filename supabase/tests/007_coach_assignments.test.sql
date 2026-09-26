-- Sprint 2 · Task 2.4 — coach assignments: schema invariants, permission matrix
-- for public.assign_primary_coach(), atomic reassignment, audit, the half-open
-- former-coach window, and fail-closed scope helpers (D1, D2, D3).
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(82);

-- Fixtures -------------------------------------------------------------------------
--   …01 VP · …02 President · …03 Coach X · …04 Coach Y · …05 Athlete A · …06 Athlete B
--   …07 Leader · …08 suspended VP · …09 active non-coach · …0a pending member
--   …0b suspended Coach · …0c athlete in another organization · …0e suspended President
INSERT INTO public.organizations (id, name, slug)
VALUES ('c2000000-0000-4000-8000-0000000000f1', 'Other Club', 'other-club-s2-test');
INSERT INTO public.branches (id, organization_id, name)
VALUES ('c2000000-0000-4000-8000-0000000000f2', 'c2000000-0000-4000-8000-0000000000f1', 'Other Branch');

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('c2000000-0000-4000-8000-000000000001', 'vp@s2.test', '{"full_name":"Vice President"}'),
  ('c2000000-0000-4000-8000-000000000002', 'pres@s2.test', '{"full_name":"President"}'),
  ('c2000000-0000-4000-8000-000000000003', 'coach.x@s2.test', '{"full_name":"Coach X"}'),
  ('c2000000-0000-4000-8000-000000000004', 'coach.y@s2.test', '{"full_name":"Coach Y"}'),
  ('c2000000-0000-4000-8000-000000000005', 'athlete.a@s2.test', '{"full_name":"Athlete A"}'),
  ('c2000000-0000-4000-8000-000000000006', 'athlete.b@s2.test', '{"full_name":"Athlete B"}'),
  ('c2000000-0000-4000-8000-000000000007', 'leader@s2.test', '{"full_name":"Leader"}'),
  ('c2000000-0000-4000-8000-000000000008', 'suspended.vp@s2.test', '{"full_name":"Suspended VP"}'),
  ('c2000000-0000-4000-8000-000000000009', 'plain@s2.test', '{"full_name":"Plain Athlete"}'),
  ('c2000000-0000-4000-8000-00000000000a', 'pending@s2.test', '{"full_name":"Pending"}'),
  ('c2000000-0000-4000-8000-00000000000b', 'suspended.coach@s2.test', '{"full_name":"Suspended Coach"}'),
  ('c2000000-0000-4000-8000-00000000000c', 'other.org@s2.test', '{"full_name":"Other Org Athlete"}'),
  ('c2000000-0000-4000-8000-00000000000e', 'suspended.pres@s2.test', '{"full_name":"Suspended President"}');

UPDATE public.profiles SET status = 'active'
WHERE id::text LIKE 'c2000000-0000-4000-8000-0000000000%' AND id <> 'c2000000-0000-4000-8000-00000000000a';
UPDATE public.profiles SET status = 'suspended'
WHERE id IN ('c2000000-0000-4000-8000-000000000008', 'c2000000-0000-4000-8000-00000000000b',
             'c2000000-0000-4000-8000-00000000000e');
UPDATE public.profiles SET home_branch_id = 'c2000000-0000-4000-8000-0000000000f2'
WHERE id = 'c2000000-0000-4000-8000-00000000000c';

INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id
FROM (VALUES
  ('c2000000-0000-4000-8000-000000000001', 'Vice President'),
  ('c2000000-0000-4000-8000-000000000002', 'President'),
  ('c2000000-0000-4000-8000-000000000003', 'Coach'),
  ('c2000000-0000-4000-8000-000000000004', 'Coach'),
  ('c2000000-0000-4000-8000-000000000005', 'Athlete'),
  ('c2000000-0000-4000-8000-000000000006', 'Athlete'),
  ('c2000000-0000-4000-8000-000000000007', 'Leader'),
  ('c2000000-0000-4000-8000-000000000008', 'Vice President'),
  ('c2000000-0000-4000-8000-000000000009', 'Athlete'),
  ('c2000000-0000-4000-8000-00000000000b', 'Coach'),
  ('c2000000-0000-4000-8000-00000000000c', 'Athlete'),
  ('c2000000-0000-4000-8000-00000000000e', 'President')
) AS f(profile_id, position_name)
JOIN public.positions pos ON pos.name = f.position_name;

-- 1. Schema & privileges -----------------------------------------------------------
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.coach_assignments'::regclass),
  'RLS is enabled on coach_assignments'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.coach_assignments', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.coach_assignments', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.coach_assignments', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'public.coach_assignments', 'TRUNCATE'),
  'authenticated has no direct INSERT/UPDATE/DELETE/TRUNCATE on coach_assignments'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.coach_assignments', 'SELECT'),
  'anon cannot read coach_assignments'
);
SELECT is(
  (SELECT count(*) FROM pg_constraint
   WHERE conrelid = 'public.coach_assignments'::regclass AND contype = 'f'
     AND confrelid = 'public.profiles'::regclass AND confdeltype = 'r'),
  4::bigint,
  'athlete_id, coach_id, assigned_by, ended_by all reference profiles ON DELETE RESTRICT'
);
SELECT ok(
  (SELECT i.indisunique AND pg_get_expr(i.indpred, i.indrelid) LIKE '%ended_at IS NULL%'
   FROM pg_index i WHERE i.indexrelid = 'public.one_active_primary_coach_per_athlete'::regclass),
  'one_active_primary_coach_per_athlete is a partial unique index WHERE ended_at IS NULL'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.assign_primary_coach(uuid, uuid, text)', 'EXECUTE'),
  'public wrapper is callable by authenticated'
);
SELECT ok(
  NOT has_function_privilege('anon', 'public.assign_primary_coach(uuid, uuid, text)', 'EXECUTE'),
  'public wrapper is not callable by anon'
);
SELECT ok(
  NOT has_schema_privilege('anon', 'app_private', 'USAGE')
  AND NOT has_function_privilege('anon', 'app_private.assign_primary_coach_internal(uuid, uuid, text)', 'EXECUTE'),
  'private implementation is unreachable for anon (no schema usage, no execute)'
);

SET LOCAL ROLE anon;
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'anon calling assign_primary_coach is rejected'
);
RESET ROLE;

-- 2. Who may assign (D3: coaches:assign = VP, President) ---------------------------
SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'Athlete cannot assign a primary coach'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'Coach cannot assign primary coaches, not even to themselves (Feature 2.2 superseded)'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'Leader cannot assign primary coaches'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'suspended Vice President cannot call assign_primary_coach (fails closed)'
);
SELECT throws_ok(
  $$ SELECT app_private.assign_primary_coach_internal('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003', NULL) $$,
  '42501', NULL,
  'suspended Vice President is also rejected by the internal implementation (defence in depth)'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-00000000000e","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'suspended President cannot call assign_primary_coach (fails closed)'
);
RESET ROLE;

-- 3. VP assigns Athlete A → Coach X ----------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT set_config('test.ax', public.assign_primary_coach(
       'c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003', 'Initial assignment')::text, true) $$,
  'VP assigns Athlete A to Coach X'
);
SELECT is(
  (SELECT count(*) FROM public.coach_assignments
   WHERE athlete_id = 'c2000000-0000-4000-8000-000000000005' AND ended_at IS NULL),
  1::bigint,
  'exactly one active coach row exists for Athlete A'
);
SELECT ok(
  (SELECT coach_id = 'c2000000-0000-4000-8000-000000000003' AND assigned_by = 'c2000000-0000-4000-8000-000000000001'
          AND notes = 'Initial assignment'
   FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid),
  'the active row names Coach X, assigned_by = VP, with notes'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003') $$,
  '55000', 'Athlete is already actively assigned to this coach',
  'same-coach reassignment is rejected as a no-op'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000003') $$,
  '22023', NULL,
  'self-coaching is rejected'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-000000000009') $$,
  '22023', NULL,
  'a member without an active Coach position cannot become a primary coach'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-00000000000a', 'c2000000-0000-4000-8000-000000000003') $$,
  '55000', NULL,
  'a pending (inactive) athlete cannot be assigned'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-00000000000b') $$,
  '55000', NULL,
  'a suspended coach cannot be assigned'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-0000000000ff', 'c2000000-0000-4000-8000-000000000003') $$,
  'P0002', NULL,
  'an unknown athlete is rejected'
);
SELECT throws_ok(
  $$ SELECT public.assign_primary_coach('c2000000-0000-4000-8000-00000000000c', 'c2000000-0000-4000-8000-000000000003') $$,
  '42501', NULL,
  'an athlete from another organization cannot be assigned'
);
SELECT throws_ok(
  $$ INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by)
     VALUES ('c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000001') $$,
  '42501', NULL,
  'even a VP cannot INSERT into coach_assignments directly'
);
SELECT throws_ok(
  $$ UPDATE public.coach_assignments SET ended_at = now() WHERE athlete_id = 'c2000000-0000-4000-8000-000000000005' $$,
  '42501', NULL,
  'even a VP cannot UPDATE coach_assignments directly'
);
SELECT throws_ok(
  $$ DELETE FROM public.coach_assignments WHERE athlete_id = 'c2000000-0000-4000-8000-000000000005' $$,
  '42501', NULL,
  'even a VP cannot DELETE coaching history'
);
RESET ROLE;

-- Give the X assignment a real duration so the half-open window is non-empty
-- (inside one test transaction CURRENT_TIMESTAMP never advances).
SELECT set_config('request.jwt.claims', '', true);
UPDATE public.coach_assignments SET started_at = now() - interval '30 days'
WHERE id = current_setting('test.ax')::uuid;

-- 4. Scope while X is the current coach ------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.current_coach_can_view('c2000000-0000-4000-8000-000000000005'), 'current_coach_can_view(Athlete A) = true for Coach X');
SELECT ok(NOT app_private.current_coach_can_view('c2000000-0000-4000-8000-000000000006'), 'current_coach_can_view(Athlete B) = false for Coach X');
SELECT is(
  (SELECT array_agg(athlete_id) FROM public.coach_assignments
   WHERE coach_id = 'c2000000-0000-4000-8000-000000000003' AND ended_at IS NULL),
  ARRAY['c2000000-0000-4000-8000-000000000005'::uuid],
  'Coach X "My Athletes": Athlete A returned (1 row)'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.coach_assignments WHERE athlete_id = 'c2000000-0000-4000-8000-000000000006' $$,
  'Coach X "My Athletes": Athlete B absent (0 rows)'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.coach_assignments WHERE athlete_id = 'c2000000-0000-4000-8000-000000000005'),
  1::bigint,
  'Athlete A can read their own coach assignment'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty($$ SELECT 1 FROM public.coach_assignments $$, 'Athlete B cannot see anyone else''s coach assignment');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty($$ SELECT 1 FROM public.coach_assignments $$, 'Coach Y sees no assignments before being assigned');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty($$ SELECT 1 FROM public.coach_assignments $$, 'Leader cannot read coach assignments (no coaches:assign)');
RESET ROLE;

-- 5. President reassigns Athlete A → Coach Y ----------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT set_config('test.ay', public.assign_primary_coach(
       'c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000004')::text, true) $$,
  'President reassigns Athlete A to Coach Y via public.assign_primary_coach()'
);
SELECT is(
  (SELECT count(*) FROM public.coach_assignments WHERE athlete_id = 'c2000000-0000-4000-8000-000000000005'),
  2::bigint,
  'historical Coach X row is preserved (2 rows for Athlete A)'
);
SELECT is(
  (SELECT array_agg(coach_id) FROM public.coach_assignments
   WHERE athlete_id = 'c2000000-0000-4000-8000-000000000005' AND ended_at IS NULL),
  ARRAY['c2000000-0000-4000-8000-000000000004'::uuid],
  'Coach Y is the sole active coach'
);
SELECT ok(
  (SELECT ended_at = CURRENT_TIMESTAMP AND ended_by = 'c2000000-0000-4000-8000-000000000002'
   FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid),
  'prior Coach X assignment closed with ended_at = CURRENT_TIMESTAMP and ended_by = President'
);
SELECT ok(
  (SELECT y.started_at = x.ended_at
   FROM public.coach_assignments x, public.coach_assignments y
   WHERE x.id = current_setting('test.ax')::uuid AND y.id = current_setting('test.ay')::uuid),
  'handover is continuous: Y starts exactly when X ends'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.current_coach_can_view('c2000000-0000-4000-8000-000000000005'), 'current_coach_can_view(Athlete A) = false for former Coach X');
SELECT is_empty(
  $$ SELECT 1 FROM public.coach_assignments
     WHERE coach_id = 'c2000000-0000-4000-8000-000000000003' AND ended_at IS NULL $$,
  'former Coach X "My Athletes" is empty'
);

-- 6. Half-open boundary [started_at, ended_at) for former Coach X -----------------
SELECT ok(
  app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005',
    (SELECT started_at FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid)),
  'former_coach_can_view(A, started_at) = true'
);
SELECT ok(
  app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005',
    (SELECT ended_at - interval '1 second' FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid)),
  'former_coach_can_view(A, ended_at - 1 second) = true'
);
SELECT ok(
  NOT app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005',
    (SELECT ended_at FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid)),
  'former_coach_can_view(A, ended_at) = false (half-open upper bound)'
);
SELECT ok(
  NOT app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005',
    (SELECT ended_at + interval '1 hour' FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid)),
  'former_coach_can_view(A, ended_at + 1 hour) = false'
);
SELECT ok(
  NOT app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005',
    (SELECT started_at - interval '1 second' FROM public.coach_assignments WHERE id = current_setting('test.ax')::uuid)),
  'former_coach_can_view(A, started_at - 1 second) = false (before the window)'
);
SELECT ok(
  app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005', NULL) IS FALSE,
  'former_coach_can_view(A, NULL) = false'
);
SELECT ok(
  NOT app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000006', now() - interval '1 day'),
  'former_coach_can_view(B, …) = false: X never coached B'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.current_coach_can_view('c2000000-0000-4000-8000-000000000005'), 'current_coach_can_view(Athlete A) = true for Coach Y');
SELECT ok(
  NOT app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005', now() - interval '10 days'),
  'Coach Y gains no former-coach window over X''s period'
);
RESET ROLE;

-- 7. Audit trail -------------------------------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_logs
          WHERE action = 'coach_assignments.insert' AND entity_id = current_setting('test.ax')
            AND actor_type = 'user' AND actor_user_id = 'c2000000-0000-4000-8000-000000000001'),
  'audit: initial assignment recorded with the VP as actor'
);
SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_logs
          WHERE action = 'coach_assignments.update' AND entity_id = current_setting('test.ax')
            AND actor_type = 'user' AND actor_user_id = 'c2000000-0000-4000-8000-000000000002'
            AND old_values ->> 'ended_at' IS NULL
            AND new_values ->> 'ended_at' IS NOT NULL
            AND new_values ->> 'ended_by' = 'c2000000-0000-4000-8000-000000000002'),
  'audit: reassignment closes the Coach X row, recorded with the President as actor'
);
SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_logs
          WHERE action = 'coach_assignments.insert' AND entity_id = current_setting('test.ay')
            AND actor_user_id = 'c2000000-0000-4000-8000-000000000002'
            AND new_values ->> 'coach_id' = 'c2000000-0000-4000-8000-000000000004'),
  'audit: new Coach Y assignment recorded'
);

-- 8. History cannot be cascade-deleted; invariants hold at the table level ----------
-- A RESTRICT violation is SQLSTATE 23503 up to PostgreSQL 17 (hosted) and 23001 from
-- PostgreSQL 18 (offline PGlite harness); accept either (finding F-S2-01).
CREATE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END;
$fn$;
SELECT ok(
  pg_temp.sqlstate_of($$ DELETE FROM auth.users WHERE id = 'c2000000-0000-4000-8000-000000000005' $$) IN ('23001', '23503'),
  'deleting the athlete''s account is blocked by ON DELETE RESTRICT (history preserved)'
);
SELECT ok(
  pg_temp.sqlstate_of($$ DELETE FROM public.profiles WHERE id = 'c2000000-0000-4000-8000-000000000003' $$) IN ('23001', '23503'),
  'deleting a former coach''s profile is blocked by ON DELETE RESTRICT'
);
SELECT throws_ok(
  $$ INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by)
     VALUES ('c2000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000001') $$,
  '23505', NULL,
  'a second active coach for the same athlete violates one_active_primary_coach_per_athlete'
);
SELECT throws_ok(
  $$ INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by)
     VALUES ('c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-000000000001') $$,
  '23514', NULL,
  'coach_not_self CHECK rejects self-coaching at the table level'
);
SELECT throws_ok(
  $$ INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at)
     VALUES ('c2000000-0000-4000-8000-000000000006', 'c2000000-0000-4000-8000-000000000003',
             'c2000000-0000-4000-8000-000000000001', now(), now() - interval '1 day') $$,
  '23514', NULL,
  'valid_assignment_window CHECK rejects ended_at < started_at'
);

-- 9. Helpers fail closed for inactive callers -------------------------------------
UPDATE public.profiles SET status = 'suspended'
WHERE id IN ('c2000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000004');

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.current_coach_can_view('c2000000-0000-4000-8000-000000000005'), 'suspended current Coach Y: current_coach_can_view = false');
SELECT is_empty($$ SELECT 1 FROM public.coach_assignments $$, 'suspended Coach Y cannot read any coach assignment');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(
  NOT app_private.former_coach_can_view('c2000000-0000-4000-8000-000000000005', now() - interval '10 days'),
  'suspended former Coach X: former_coach_can_view = false inside the window'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '', true);
UPDATE public.profiles SET status = 'active'
WHERE id IN ('c2000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000004');

-- 10. can_assign_training_to (D1) --------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000005'), 'Coach Y may assign training to current athlete A');
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000006'), 'Coach Y may not assign training to unassigned athlete B');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000005'), 'former Coach X may no longer assign training to A');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000005'), 'Leader may assign training organization-wide (A)');
SELECT ok(app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000006'), 'Leader may assign training organization-wide (B)');
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-00000000000c'), 'Leader may not assign training to another organization''s athlete');
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-00000000000a'), 'nobody may assign training to a pending (inactive) member');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000006'), 'VP may assign training organization-wide');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000006'), 'President may assign training organization-wide');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000006'), 'Athlete may not assign training to others');
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000005'), 'Athlete holds no workout:assign, not even for themselves');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.can_assign_training_to('c2000000-0000-4000-8000-000000000006'), 'suspended VP may not assign training (fails closed)');
RESET ROLE;

-- 11. ADR-003: position permissions require an active profile ----------------------
SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  public.get_my_access_context(),
  '{"positions":[],"permissions":[],"is_system_admin":false}'::jsonb,
  'suspended Coach: access context has no positions or position-derived permissions'
);
SELECT ok(NOT app_private.has_permission('exercises:approve'), 'suspended Coach: has_permission(exercises:approve) = false');
SELECT is((SELECT count(*) FROM public.profiles), 1::bigint, 'suspended Coach loses the organization member directory (self only)');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT app_private.has_permission('coaches:assign'), 'suspended VP: has_permission(coaches:assign) = false');
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(app_private.has_permission('exercises:approve'), 'active Coach X keeps exercises:approve');
SELECT ok((SELECT count(*) FROM public.profiles) > 1, 'active Coach X keeps the organization member directory');
RESET ROLE;

SELECT ok(
  NOT has_function_privilege('anon', 'app_private.can_assign_training_to(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'app_private.current_coach_can_view(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'app_private.former_coach_can_view(uuid, timestamptz)', 'EXECUTE'),
  'scope helpers are not executable by anon'
);

SELECT * FROM finish();
ROLLBACK;
