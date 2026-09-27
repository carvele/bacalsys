-- Sprint 4 · Task 4.6 — workout execution: schema constraints, explicit grants,
-- the two-tier privacy predicates, sensitive-substitution conditional RLS,
-- audit redaction (F-S4-P13), and the idempotency ledger's own constraints.
-- RPC mutation flows, row-level locking and offline continuation are 012's job
-- (mirrors the 009/010 split from Sprint 3).
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(35);

-- Helpers (rolled back with the test) ------------------------------------------------
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END;
$fn$;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;
CREATE FUNCTION pg_temp.remember(p_k text, p_v uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  INSERT INTO pg_temp.ids VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = excluded.v;
  RETURN p_v;
END;
$fn$;
CREATE FUNCTION pg_temp.recall(p_k text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $fn$
  SELECT v FROM pg_temp.ids WHERE k = p_k;
$fn$;
-- Resolves a session_exercise id by the exercise CURRENTLY assigned to it
-- (works before and after a substitution, since it matches exercise_id, not
-- the original prescribed exercise).
CREATE FUNCTION pg_temp.se_for(p_session uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT se.id FROM public.session_exercises se JOIN public.exercises e ON e.id = se.exercise_id
  WHERE se.session_id = p_session AND e.slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.item_for(p_version uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.exercises e ON e.id = i.exercise_id
  WHERE b.workout_version_id = p_version AND e.slug = p_slug;
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.act(text), pg_temp.remember(text, uuid), pg_temp.recall(text),
  pg_temp.se_for(uuid, text), pg_temp.item_for(uuid, text) TO authenticated;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete (a1)          …02 Current Coach of a1 (c1)   …03 Former Coach of a1 (fc1, closed window)
--   …04 Leader (l1)           …05 Vice President (vp1)       …06 President (pres1)
--   …07 Leader in Org B (l_b1, cross-org isolation)          …08 System-Administrator-only member (Rule A)
INSERT INTO public.organizations (id, name, slug) VALUES ('a4000000-0000-4000-8000-0000000000f1', 'Club B', 'club-b-s4-test');
INSERT INTO public.branches (id, organization_id, name) VALUES ('a4000000-0000-4000-8000-0000000000f2', 'a4000000-0000-4000-8000-0000000000f1', 'Club B Branch');

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('a4000000-0000-4000-8000-000000000001', 'athlete@s4.test', '{"full_name":"Athlete"}'),
  ('a4000000-0000-4000-8000-000000000002', 'coach@s4.test', '{"full_name":"Current Coach"}'),
  ('a4000000-0000-4000-8000-000000000003', 'former@s4.test', '{"full_name":"Former Coach"}'),
  ('a4000000-0000-4000-8000-000000000004', 'leader@s4.test', '{"full_name":"Leader"}'),
  ('a4000000-0000-4000-8000-000000000005', 'vp@s4.test', '{"full_name":"VP"}'),
  ('a4000000-0000-4000-8000-000000000006', 'pres@s4.test', '{"full_name":"President"}'),
  ('a4000000-0000-4000-8000-000000000007', 'leader.b@s4.test', '{"full_name":"Leader B"}'),
  ('a4000000-0000-4000-8000-000000000008', 'sysadmin@s4.test', '{"full_name":"SysAdmin Only"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'a4000000-0000-4000-8000-0000000000%';
UPDATE public.profiles SET home_branch_id = 'a4000000-0000-4000-8000-0000000000f2' WHERE id = 'a4000000-0000-4000-8000-000000000007';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id
FROM (VALUES
  ('a4000000-0000-4000-8000-000000000001', 'Athlete'),
  ('a4000000-0000-4000-8000-000000000002', 'Coach'),
  ('a4000000-0000-4000-8000-000000000003', 'Coach'),
  ('a4000000-0000-4000-8000-000000000004', 'Leader'),
  ('a4000000-0000-4000-8000-000000000005', 'Vice President'),
  ('a4000000-0000-4000-8000-000000000006', 'President'),
  ('a4000000-0000-4000-8000-000000000007', 'Leader'),
  ('a4000000-0000-4000-8000-000000000008', 'Athlete')
) AS f(profile_id, position_name)
JOIN public.positions pos ON pos.name = f.position_name;

-- Rule A: System Administrator system role, held by …08 alone (no coaching/leadership position access).
INSERT INTO public.user_system_roles (user_id, role_id)
SELECT 'a4000000-0000-4000-8000-000000000008', id FROM public.system_roles WHERE name = 'System Administrator';

-- Coaching relationships: …02 is a1's CURRENT primary coach; …03 was a1's coach
-- in a CLOSED window 5..2 days ago (fixture sessions are backdated into it below).
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('a4000000-0000-4000-8000-000000000001', 'a4000000-0000-4000-8000-000000000002', 'a4000000-0000-4000-8000-000000000006');
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at) VALUES
  ('a4000000-0000-4000-8000-000000000001', 'a4000000-0000-4000-8000-000000000003', 'a4000000-0000-4000-8000-000000000006',
   now() - interval '5 days', now() - interval '2 days');

-- 1. Schema, grants, RLS enabled -----------------------------------------------------
SELECT ok(
  (SELECT count(*) = 6 AND bool_and(relrowsecurity) FROM pg_class
   WHERE oid IN ('public.workout_sessions'::regclass, 'public.session_exercises'::regclass,
                 'public.session_sets'::regclass, 'public.session_modifications'::regclass,
                 'public.session_feedback'::regclass, 'public.session_private_feedback'::regclass)),
  'RLS is enabled on all six execution tables'
);
SELECT ok(
  (SELECT bool_and(has_table_privilege('authenticated', t, 'SELECT')
                   AND NOT has_table_privilege('authenticated', t, 'INSERT')
                   AND NOT has_table_privilege('authenticated', t, 'UPDATE')
                   AND NOT has_table_privilege('authenticated', t, 'DELETE'))
   FROM unnest(ARRAY['public.workout_sessions', 'public.session_exercises', 'public.session_sets',
                     'public.session_modifications', 'public.session_feedback', 'public.session_private_feedback']) AS t),
  'authenticated holds SELECT only on every execution table (direct DML fails closed with 42501)'
);
SELECT ok(
  (SELECT bool_and(NOT has_table_privilege('anon', t, 'SELECT') AND NOT has_table_privilege('anon', t, 'INSERT'))
   FROM unnest(ARRAY['public.workout_sessions', 'public.session_exercises', 'public.session_sets',
                     'public.session_modifications', 'public.session_feedback', 'public.session_private_feedback']) AS t),
  'anon holds no privilege on any execution table'
);
SELECT pg_temp.act('a4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions (athlete_id, workout_version_id) VALUES (%L, gen_random_uuid()) $sql$,
    'a4000000-0000-4000-8000-000000000001')),
  '42501',
  'a direct authenticated INSERT into workout_sessions is rejected (no table grant)'
);
RESET ROLE;

-- 2. Constraints ----------------------------------------------------------------------
SELECT is(
  ARRAY[
    -- completed_at >= started_at
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions
      (athlete_id, workout_version_id, status, started_at, completed_at)
      VALUES (%L, gen_random_uuid(), 'completed', now(), now() - interval '1 minute') $sql$, 'a4000000-0000-4000-8000-000000000001')),
    -- status/completed_at consistency: in_progress with a completed_at set
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions
      (athlete_id, workout_version_id, status, completed_at) VALUES (%L, gen_random_uuid(), 'in_progress', now()) $sql$,
      'a4000000-0000-4000-8000-000000000001')),
    -- abandoned with no reason code
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions
      (athlete_id, workout_version_id, status, completed_at, abandonment_reason_code)
      VALUES (%L, gen_random_uuid(), 'abandoned', now(), NULL) $sql$, 'a4000000-0000-4000-8000-000000000001')),
    -- completed WITH a reason code
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions
      (athlete_id, workout_version_id, status, completed_at, abandonment_reason_code)
      VALUES (%L, gen_random_uuid(), 'completed', now(), 'time_constraint') $sql$, 'a4000000-0000-4000-8000-000000000001')),
    -- unknown abandonment_reason_code
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions
      (athlete_id, workout_version_id, status, completed_at, abandonment_reason_code)
      VALUES (%L, gen_random_uuid(), 'abandoned', now(), 'nonsense') $sql$, 'a4000000-0000-4000-8000-000000000001'))
  ],
  ARRAY['23514', '23514', '23514', '23514', '23514'],
  'workout_sessions: time interval, status/completed_at and bidirectional abandonment-reason consistency all fail closed'
);
SELECT is(
  ARRAY[
    -- has_discomfort true with no discomfort_area
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.session_private_feedback (session_id, has_discomfort, discomfort_area)
      VALUES (%L, true, NULL) $sql$, gen_random_uuid())),
    -- has_discomfort false WITH a discomfort_area
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.session_private_feedback (session_id, has_discomfort, discomfort_area)
      VALUES (%L, false, 'Knee') $sql$, gen_random_uuid()))
  ],
  ARRAY['23514', '23514'],
  'session_private_feedback: discomfort_fields_consistency fails closed both directions'
);
-- F-S4-01: the fixed load-consistency constraint actually rejects a nonzero
-- load with load_type NULL (the exact loophole F-S3-02 closed on the
-- prescription table; proves the mirror-fix on session_sets is real).
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ INSERT INTO public.session_sets (session_exercise_id, set_number, actual_load_kg, load_type)
          VALUES (%L, 1, 10.00, NULL) $sql$, gen_random_uuid())),
  '23514',
  'F-S4-01: a nonzero actual_load_kg with load_type NULL is rejected (mirrors the F-S3-02 fix, not the original loophole)'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ INSERT INTO public.session_sets (session_exercise_id, set_number, actual_load_kg, load_type)
          VALUES (%L, 1, 10.00, 'added') $sql$, gen_random_uuid())),
  '23503',
  'a correctly-typed load only trips the (unrelated) foreign key to a real session_exercise, not the load-consistency check'
);

-- 3. Idempotency ledger: caller-scoped independence and payload-hash integrity --------
SELECT lives_ok(
  format($sql$ INSERT INTO app_private.idempotency_keys (caller_id, mutation_type, key, payload_hash) VALUES
    (%L, 'START_SESSION', %L, 'hash-a'), (%L, 'START_SESSION', %L, 'hash-b') $sql$,
    'a4000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-00000000baaa',
    'a4000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-00000000baaa'),
  'two different athletes may each use the IDENTICAL idempotency key UUID without conflict (composite primary key is caller-scoped)'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ INSERT INTO app_private.idempotency_keys (caller_id, mutation_type, key, payload_hash) VALUES (%L, 'START_SESSION', %L, 'hash-c') $sql$,
    'a4000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-00000000baaa')),
  '23505',
  'the SAME caller reusing the same (mutation_type, key) hits the composite primary key'
);

-- 4. A full, realistic session: build it through the real RPCs -----------------------
-- Coach …02 authors an organization routine (push-up reps, pull-up added_weight).
SELECT pg_temp.act('a4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('tpl', (public.create_workout_template(
       'Session Fixture Routine', NULL, 'organization',
       jsonb_build_array(jsonb_build_object(
         'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
           jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
             'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 10))),
           jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'pull-up'),
             'measurement_mode', 'added_weight', 'sets', jsonb_build_array(
               jsonb_build_object('target_reps', 5, 'target_load_kg', 5, 'load_type', 'added')))
         )
       ))
     ) ->> 'template_id')::uuid) $$,
  'the Coach creates the fixture routine'
);
RESET ROLE;
SELECT pg_temp.remember('ver', id) FROM public.workout_versions WHERE template_id = pg_temp.recall('tpl');

-- Athlete …01 lives the whole Slice-1-shaped flow: start, a sensitive
-- substitution (pain_discomfort) and an operational one, two sets, then splits
-- feedback on completion.
SELECT pg_temp.act('a4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('s1', (public.start_workout_session(%L, gen_random_uuid()) ->> 'session_id')::uuid) $sql$,
         pg_temp.recall('ver')),
  'the athlete starts a session from the fixture routine'
);
SELECT lives_ok(
  format($sql$ SELECT public.record_exercise_substitution(%L, %L,
    (SELECT id FROM public.exercises WHERE slug = 'diamond-push-up'), 'reps', 'pain_discomfort', gen_random_uuid()) $sql$,
    pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'push-up')),
  'a SENSITIVE substitution (pain_discomfort) is recorded before any set'
);
SELECT lives_ok(
  format($sql$ SELECT public.record_exercise_substitution(%L, %L,
    (SELECT id FROM public.exercises WHERE slug = 'chin-up'), 'reps', 'equipment_unavailable', gen_random_uuid()) $sql$,
    pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'pull-up')),
  'an OPERATIONAL substitution (equipment_unavailable) is recorded before any set'
);
SELECT lives_ok(
  format($sql$ SELECT public.record_session_set(%L, %L, '{"set_number":1,"actual_reps":10,"is_completed":true}'::jsonb, gen_random_uuid()) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'diamond-push-up')),
  'a set is recorded against the substituted diamond push-up'
);
SELECT lives_ok(
  format($sql$ SELECT public.record_session_set(%L, %L, '{"set_number":1,"actual_reps":8,"is_completed":true}'::jsonb, gen_random_uuid()) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'chin-up')),
  'a set is recorded against the substituted chin-up'
);
SELECT lives_ok(
  format($sql$ SELECT public.complete_workout_session(%L, 'completed', NULL,
    '{"difficulty_rating":8,"energy_level":4}'::jsonb,
    '{"has_discomfort":true,"discomfort_area":"Left Shoulder","note_to_coach":"Felt pinching at the top"}'::jsonb,
    gen_random_uuid()) $sql$, pg_temp.recall('s1')),
  'the session completes with split ordinary + private feedback'
);
-- A second, plain abandonment: proves the (non-sensitive) abandonment reason
-- lives on the general session row, not gated behind private-feedback access.
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('s2', (public.start_workout_session(%L, gen_random_uuid()) ->> 'session_id')::uuid) $sql$,
         pg_temp.recall('ver')),
  'the athlete starts a second session'
);
SELECT lives_ok(
  format($sql$ SELECT public.complete_workout_session(%L, 'abandoned', 'general_fatigue', NULL, NULL, gen_random_uuid()) $sql$,
         pg_temp.recall('s2')),
  'the second session is abandoned with a plain, non-sensitive reason code'
);
RESET ROLE;

-- Backdate session 1 into the FORMER coach's closed tenure window (5..2 days
-- ago) so former-coach visibility can be tested without timing flakiness.
UPDATE public.workout_sessions
SET started_at = now() - interval '3 days', completed_at = now() - interval '3 days' + interval '20 minutes'
WHERE id = pg_temp.recall('s1');

-- 5. General visibility (can_view_workout_session) ------------------------------------
SELECT pg_temp.act('a4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2'))),
    (SELECT count(*) FROM public.session_feedback WHERE session_id = pg_temp.recall('s1')),
    (SELECT count(*) FROM public.session_sets ss JOIN public.session_exercises se ON se.id = ss.session_exercise_id WHERE se.session_id = pg_temp.recall('s1')),
    (SELECT count(*) FROM public.session_modifications WHERE session_id = pg_temp.recall('s1'))
  ],
  ARRAY[2::bigint, 1, 2, 2],
  'sanity: the athlete (owner) sees both sessions, 1 feedback row, 2 sets and both modifications on session 1'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT ARRAY[count(*) FILTER (WHERE id = pg_temp.recall('s1')), count(*) FILTER (WHERE id = pg_temp.recall('s2'))]
   FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2'))),
  ARRAY[1::bigint, 1],
  'the CURRENT primary coach sees both sessions (no time-window restriction)'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2'))),
  1::bigint,
  'the FORMER coach sees ONLY session 1 (backdated into their closed tenure window), never session 2'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000004');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2')))::text,
    (SELECT abandonment_reason_code FROM public.workout_sessions WHERE id = pg_temp.recall('s2')),
    (SELECT count(*) FROM public.session_modifications WHERE session_id = pg_temp.recall('s1'))::text
  ],
  ARRAY['2', 'general_fatigue', '1'],
  'the Leader (training:view_org) sees both sessions and the structured abandonment reason, but only the OPERATIONAL modification (1, not 2)'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000007');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2'))),
  0::bigint,
  'a Leader in a DIFFERENT organization (same training:view_org permission) sees 0 rows — null-safe cross-org isolation'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000008');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2'))),
    (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1'))
  ],
  ARRAY[0::bigint, 0],
  'Rule A: a member holding ONLY the System Administrator system role (no organizational position access) sees 0 rows of either'
);
RESET ROLE;

-- 6. Strict private-feedback predicate & sensitive-substitution conditional RLS ------
SELECT pg_temp.act('a4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1')),
  1::bigint,
  'the current primary coach sees the private discomfort feedback'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1')),
  0::bigint,
  'the FORMER coach — even one whose tenure covers this exact session — is STRICTLY excluded from private feedback'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000004');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1')),
  0::bigint,
  'the Leader (training:view_org only, no training:view_private_feedback) sees 0 rows of private feedback'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1')),
    (SELECT count(*) FROM public.session_modifications WHERE session_id = pg_temp.recall('s1'))
  ],
  ARRAY[1::bigint, 2],
  'the Vice President (training:view_private_feedback) sees the private feedback AND both modifications (sensitive + operational)'
);
RESET ROLE;

SELECT pg_temp.act('a4000000-0000-4000-8000-000000000006');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1')),
    (SELECT count(*) FROM public.session_modifications WHERE session_id = pg_temp.recall('s1'))
  ],
  ARRAY[1::bigint, 2],
  'the President (training:view_private_feedback) sees the same as the Vice President'
);
RESET ROLE;

-- Rule A clarification: granting …04 (Leader) the System Administrator role in
-- ADDITION to their position changes nothing — access still comes from the
-- position, and the system role adds no private-feedback visibility.
INSERT INTO public.user_system_roles (user_id, role_id)
SELECT 'a4000000-0000-4000-8000-000000000004', id FROM public.system_roles WHERE name = 'System Administrator';
SELECT pg_temp.act('a4000000-0000-4000-8000-000000000004');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_sessions WHERE id IN (pg_temp.recall('s1'), pg_temp.recall('s2'))),
    (SELECT count(*) FROM public.session_private_feedback WHERE session_id = pg_temp.recall('s1'))
  ],
  ARRAY[2::bigint, 0],
  'Rule A: a Leader who ALSO holds System Administrator keeps exactly their position-derived access — no more, no less'
);
RESET ROLE;

-- 7. Audit redaction (F-S4-P13): single path, uniform redaction ----------------------
SELECT is(
  (SELECT count(*) FROM public.audit_logs
   WHERE entity_type = 'session_private_feedback' AND entity_id = pg_temp.recall('s1')::text),
  1::bigint,
  'session_private_feedback: exactly ONE audit row exists (single-audit-path guarantee)'
);
SELECT is(
  (SELECT ARRAY[new_values ->> 'has_discomfort', new_values ->> 'discomfort_area', new_values ->> 'note_to_coach']
   FROM public.audit_logs WHERE entity_type = 'session_private_feedback' AND entity_id = pg_temp.recall('s1')::text),
  ARRAY['[REDACTED]', '[REDACTED]', '[REDACTED]'],
  'every sensitive field is uniformly redacted in the audit row'
);
SELECT is(
  (SELECT count(*) FROM public.audit_logs
   WHERE entity_type = 'session_modification'
     AND (new_values ->> 'session_id') = pg_temp.recall('s1')::text),
  2::bigint,
  'both substitutions on session 1 produced exactly one audit row EACH (no duplicates)'
);
SELECT is(
  (SELECT array_agg(DISTINCT new_values ->> 'reason_code')
   FROM public.audit_logs WHERE entity_type = 'session_modification' AND (new_values ->> 'session_id') = pg_temp.recall('s1')::text),
  ARRAY['[REDACTED]'],
  'F-S4-P13: reason_code is redacted UNIFORMLY for the sensitive AND the operational substitution — audit:view cannot tell them apart'
);

SELECT * FROM finish();
ROLLBACK;
