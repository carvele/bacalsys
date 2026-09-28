-- Sprint 5 · Task 5.7 — assignment schema, constraints, the occurrence lifecycle
-- trigger (terminal immutability, direct missed→terminal rejection, lineage,
-- Rule C version rule, cancellation delete boundary), grants, the exact scoped
-- idempotency mutation types, the target-safe / temporal / organization-bounded
-- RLS matrix, version viewability, RPC signature inventory and function security
-- attributes. RPC behaviour, scheduling and Rule C flows are 014's job; offline
-- reconciliation is 015's (mirrors the 011/012 split from Sprint 4).
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(53);

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
-- Org-local (Asia/Manila) calendar date, offset by p_days.
CREATE FUNCTION pg_temp.day(p_days integer) RETURNS date LANGUAGE sql AS $fn$
  SELECT ((now() AT TIME ZONE 'Asia/Manila')::date + p_days);
$fn$;
-- Inserts one occurrence with correctly derived local-midnight timestamps
-- (run as the owner; direct DML is how fixtures bypass the RPCs).
CREATE FUNCTION pg_temp.mk_occ(p_key text, p_assignment uuid, p_athlete uuid, p_offset integer, p_status text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
  v_date date := pg_temp.day(p_offset);
  v_id uuid;
BEGIN
  INSERT INTO public.assignment_occurrences
    (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status, completed_at)
  VALUES (p_assignment, p_athlete, pg_temp.recall('ver'), v_date,
          v_date::timestamp AT TIME ZONE 'Asia/Manila', (v_date + 1)::timestamp AT TIME ZONE 'Asia/Manila', p_status,
          CASE WHEN p_status IN ('completed', 'partially_completed', 'abandoned') THEN now() END)
  RETURNING id INTO v_id;
  PERFORM pg_temp.remember(p_key, v_id);
  RETURN v_id;
END;
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.act(text), pg_temp.remember(text, uuid), pg_temp.recall(text),
  pg_temp.day(integer), pg_temp.mk_occ(text, uuid, uuid, integer, text) TO authenticated;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete A1 (coach C1)     …02 Athlete A2 (coach C2)     …03 Coach C1     …04 Coach C2
--   …05 Former coach of A1 (closed window 10..3 days ago)       …06 Leader (org A)   …07 Vice President (org A)
--   …08 Leader in Org B           …09 Leader with NO organization (home_branch_id NULL)
--   …0a System-Administrator-only (Rule A)                      …0b Leader (org A) who authors assignment X
--   …0c Athlete in Org B
INSERT INTO public.organizations (id, name, slug) VALUES ('a5000000-0000-4000-8000-0000000000f1', 'Club B', 'club-b-s5-test');
INSERT INTO public.branches (id, organization_id, name) VALUES ('a5000000-0000-4000-8000-0000000000f2', 'a5000000-0000-4000-8000-0000000000f1', 'Club B Branch');

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('a5000000-0000-4000-8000-000000000001', 'a1@s5.test', '{"full_name":"Athlete One"}'),
  ('a5000000-0000-4000-8000-000000000002', 'a2@s5.test', '{"full_name":"Athlete Two"}'),
  ('a5000000-0000-4000-8000-000000000003', 'c1@s5.test', '{"full_name":"Coach One"}'),
  ('a5000000-0000-4000-8000-000000000004', 'c2@s5.test', '{"full_name":"Coach Two"}'),
  ('a5000000-0000-4000-8000-000000000005', 'fc@s5.test', '{"full_name":"Former Coach"}'),
  ('a5000000-0000-4000-8000-000000000006', 'la@s5.test', '{"full_name":"Leader A"}'),
  ('a5000000-0000-4000-8000-000000000007', 'vp@s5.test', '{"full_name":"VP"}'),
  ('a5000000-0000-4000-8000-000000000008', 'lb@s5.test', '{"full_name":"Leader B"}'),
  ('a5000000-0000-4000-8000-000000000009', 'ln@s5.test', '{"full_name":"Leader No Org"}'),
  ('a5000000-0000-4000-8000-00000000000a', 'sys@s5.test', '{"full_name":"SysAdmin Only"}'),
  ('a5000000-0000-4000-8000-00000000000b', 'creator@s5.test', '{"full_name":"Assignment Creator"}'),
  ('a5000000-0000-4000-8000-00000000000c', 'xb@s5.test', '{"full_name":"Athlete Org B"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'a5000000-0000-4000-8000-0000000000%';
UPDATE public.profiles SET home_branch_id = 'a5000000-0000-4000-8000-0000000000f2'
  WHERE id IN ('a5000000-0000-4000-8000-000000000008', 'a5000000-0000-4000-8000-00000000000c');
UPDATE public.profiles SET home_branch_id = NULL WHERE id = 'a5000000-0000-4000-8000-000000000009';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id FROM (VALUES
  ('a5000000-0000-4000-8000-000000000001', 'Athlete'),
  ('a5000000-0000-4000-8000-000000000002', 'Athlete'),
  ('a5000000-0000-4000-8000-000000000003', 'Coach'),
  ('a5000000-0000-4000-8000-000000000004', 'Coach'),
  ('a5000000-0000-4000-8000-000000000005', 'Coach'),
  ('a5000000-0000-4000-8000-000000000006', 'Leader'),
  ('a5000000-0000-4000-8000-000000000007', 'Vice President'),
  ('a5000000-0000-4000-8000-000000000008', 'Leader'),
  ('a5000000-0000-4000-8000-000000000009', 'Leader'),
  ('a5000000-0000-4000-8000-00000000000a', 'Athlete'),
  ('a5000000-0000-4000-8000-00000000000b', 'Leader'),
  ('a5000000-0000-4000-8000-00000000000c', 'Athlete')
) AS f(profile_id, position_name) JOIN public.positions pos ON pos.name = f.position_name;
INSERT INTO public.user_system_roles (user_id, role_id)
SELECT 'a5000000-0000-4000-8000-00000000000a', id FROM public.system_roles WHERE name = 'System Administrator';

INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('a5000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000003', 'a5000000-0000-4000-8000-000000000007'),
  ('a5000000-0000-4000-8000-000000000002', 'a5000000-0000-4000-8000-000000000004', 'a5000000-0000-4000-8000-000000000007');
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at) VALUES
  ('a5000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000005', 'a5000000-0000-4000-8000-000000000007',
   now() - interval '10 days', now() - interval '3 days');

-- Coach C1 authors the organization routine every fixture assignment points at.
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('tpl', (public.create_workout_template(
  'Assignment Fixture Routine', NULL, 'organization',
  jsonb_build_array(jsonb_build_object(
    'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
        'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 10))))))
) ->> 'template_id')::uuid);
RESET ROLE;
SELECT pg_temp.remember('ver', id) FROM public.workout_versions WHERE template_id = pg_temp.recall('tpl');

-- Assignment X: recurring, authored by …0b, targets A1 + A2, with its schedule.
-- Assignment Y: single-date, authored by C2 (who does NOT coach A1), target A1.
-- Assignment Z: the lifecycle-trigger playground (owner-level DML only).
INSERT INTO public.workout_assignments (id, organization_id, workout_template_id, workout_version_id, assigned_by, is_recurring, target_date) VALUES
  ('a5000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-000000000001', pg_temp.recall('tpl'), pg_temp.recall('ver'),
   'a5000000-0000-4000-8000-00000000000b', true, NULL),
  ('a5000000-0000-4000-8000-0000000000e2', '00000000-0000-4000-8000-000000000001', pg_temp.recall('tpl'), pg_temp.recall('ver'),
   'a5000000-0000-4000-8000-000000000004', false, pg_temp.day(1)),
  ('a5000000-0000-4000-8000-0000000000e3', '00000000-0000-4000-8000-000000000001', pg_temp.recall('tpl'), pg_temp.recall('ver'),
   'a5000000-0000-4000-8000-00000000000b', false, pg_temp.day(1));
INSERT INTO public.assignment_targets (assignment_id, athlete_id) VALUES
  ('a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000001'),
  ('a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000002'),
  ('a5000000-0000-4000-8000-0000000000e2', 'a5000000-0000-4000-8000-000000000001'),
  ('a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001');
INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date, timezone) VALUES
  ('a5000000-0000-4000-8000-0000000000e1', ARRAY[1, 3, 5]::smallint[], pg_temp.day(-10), 'Asia/Manila');
SELECT pg_temp.mk_occ('r1', 'a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000001', -5, 'missed');
SELECT pg_temp.mk_occ('r2', 'a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000001', 2, 'upcoming');
SELECT pg_temp.mk_occ('r3', 'a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000002', 2, 'upcoming');
SELECT pg_temp.mk_occ('y1', 'a5000000-0000-4000-8000-0000000000e2', 'a5000000-0000-4000-8000-000000000001', 1, 'upcoming');

-- 1. Grants, RLS enabled ------------------------------------------------------------
SELECT ok(
  (SELECT count(*) = 4 AND bool_and(relrowsecurity) FROM pg_class
   WHERE oid IN ('public.workout_assignments'::regclass, 'public.assignment_targets'::regclass,
                 'public.recurring_schedules'::regclass, 'public.assignment_occurrences'::regclass)),
  'RLS is enabled on all four assignment tables'
);
SELECT ok(
  (SELECT bool_and(has_table_privilege('authenticated', t, 'SELECT')
                   AND NOT has_table_privilege('authenticated', t, 'INSERT')
                   AND NOT has_table_privilege('authenticated', t, 'UPDATE')
                   AND NOT has_table_privilege('authenticated', t, 'DELETE')
                   AND NOT has_table_privilege('anon', t, 'SELECT')
                   AND NOT has_table_privilege('anon', t, 'INSERT'))
   FROM unnest(ARRAY['public.workout_assignments', 'public.assignment_targets',
                     'public.recurring_schedules', 'public.assignment_occurrences']) AS t),
  'authenticated holds SELECT only and anon holds nothing on every assignment table (direct DML fails closed)'
);
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_assignments (organization_id, workout_template_id, workout_version_id, assigned_by, target_date)
      VALUES ('00000000-0000-4000-8000-000000000001', %L, %L, %L, current_date) $sql$,
      pg_temp.recall('tpl'), pg_temp.recall('ver'), 'a5000000-0000-4000-8000-000000000003')),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = %L $sql$, pg_temp.recall('r2'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('r2'))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_targets (assignment_id, athlete_id) VALUES (%L, %L) $sql$,
      'a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000003')),
    pg_temp.sqlstate_of($sql$ UPDATE public.recurring_schedules SET is_active = false $sql$)
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'direct authenticated INSERT / UPDATE / DELETE on the assignment tables are rejected (no table grant)'
);
RESET ROLE;

-- 2. Idempotency mutation types: exactly the 5 accepted + 3 scoped values (F-S5-P11) ----
SELECT is(
  ARRAY(
    SELECT pg_temp.sqlstate_of(format(
      $sql$ INSERT INTO app_private.idempotency_keys (caller_id, mutation_type, key, payload_hash) VALUES (%L, %L, gen_random_uuid(), 'h') $sql$,
      'a5000000-0000-4000-8000-000000000003', t))
    FROM unnest(ARRAY['START_SESSION', 'RECORD_SET', 'SUBSTITUTE_EXERCISE', 'COMPLETE_SESSION', 'SYNC_BUNDLE',
                      'CREATE_ASSIGNMENT', 'CANCEL_ASSIGNMENT', 'MIGRATE_ASSIGNMENT_VERSION', 'GENERATE_OCCURRENCES', 'create_assignment'])
         WITH ORDINALITY AS u(t, n)
    ORDER BY n
  ),
  ARRAY['ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', '23514', '23514'],
  'the idempotency ledger accepts exactly the 5 Sprint 4 types plus CREATE_ASSIGNMENT / CANCEL_ASSIGNMENT / MIGRATE_ASSIGNMENT_VERSION — nothing else'
);

-- 3. Table constraints -------------------------------------------------------------
SELECT is(
  ARRAY[
    -- recurring assignment WITH a target_date
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_assignments (organization_id, workout_template_id, workout_version_id, assigned_by, is_recurring, target_date)
      VALUES ('00000000-0000-4000-8000-000000000001', %L, %L, %L, true, current_date) $sql$,
      pg_temp.recall('tpl'), pg_temp.recall('ver'), 'a5000000-0000-4000-8000-000000000003')),
    -- single-date assignment WITHOUT a target_date
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_assignments (organization_id, workout_template_id, workout_version_id, assigned_by, is_recurring, target_date)
      VALUES ('00000000-0000-4000-8000-000000000001', %L, %L, %L, false, NULL) $sql$,
      pg_temp.recall('tpl'), pg_temp.recall('ver'), 'a5000000-0000-4000-8000-000000000003')),
    -- blank notes
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_assignments (organization_id, workout_template_id, workout_version_id, assigned_by, target_date, notes)
      VALUES ('00000000-0000-4000-8000-000000000001', %L, %L, %L, current_date, '   ') $sql$,
      pg_temp.recall('tpl'), pg_temp.recall('ver'), 'a5000000-0000-4000-8000-000000000003')),
    -- notes over 2000 characters
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_assignments (organization_id, workout_template_id, workout_version_id, assigned_by, target_date, notes)
      VALUES ('00000000-0000-4000-8000-000000000001', %L, %L, %L, current_date, repeat('x', 2001)) $sql$,
      pg_temp.recall('tpl'), pg_temp.recall('ver'), 'a5000000-0000-4000-8000-000000000003')),
    -- unknown status
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_assignments (organization_id, workout_template_id, workout_version_id, assigned_by, target_date, status)
      VALUES ('00000000-0000-4000-8000-000000000001', %L, %L, %L, current_date, 'paused') $sql$,
      pg_temp.recall('tpl'), pg_temp.recall('ver'), 'a5000000-0000-4000-8000-000000000003'))
  ],
  ARRAY['23514', '23514', '23514', '23514', '23514'],
  'workout_assignments: schedule-kind, notes length/blank and status constraints all fail closed'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_targets (assignment_id, athlete_id) VALUES (%L, %L) $sql$,
    'a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000001')),
  '23505',
  'assignment_targets: the same athlete cannot be targeted twice on one assignment'
);
-- recurring_schedules needs a second recurring assignment (X already owns its 1:1 schedule).
INSERT INTO public.workout_assignments (id, organization_id, workout_template_id, workout_version_id, assigned_by, is_recurring, target_date) VALUES
  ('a5000000-0000-4000-8000-0000000000e4', '00000000-0000-4000-8000-000000000001', pg_temp.recall('tpl'), pg_temp.recall('ver'),
   'a5000000-0000-4000-8000-00000000000b', true, NULL);
SELECT is(
  ARRAY[
    -- empty weekday set
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date) VALUES (%L, ARRAY[]::smallint[], current_date) $sql$,
      'a5000000-0000-4000-8000-0000000000e4')),
    -- weekday 8 (outside ISO 1-7)
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date) VALUES (%L, ARRAY[1, 8]::smallint[], current_date) $sql$,
      'a5000000-0000-4000-8000-0000000000e4')),
    -- weekday 0
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date) VALUES (%L, ARRAY[0]::smallint[], current_date) $sql$,
      'a5000000-0000-4000-8000-0000000000e4')),
    -- end_date before start_date
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date, end_date) VALUES (%L, ARRAY[1]::smallint[], current_date, current_date - 1) $sql$,
      'a5000000-0000-4000-8000-0000000000e4')),
    -- a second schedule for assignment X (1:1)
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date) VALUES (%L, ARRAY[2]::smallint[], current_date) $sql$,
      'a5000000-0000-4000-8000-0000000000e1'))
  ],
  ARRAY['23514', '23514', '23514', '23514', '23505'],
  'recurring_schedules: weekday cardinality/range, end-before-start and the 1:1 schedule rule all fail closed'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date, timezone) VALUES (%L, ARRAY[1]::smallint[], current_date, 'Europe/London') $sql$,
      'a5000000-0000-4000-8000-0000000000e4')),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date, timezone) VALUES (%L, ARRAY[1]::smallint[], current_date, 'Asia/Manila') $sql$,
      'a5000000-0000-4000-8000-0000000000e4'))
  ],
  ARRAY['22023', 'ok'],
  'F-S5-P14: a schedule timezone that differs from the organization timezone is rejected (22023); the matching one is accepted'
);
SELECT is(
  ARRAY[
    -- completed without completed_at
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_occurrences (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status)
      VALUES (%L, %L, %L, current_date + 900, now(), now() + interval '1 day', 'completed') $sql$,
      'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'))),
    -- upcoming WITH completed_at
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_occurrences (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status, completed_at)
      VALUES (%L, %L, %L, current_date + 901, now(), now() + interval '1 day', 'upcoming', now()) $sql$,
      'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'))),
    -- missed WITH completed_at
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_occurrences (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status, completed_at)
      VALUES (%L, %L, %L, current_date + 902, now(), now() + interval '1 day', 'missed', now()) $sql$,
      'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'))),
    -- unknown status
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_occurrences (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status)
      VALUES (%L, %L, %L, current_date + 903, now(), now() + interval '1 day', 'cancelled') $sql$,
      'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'))),
    -- duplicate (assignment, athlete, scheduled_date)
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.assignment_occurrences (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime)
      VALUES (%L, %L, %L, %L, now(), now() + interval '1 day') $sql$,
      'a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'), pg_temp.day(2)))
  ],
  ARRAY['23514', '23514', '23514', '23514', '23505'],
  'assignment_occurrences: completed_at consistency, status domain and the per-athlete-per-day unique key all fail closed'
);

-- 4. Session ↔ occurrence link (F-S5-P08) --------------------------------------------
SELECT is(
  (SELECT confdeltype::text FROM pg_constraint WHERE conname = 'fk_workout_sessions_assignment_occurrence'),
  'r',
  'F-S5-P08: workout_sessions.assignment_occurrence_id is ON DELETE RESTRICT (never SET NULL / CASCADE)'
);
SELECT pg_temp.mk_occ('link', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000002', 0, 'completed');
INSERT INTO public.workout_sessions (athlete_id, workout_version_id, assignment_occurrence_id, status, started_at, completed_at)
VALUES ('a5000000-0000-4000-8000-000000000002', pg_temp.recall('ver'), pg_temp.recall('link'), 'completed', now() - interval '2 hours', now() - interval '1 hour');
SELECT is(
  pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions (athlete_id, workout_version_id, assignment_occurrence_id, status, started_at, completed_at)
    VALUES (%L, %L, %L, 'completed', now() - interval '4 hours', now() - interval '3 hours') $sql$,
    'a5000000-0000-4000-8000-000000000002', pg_temp.recall('ver'), pg_temp.recall('link'))),
  '23505',
  'at most ONE session may reference a given occurrence (partial unique index)'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions (athlete_id, workout_version_id, assignment_occurrence_id, status, started_at, completed_at)
      VALUES (%L, %L, gen_random_uuid(), 'completed', now() - interval '6 hours', now() - interval '5 hours') $sql$,
      'a5000000-0000-4000-8000-000000000002', pg_temp.recall('ver'))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions (athlete_id, workout_version_id, status, started_at, completed_at)
      VALUES (%L, %L, 'completed', now() - interval '8 hours', now() - interval '7 hours') $sql$,
      'a5000000-0000-4000-8000-000000000002', pg_temp.recall('ver'))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.workout_sessions (athlete_id, workout_version_id, status, started_at, completed_at)
      VALUES (%L, %L, 'completed', now() - interval '10 hours', now() - interval '9 hours') $sql$,
      'a5000000-0000-4000-8000-000000000002', pg_temp.recall('ver')))
  ],
  ARRAY['23503', 'ok', 'ok'],
  'a session must reference a REAL occurrence (FK), while unassigned direct sessions (NULL) remain unconstrained and unlimited (the unique index is partial)'
);

-- 5. Occurrence lifecycle trigger (F-S5-P02, F-S5-P12, F-S5-P15) ----------------------
SELECT pg_temp.mk_occ('t_completed', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -20, 'completed');
SELECT pg_temp.mk_occ('t_partial', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -21, 'partially_completed');
SELECT pg_temp.mk_occ('t_abandoned', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -22, 'abandoned');
SELECT pg_temp.mk_occ('t_missed', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -23, 'missed');
SELECT pg_temp.mk_occ('t_inprog', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -24, 'in_progress');
SELECT pg_temp.mk_occ('t_up_past', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -25, 'upcoming');
SELECT pg_temp.mk_occ('t_up_future', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', 7, 'upcoming');
SELECT pg_temp.mk_occ('t_up_today', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', 0, 'upcoming');

SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET updated_at = now() WHERE id = %L $sql$, pg_temp.recall('t_completed'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET updated_at = now() WHERE id = %L $sql$, pg_temp.recall('t_partial'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET updated_at = now() WHERE id = %L $sql$, pg_temp.recall('t_abandoned'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'upcoming', completed_at = NULL WHERE id = %L $sql$, pg_temp.recall('t_completed')))
  ],
  ARRAY['22000', '22000', '22000', '22000'],
  'terminal history is immutable: any UPDATE of a completed / partially_completed / abandoned occurrence fails 22000 — even a privileged one'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_completed'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_partial'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_abandoned'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_inprog')))
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000'],
  'DELETE of any non-upcoming occurrence (completed / partially_completed / abandoned / missed / in_progress) fails 22000'
);
SELECT is(
  ARRAY[
    -- direct missed -> every terminal status
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'partially_completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'abandoned', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
    -- missed -> upcoming, missed -> missed
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'upcoming' WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET updated_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
    -- missed -> in_progress with NO linked session
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = %L $sql$, pg_temp.recall('t_missed')))
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000', '22000'],
  'F-S5-P15: a privileged direct missed -> completed / partially_completed / abandoned (and any other exit) fails 22000; missed -> in_progress needs a linked session'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET scheduled_date = scheduled_date + 1 WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET scheduled_at = scheduled_at + interval '1 hour' WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET due_datetime = due_datetime + interval '1 hour' WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET athlete_id = %L WHERE id = %L $sql$, 'a5000000-0000-4000-8000-000000000002', pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET assignment_id = %L WHERE id = %L $sql$, 'a5000000-0000-4000-8000-0000000000e2', pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET id = gen_random_uuid() WHERE id = %L $sql$, pg_temp.recall('t_up_future')))
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000', '22000'],
  'lineage and temporal anchors (id, assignment_id, athlete_id, scheduled_date, scheduled_at, due_datetime) can never be updated'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'abandoned', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'partially_completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'missed' WHERE id = %L $sql$, pg_temp.recall('t_inprog'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'upcoming' WHERE id = %L $sql$, pg_temp.recall('t_inprog')))
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000'],
  'the state machine has no shortcuts: upcoming cannot jump to a terminal status, in_progress can only move to completed / partially_completed / abandoned'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_up_future'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'missed' WHERE id = %L $sql$, pg_temp.recall('t_up_past')))
  ],
  ARRAY['ok', 'ok', 'ok'],
  'the legal transitions succeed: upcoming -> in_progress -> completed, and upcoming -> missed'
);
-- Rule C: the version may change ONLY while upcoming.
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('ver2', (public.publish_new_workout_version(pg_temp.recall('tpl'), 'v2', jsonb_build_array(jsonb_build_object(
    'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'),
        'measurement_mode', 'duration', 'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 30)))))))
  ->> 'version_id')::uuid);
RESET ROLE;
SELECT pg_temp.mk_occ('t_up_v', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', 8, 'upcoming');
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET workout_version_id = %L WHERE id = %L $sql$, pg_temp.recall('ver2'), pg_temp.recall('t_up_v'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET workout_version_id = %L WHERE id = %L $sql$, pg_temp.recall('ver2'), pg_temp.recall('t_inprog'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET workout_version_id = %L WHERE id = %L $sql$, pg_temp.recall('ver2'), pg_temp.recall('t_missed'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET workout_version_id = %L WHERE id = %L $sql$, pg_temp.recall('ver2'), pg_temp.recall('t_completed')))
  ],
  ARRAY['ok', '22000', '22000', '22000'],
  'Rule C: the workout version can change while upcoming, never once in_progress / missed / terminal'
);

-- Late-sync structural reconciliation at the trigger level (F-S5-P15).
INSERT INTO public.workout_sessions (id, athlete_id, workout_version_id, assignment_occurrence_id, status, started_at)
SELECT 'a5000000-0000-4000-8000-0000000000a1', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'), pg_temp.recall('t_missed'),
       'in_progress', o.scheduled_at + interval '10 hours'
FROM public.assignment_occurrences o WHERE o.id = pg_temp.recall('t_missed');
SELECT is(
  pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = %L $sql$, pg_temp.recall('t_missed'))),
  'ok',
  'F-S5-P15: missed -> in_progress IS permitted once a linked in_progress session started inside [scheduled_at, due_datetime) exists'
);
SELECT pg_temp.mk_occ('t_missed2', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000002', -26, 'missed');
INSERT INTO public.workout_sessions (id, athlete_id, workout_version_id, assignment_occurrence_id, status, started_at)
SELECT 'a5000000-0000-4000-8000-0000000000a2', 'a5000000-0000-4000-8000-000000000002', pg_temp.recall('ver'), pg_temp.recall('t_missed2'),
       'in_progress', o.due_datetime + interval '1 minute'
FROM public.assignment_occurrences o WHERE o.id = pg_temp.recall('t_missed2');
SELECT is(
  pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = %L $sql$, pg_temp.recall('t_missed2'))),
  '22000',
  'F-S5-P15: a linked session that started AFTER the deadline does not reconcile — the occurrence stays missed (22000)'
);
-- Even WITH a fully valid linked session, missed can only ever resume to in_progress: a direct jump to
-- any terminal status stays impossible (the structural check is a precondition of the ONE allowed exit,
-- never a route to completion).
UPDATE public.workout_sessions SET status = 'completed', completed_at = started_at + interval '1 hour'
  WHERE id = 'a5000000-0000-4000-8000-0000000000a1';
SELECT pg_temp.mk_occ('t_missed3', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', -27, 'missed');
INSERT INTO public.workout_sessions (id, athlete_id, workout_version_id, assignment_occurrence_id, status, started_at)
SELECT 'a5000000-0000-4000-8000-0000000000a3', 'a5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'), pg_temp.recall('t_missed3'),
       'in_progress', o.scheduled_at + interval '5 hours'
FROM public.assignment_occurrences o WHERE o.id = pg_temp.recall('t_missed3');
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed3'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'partially_completed', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed3'))),
    pg_temp.sqlstate_of(format($sql$ UPDATE public.assignment_occurrences SET status = 'abandoned', completed_at = now() WHERE id = %L $sql$, pg_temp.recall('t_missed3')))
  ],
  ARRAY['22000', '22000', '22000'],
  'F-S5-P15: even with a valid pre-deadline linked session present, a DIRECT missed -> completed / partially_completed / abandoned still fails 22000'
);
SELECT ok(
  (SELECT prosrc !~* 'current_setting|set_config|GUC' FROM pg_proc WHERE oid = 'app_private.enforce_occurrence_lifecycle()'::regprocedure),
  'F-S5-P15: the lifecycle trigger reads no custom GUC / session variable — reconciliation is verified purely from database state'
);

-- Cancellation delete boundary (F-S5-P12).
SELECT pg_temp.mk_occ('t_up_future2', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000001', 9, 'upcoming');
SELECT is(
  pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_up_future2'))),
  '22000',
  'deleting even a future upcoming occurrence of a NON-cancelled assignment fails 22000'
);
UPDATE public.workout_assignments SET status = 'cancelled' WHERE id = 'a5000000-0000-4000-8000-0000000000e3';
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_up_future2'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_up_today'))),
    pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_completed')))
  ],
  ARRAY['ok', 'ok', '22000'],
  'of a CANCELLED assignment, upcoming occurrences dated today or later may be deleted; a completed one still cannot'
);
SELECT pg_temp.mk_occ('t_up_past2', 'a5000000-0000-4000-8000-0000000000e3', 'a5000000-0000-4000-8000-000000000002', -3, 'upcoming');
SELECT is(
  pg_temp.sqlstate_of(format($sql$ DELETE FROM public.assignment_occurrences WHERE id = %L $sql$, pg_temp.recall('t_up_past2'))),
  '22000',
  'F-S5-P12: a PAST-dated upcoming occurrence is preserved for overdue -> missed processing — deleting it fails 22000 even for a cancelled assignment'
);

-- 6. RLS matrix (F-S5-P04, F-S5-P13) ---------------------------------------------------
-- Visible rows per identity: [assignments, targets, schedules, occurrences], counted over the
-- RLS-relevant fixtures X (recurring, 2 targets, r1 missed -5d/A1, r2 +2d/A1, r3 +2d/A2),
-- Y (single-date by C2, target A1, y1 +1d) — Z/E4 fixtures are excluded by id.
CREATE FUNCTION pg_temp.visible() RETURNS bigint[] LANGUAGE sql AS $fn$
  SELECT ARRAY[
    (SELECT count(*) FROM public.workout_assignments WHERE id IN ('a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-0000000000e2')),
    (SELECT count(*) FROM public.assignment_targets WHERE assignment_id IN ('a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-0000000000e2')),
    (SELECT count(*) FROM public.recurring_schedules WHERE assignment_id = 'a5000000-0000-4000-8000-0000000000e1'),
    (SELECT count(*) FROM public.assignment_occurrences WHERE assignment_id IN ('a5000000-0000-4000-8000-0000000000e1', 'a5000000-0000-4000-8000-0000000000e2'))
  ]
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.visible() TO authenticated;

SELECT pg_temp.act('a5000000-0000-4000-8000-000000000001'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[2, 2, 1, 3]::bigint[], 'athlete A1 sees own assignments, ONLY own target rows, the schedule and own occurrences');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000002'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[1, 1, 1, 1]::bigint[], 'athlete A2 sees ONLY assignment X, ITS OWN target row and ITS OWN occurrence (never A1''s)');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000003'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[2, 2, 1, 3]::bigint[],
  'F-S5-P04: coach C1 (current coach of A1) sees A1''s target rows and occurrences only — NOT sibling athlete A2''s target row or occurrence on the shared assignment X');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000004'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[1, 1, 1, 1]::bigint[],
  'coach C2 sees X with only A2''s target row/occurrence — and, despite AUTHORING assignment Y, sees none of it (no creator visibility shortcut)');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000005'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[0, 0, 0, 1]::bigint[],
  'the FORMER coach of A1 sees 0 assignments / targets / schedules and ONLY the occurrence scheduled inside the half-open coaching window');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000006'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[2, 3, 1, 4]::bigint[], 'a same-organization Leader (training:view_org) sees every row of the organization''s assignments');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000007'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[2, 3, 1, 4]::bigint[], 'the Vice President sees the same organization-wide scope');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000008'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[0, 0, 0, 0]::bigint[], 'F-S5-P13: a Leader of a DIFFERENT organization (same permission) sees 0 rows — cross-org fails closed');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000009'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[0, 0, 0, 0]::bigint[], 'F-S5-P13: a Leader with NO organization (home_branch_id NULL) sees 0 rows — NULL-org fails closed');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-00000000000a'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[0, 0, 0, 0]::bigint[], 'Rule A: a System-Administrator-only member sees 0 rows');
RESET ROLE;

-- Creator identity is not a permanent shortcut, and never moves the assignment's organization.
SELECT pg_temp.act('a5000000-0000-4000-8000-00000000000b'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[2, 3, 1, 4]::bigint[], 'the creator (a same-org Leader) sees the assignment through leadership scope');
RESET ROLE;
UPDATE public.profiles SET home_branch_id = 'a5000000-0000-4000-8000-0000000000f2' WHERE id = 'a5000000-0000-4000-8000-00000000000b';
SELECT pg_temp.act('a5000000-0000-4000-8000-00000000000b'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[0, 0, 0, 0]::bigint[],
  'moving the creator to another organization removes ALL access — assigned_by is not a visibility shortcut');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000008'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[0, 0, 0, 0]::bigint[],
  'the creator''s new organization does NOT drag the assignment into it — the boundary is workout_assignments.organization_id');
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000006'); SET LOCAL ROLE authenticated;
SELECT is(pg_temp.visible(), ARRAY[2, 3, 1, 4]::bigint[], 'and the original organization''s Leader still sees everything');
RESET ROLE;

-- 7. Version viewability & source eligibility on assignment (F-S5-P05, F-S5-P13) -------
-- C2 authors a PRIVATE routine; A1 authors a private routine of their own.
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000004'); SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('c2_private', (public.create_workout_template('C2 Private', NULL, 'private', jsonb_build_array(jsonb_build_object(
  'title', 'B', 'block_type', 'standard_set', 'items', jsonb_build_array(jsonb_build_object(
    'exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 'measurement_mode', 'reps',
    'sets', jsonb_build_array(jsonb_build_object('target_reps', 5)))))))->> 'template_id')::uuid);
RESET ROLE;
SELECT pg_temp.act('a5000000-0000-4000-8000-000000000001'); SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('a1_private', (public.create_workout_template('A1 Private', NULL, 'private', jsonb_build_array(jsonb_build_object(
  'title', 'B', 'block_type', 'standard_set', 'items', jsonb_build_array(jsonb_build_object(
    'exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 'measurement_mode', 'reps',
    'sets', jsonb_build_array(jsonb_build_object('target_reps', 5)))))))->> 'template_id')::uuid);
RESET ROLE;
-- (…0b moved to Org B above; restore so later fixtures stay simple.)
UPDATE public.profiles SET home_branch_id = '00000000-0000-4000-8000-000000000101' WHERE id = 'a5000000-0000-4000-8000-00000000000b';

SELECT pg_temp.act('a5000000-0000-4000-8000-000000000003'); SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('c1_private', (public.create_workout_template('C1 Private', NULL, 'private', jsonb_build_array(jsonb_build_object(
  'title', 'B', 'block_type', 'standard_set', 'items', jsonb_build_array(jsonb_build_object(
    'exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 'measurement_mode', 'reps',
    'sets', jsonb_build_array(jsonb_build_object('target_reps', 5)))))))->> 'template_id')::uuid);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(%L, NULL, ARRAY[%L]::uuid[], current_date, false, NULL, NULL, gen_random_uuid()) $sql$,
    pg_temp.recall('c2_private'), 'a5000000-0000-4000-8000-000000000001')),
  '42501',
  'F-S5-P13: assigning a private routine whose version the caller cannot view (another member''s, with no coaching link) fails 42501'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(%L, NULL, ARRAY[%L]::uuid[], current_date + 30, false, NULL, NULL, gen_random_uuid()) $sql$,
    pg_temp.recall('c1_private'), 'a5000000-0000-4000-8000-000000000001')),
  '42501',
  'F-S5-P05: a private routine may only be assigned to its creator — assigning C1''s private routine to A1 fails 42501'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(%L, NULL, ARRAY[%L]::uuid[], current_date + 31, false, NULL, NULL, gen_random_uuid()) $sql$,
    pg_temp.recall('a1_private'), 'a5000000-0000-4000-8000-000000000001')),
  'ok',
  'F-S5-P05: a coach may program an athlete''s OWN private routine back to that athlete'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(%L, NULL, ARRAY[%L]::uuid[], current_date + 32, false, NULL, NULL, gen_random_uuid()) $sql$,
      pg_temp.recall('tpl'), 'a5000000-0000-4000-8000-00000000000c')),
    pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(%L, NULL, ARRAY[%L]::uuid[], current_date + 32, false, NULL, NULL, gen_random_uuid()) $sql$,
      pg_temp.recall('tpl'), 'a5000000-0000-4000-8000-000000000002'))
  ],
  ARRAY['42501', '42501'],
  'a coach cannot assign to an athlete of ANOTHER organization, nor to an athlete they do not currently coach (42501)'
);
RESET ROLE;

-- 8. RPC signature inventory & function security attributes ---------------------------
SELECT is(
  (SELECT count(*) FROM pg_proc WHERE proname = 'start_workout_session' AND pronamespace = 'public'::regnamespace),
  2::bigint,
  'F-S5-P11: exactly TWO public.start_workout_session signatures exist (2-arg and 3-arg wrappers)'
);
SELECT is(
  (SELECT count(*) FROM pg_proc WHERE proname = 'start_workout_session_internal' AND pronamespace = 'app_private'::regnamespace),
  1::bigint,
  'F-S5-P11: exactly ONE app_private.start_workout_session_internal signature exists (single authoritative implementation)'
);
SELECT is(
  (SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'start_workout_session_internal' AND pronamespace = 'app_private'::regnamespace),
  'p_workout_version_id uuid, p_idempotency_key uuid, p_assignment_occurrence_id uuid',
  'the one private start implementation takes exactly (version, idempotency key, occurrence)'
);
SELECT is(
  (SELECT array_agg(pg_get_function_identity_arguments(oid) ORDER BY pronargs) FROM pg_proc
   WHERE proname = 'start_workout_session' AND pronamespace = 'public'::regnamespace),
  ARRAY['p_workout_version_id uuid, p_idempotency_key uuid',
        'p_workout_version_id uuid, p_idempotency_key uuid, p_assignment_occurrence_id uuid'],
  'the two public wrapper signatures are (version, key) and (version, key, occurrence)'
);
SELECT ok(
  (SELECT bool_and(NOT prosecdef) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
     AND proname IN ('create_workout_assignment', 'cancel_workout_assignment', 'migrate_assignment_version', 'start_workout_session'))
  AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
     AND proname IN ('create_workout_assignment', 'cancel_workout_assignment', 'migrate_assignment_version', 'start_workout_session')) = 5,
  'all five public assignment/start wrappers are SECURITY INVOKER'
);
SELECT ok(
  (SELECT bool_and(prosecdef AND proconfig @> ARRAY['search_path=""'])
   FROM pg_proc WHERE pronamespace = 'app_private'::regnamespace
     AND proname IN ('create_workout_assignment_internal', 'cancel_workout_assignment_internal',
                     'migrate_assignment_version_internal', 'start_workout_session_internal',
                     'sync_offline_session_bundle_internal', 'complete_workout_session_internal',
                     'complete_assignment_occurrence', 'generate_assignment_occurrences',
                     'generate_recurring_occurrences', 'mark_overdue_assignments_as_missed',
                     'enforce_occurrence_lifecycle', 'validate_recurring_schedule_timezone',
                     'can_view_assignment', 'can_view_assignment_target', 'can_view_assignment_occurrence',
                     'can_manage_assignment')),
  'every Sprint 5 SECURITY DEFINER function pins search_path = '''''
);
SELECT ok(
  (SELECT bool_and(NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
   FROM pg_proc p WHERE p.pronamespace = 'app_private'::regnamespace
     AND p.proname IN ('generate_recurring_occurrences', 'mark_overdue_assignments_as_missed', 'generate_assignment_occurrences',
                       'complete_assignment_occurrence', 'enforce_occurrence_lifecycle', 'validate_recurring_schedule_timezone',
                       'normalize_days_of_week')),
  'the cron jobs, the shared occurrence helpers and the trigger functions are NOT executable by authenticated or anon'
);
SELECT ok(
  (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
   FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('create_workout_assignment', 'cancel_workout_assignment', 'migrate_assignment_version', 'start_workout_session')),
  'the public assignment RPC wrappers are executable by authenticated and never by anon (explicit grants, ADR-002)'
);
SELECT is(
  (SELECT array_agg(jobname || '|' || schedule ORDER BY jobname) FROM cron.job),
  ARRAY['generate-recurring-occurrences|0 1 * * *', 'mark-missed-workouts|0 * * * *'],
  'F-S5-P07: both cron jobs are registered with the frozen names and schedules'
);

SELECT * FROM finish();
ROLLBACK;
