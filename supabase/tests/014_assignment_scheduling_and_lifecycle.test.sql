-- Sprint 5 · Task 5.8 — assignment RPC flows, timezone-aware scheduling and the
-- rolling 14-day horizon, the generator's idempotency, the overdue -> missed cron
-- (cron actor, in_progress never touched), the start -> complete occurrence
-- lifecycle, idempotency & racing-start semantics, temporal cancellation
-- authority and the past/future deletion boundary, Rule C version migration
-- (three mutually exclusive choices) and the structural lock-ordering statements.
-- Concurrency ITSELF (real overlapping transactions) is proven by
-- scripts/e2e/sprint5-slices.mjs on the hosted project; here the serialization
-- statements are asserted structurally (same convention as Sprint 3/4).
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(61);

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
-- Org-local calendar date (in the organization's CURRENT timezone), offset by p_days.
CREATE FUNCTION pg_temp.day(p_days integer) RETURNS date LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT ((now() AT TIME ZONE (SELECT timezone FROM public.organizations WHERE id = '00000000-0000-4000-8000-000000000001'))::date + p_days);
$fn$;
-- Assign wrapper: positional shorthand over public.create_workout_assignment (runs as the caller).
CREATE FUNCTION pg_temp.mk_asg(p_targets uuid[], p_date date, p_recurring boolean, p_rule jsonb, p_version uuid DEFAULT NULL, p_key uuid DEFAULT gen_random_uuid(), p_template uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.create_workout_assignment(COALESCE(p_template, pg_temp.recall('tpl')), p_version, p_targets, p_date, p_recurring, p_rule, NULL, p_key);
$fn$;
-- Owner-level occurrence fixture (correct local-midnight timestamps in the organization timezone).
CREATE FUNCTION pg_temp.mk_occ(p_key text, p_assignment uuid, p_athlete uuid, p_offset integer, p_status text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
  v_date date := pg_temp.day(p_offset);
  v_tz text := (SELECT timezone FROM public.organizations WHERE id = '00000000-0000-4000-8000-000000000001');
  v_id uuid;
BEGIN
  INSERT INTO public.assignment_occurrences
    (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status, completed_at)
  VALUES (p_assignment, p_athlete, pg_temp.recall('ver'), v_date,
          v_date::timestamp AT TIME ZONE v_tz, (v_date + 1)::timestamp AT TIME ZONE v_tz, p_status,
          CASE WHEN p_status IN ('completed', 'partially_completed', 'abandoned') THEN now() END)
  RETURNING id INTO v_id;
  PERFORM pg_temp.remember(p_key, v_id);
  RETURN v_id;
END;
$fn$;
CREATE FUNCTION pg_temp.occ_for(p_assignment uuid, p_athlete uuid, p_offset integer) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT id FROM public.assignment_occurrences WHERE assignment_id = p_assignment AND athlete_id = p_athlete AND scheduled_date = pg_temp.day(p_offset);
$fn$;
CREATE FUNCTION pg_temp.occ_status(p_id uuid) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT status FROM public.assignment_occurrences WHERE id = p_id;
$fn$;
CREATE FUNCTION pg_temp.first_se(p_session uuid) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT id FROM public.session_exercises WHERE session_id = p_session ORDER BY order_in_session LIMIT 1;
$fn$;
-- Occurrences an all-weekday / given-weekday schedule should hold for the rolling horizon.
CREATE FUNCTION pg_temp.expected(p_days integer[], p_start_offset integer DEFAULT 0) RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT count(*) FROM generate_series(p_start_offset, 13) AS g WHERE EXTRACT(ISODOW FROM pg_temp.day(g))::integer = ANY (p_days);
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.act(text), pg_temp.remember(text, uuid), pg_temp.recall(text), pg_temp.day(integer),
  pg_temp.mk_asg(uuid[], date, boolean, jsonb, uuid, uuid, uuid), pg_temp.mk_occ(text, uuid, uuid, integer, text),
  pg_temp.occ_for(uuid, uuid, integer), pg_temp.occ_status(uuid), pg_temp.first_se(uuid), pg_temp.expected(integer[], integer) TO authenticated;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete A1 (coach C1)   …02 Athlete A2 (coach C2)   …03 Coach C1   …04 Coach C2
--   …05 Leader (org A)          …06 Leader in Org B         …07 Athlete in Org B
--   …08 Athlete A3 (coach C1)   …09 Coach C3 (takes A3 over later)
INSERT INTO public.organizations (id, name, slug) VALUES ('b5000000-0000-4000-8000-0000000000f1', 'Club B', 'club-b-s5b-test');
INSERT INTO public.branches (id, organization_id, name) VALUES ('b5000000-0000-4000-8000-0000000000f2', 'b5000000-0000-4000-8000-0000000000f1', 'Club B Branch');
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('b5000000-0000-4000-8000-000000000001', 'a1@s5b.test', '{"full_name":"Athlete One"}'),
  ('b5000000-0000-4000-8000-000000000002', 'a2@s5b.test', '{"full_name":"Athlete Two"}'),
  ('b5000000-0000-4000-8000-000000000003', 'c1@s5b.test', '{"full_name":"Coach One"}'),
  ('b5000000-0000-4000-8000-000000000004', 'c2@s5b.test', '{"full_name":"Coach Two"}'),
  ('b5000000-0000-4000-8000-000000000005', 'la@s5b.test', '{"full_name":"Leader A"}'),
  ('b5000000-0000-4000-8000-000000000006', 'lb@s5b.test', '{"full_name":"Leader B"}'),
  ('b5000000-0000-4000-8000-000000000007', 'xb@s5b.test', '{"full_name":"Athlete B"}'),
  ('b5000000-0000-4000-8000-000000000008', 'a3@s5b.test', '{"full_name":"Athlete Three"}'),
  ('b5000000-0000-4000-8000-000000000009', 'c3@s5b.test', '{"full_name":"Coach Three"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'b5000000-0000-4000-8000-0000000000%';
UPDATE public.profiles SET home_branch_id = 'b5000000-0000-4000-8000-0000000000f2'
  WHERE id IN ('b5000000-0000-4000-8000-000000000006', 'b5000000-0000-4000-8000-000000000007');
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id FROM (VALUES
  ('b5000000-0000-4000-8000-000000000001', 'Athlete'), ('b5000000-0000-4000-8000-000000000002', 'Athlete'),
  ('b5000000-0000-4000-8000-000000000003', 'Coach'), ('b5000000-0000-4000-8000-000000000004', 'Coach'),
  ('b5000000-0000-4000-8000-000000000005', 'Leader'), ('b5000000-0000-4000-8000-000000000006', 'Leader'),
  ('b5000000-0000-4000-8000-000000000007', 'Athlete'), ('b5000000-0000-4000-8000-000000000008', 'Athlete'),
  ('b5000000-0000-4000-8000-000000000009', 'Coach')
) AS f(profile_id, position_name) JOIN public.positions pos ON pos.name = f.position_name;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000003', 'b5000000-0000-4000-8000-000000000005'),
  ('b5000000-0000-4000-8000-000000000008', 'b5000000-0000-4000-8000-000000000003', 'b5000000-0000-4000-8000-000000000005'),
  ('b5000000-0000-4000-8000-000000000002', 'b5000000-0000-4000-8000-000000000004', 'b5000000-0000-4000-8000-000000000005');

-- Coach C1 authors the organization routine (v1) and publishes v2 and v3.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('tpl', (public.create_workout_template(
  'Scheduling Fixture Routine', NULL, 'organization',
  jsonb_build_array(jsonb_build_object(
    'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
        'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 10))),
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'),
        'measurement_mode', 'duration', 'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 30))))))
) ->> 'template_id')::uuid);
SELECT pg_temp.remember('ver2', (public.publish_new_workout_version(pg_temp.recall('tpl'), 'v2', jsonb_build_array(jsonb_build_object(
  'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
    jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
      'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 12)))))))->> 'version_id')::uuid);
RESET ROLE;
SELECT pg_temp.remember('ver', v.id) FROM public.workout_versions v WHERE v.template_id = pg_temp.recall('tpl') AND v.version_number = 1;
-- A second, unrelated template (its version must be rejected on the wrong assignment).
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('tpl_other', (public.create_workout_template(
  'Other Routine', NULL, 'organization',
  jsonb_build_array(jsonb_build_object(
    'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'),
        'measurement_mode', 'duration', 'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 20))))))
) ->> 'template_id')::uuid);
RESET ROLE;
SELECT pg_temp.remember('ver_other', id) FROM public.workout_versions WHERE template_id = pg_temp.recall('tpl_other');

-- 1. create_workout_assignment: single date ----------------------------------------------
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('key_a1', gen_random_uuid());
SELECT is(
  (SELECT ARRAY[r ->> 'occurrences_created', r ->> 'status'] FROM (SELECT pg_temp.mk_asg(ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], pg_temp.day(1), false, NULL, NULL, pg_temp.recall('key_a1')) AS r) x),
  ARRAY['1', 'active'],
  'a coach creates a single-date assignment for their athlete (defaults to the latest sealed version)'
);
RESET ROLE;
SELECT pg_temp.remember('asg1', (SELECT id FROM public.workout_assignments WHERE assigned_by = 'b5000000-0000-4000-8000-000000000003' AND target_date = pg_temp.day(1)));
SELECT is(
  (SELECT ARRAY[
      (o.scheduled_date = pg_temp.day(1))::text,
      (o.scheduled_at = pg_temp.day(1)::timestamp AT TIME ZONE 'Asia/Manila')::text,
      (o.due_datetime = (pg_temp.day(1) + 1)::timestamp AT TIME ZONE 'Asia/Manila')::text,
      (o.workout_version_id = pg_temp.recall('ver2'))::text,
      o.status]
   FROM public.assignment_occurrences o WHERE o.assignment_id = pg_temp.recall('asg1')),
  ARRAY['true', 'true', 'true', 'true', 'upcoming'],
  'the occurrence spans the organization-local calendar day (midnight to midnight) and defaults to the LATEST sealed version (v2)'
);
SELECT is(
  (SELECT ARRAY[actor_type::text, (actor_user_id = 'b5000000-0000-4000-8000-000000000003')::text, entity_type, (new_values ->> 'occurrences_created')]
   FROM public.audit_logs WHERE action = 'created' AND entity_type = 'workout_assignment' AND entity_id = pg_temp.recall('asg1')::text),
  ARRAY['user', 'true', 'workout_assignment', '1'],
  'creation is audited as actor_type user, by the creating coach'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (pg_temp.mk_asg(ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], pg_temp.day(1), false, NULL, NULL, pg_temp.recall('key_a1')) ->> 'assignment_id'),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], pg_temp.day(2), false, NULL, NULL, %L) $sql$,
      'b5000000-0000-4000-8000-000000000001', pg_temp.recall('key_a1')))
  ],
  ARRAY[pg_temp.recall('asg1')::text, '42501'],
  'replaying the same key + payload returns the SAME assignment; the same key with a different payload fails closed (42501)'
);
RESET ROLE;
SELECT is(
  (SELECT count(*) FROM public.workout_assignments WHERE assigned_by = 'b5000000-0000-4000-8000-000000000003' AND target_date = pg_temp.day(1)),
  1::bigint,
  'the replay created NO second assignment'
);

-- 2. Recurring creation: weekday normalization, horizon, validation ----------------------
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_mwf', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000002']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(5, 1, 3, 3, 1), 'start_date', pg_temp.day(0)::text, 'end_date', NULL, 'timezone', 'Asia/Manila')
) ->> 'assignment_id')::uuid);
RESET ROLE;
SELECT is(
  (SELECT days_of_week FROM public.recurring_schedules WHERE assignment_id = pg_temp.recall('asg_mwf')),
  ARRAY[1, 3, 5]::smallint[],
  'F-S5-P14: unordered / duplicate weekdays are stored as the sorted distinct array {1,3,5}'
);
SELECT is(
  (SELECT ARRAY[count(*)::text, count(DISTINCT athlete_id)::text, (min(scheduled_date) >= pg_temp.day(0))::text, (max(scheduled_date) <= pg_temp.day(13))::text]
   FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_mwf')),
  ARRAY[(2 * pg_temp.expected(ARRAY[1, 3, 5]))::text, '2', 'true', 'true'],
  'the rolling 14-day horizon holds exactly the Mon/Wed/Fri days of [today, today+13] for EACH target'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], current_date, true, '{"days_of_week":[1],"start_date":"2030-01-01"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, false, NULL) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], current_date, false, '{"days_of_week":[1],"start_date":"2030-01-01"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, NULL) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, '{"days_of_week":[],"start_date":"2030-01-01"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, '{"days_of_week":[1,8],"start_date":"2030-01-01"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, '{"days_of_week":["mon"],"start_date":"2030-01-01"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, '{"days_of_week":[1],"start_date":"2030-01-01","timezone":"Europe/London"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, '{"days_of_week":[1],"start_date":"2030-02-01","end_date":"2030-01-01"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], NULL, true, '{"days_of_week":[1],"start_date":"not-a-date"}'::jsonb) $sql$, 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of($sql$ SELECT pg_temp.mk_asg(ARRAY[]::uuid[], current_date, false, NULL) $sql$)
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023'],
  'invalid schedules all fail 22023: recurring+date, single without date, single+rule, recurring without rule, empty / out-of-range / non-numeric weekdays, timezone mismatch, end before start, bad date, no targets'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], current_date + 40, false, NULL, %L) $sql$,
    'b5000000-0000-4000-8000-000000000001', pg_temp.recall('ver_other'))),
  '22023',
  'a version that belongs to a DIFFERENT template is rejected (22023)'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(%L, NULL, ARRAY[%L]::uuid[], current_date + 41, false, NULL, NULL, NULL) $sql$,
      pg_temp.recall('tpl'), 'b5000000-0000-4000-8000-000000000001')),
    pg_temp.sqlstate_of(format($sql$ SELECT public.create_workout_assignment(NULL, NULL, ARRAY[%L]::uuid[], current_date + 41, false, NULL, NULL, gen_random_uuid()) $sql$,
      'b5000000-0000-4000-8000-000000000001'))
  ],
  ARRAY['22023', '22023'],
  'a missing idempotency key or template id is rejected (22023)'
);
RESET ROLE;

-- Authority: athletes cannot assign; coaches only within their scope; leaders across their organization.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], current_date + 42, false, NULL) $sql$, 'b5000000-0000-4000-8000-000000000001')),
  '42501',
  'an athlete (no workout:assign) cannot create an assignment, not even for themselves'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L, %L]::uuid[], current_date + 43, false, NULL) $sql$,
      'b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000002')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L, %L]::uuid[], current_date + 43, false, NULL) $sql$,
      'b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000008'))
  ],
  ARRAY['42501', 'ok'],
  'a coach may target all of THEIR OWN athletes together, but one athlete outside their scope fails the whole request (42501)'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L, %L]::uuid[], current_date + 44, false, NULL) $sql$,
      'b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000002')),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], current_date + 44, false, NULL) $sql$, 'b5000000-0000-4000-8000-000000000007'))
  ],
  ARRAY['ok', '42501'],
  'a Leader may assign to any athlete of their organization, and never to another organization''s athlete'
);
RESET ROLE;

-- 3. Timezone-aware generation & the generator's idempotency ------------------------------
SELECT is(
  ARRAY[app_private.generate_recurring_occurrences()::text],
  ARRAY['0'],
  'generate_recurring_occurrences() is idempotent: re-running over an already-generated horizon creates 0 duplicates'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_all', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', pg_temp.day(0)::text)
) ->> 'assignment_id')::uuid);
SELECT pg_temp.remember('asg_late', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', pg_temp.day(5)::text)
) ->> 'assignment_id')::uuid);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[count(*)::text, min(scheduled_date)::text, max(scheduled_date)::text]
   FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_all')),
  ARRAY['14', pg_temp.day(0)::text, pg_temp.day(13)::text],
  'F-S5-P14: an every-day schedule yields EXACTLY 14 occurrences, [org today, org today + 13] inclusive — day 14 is outside the horizon'
);
SELECT is(
  (SELECT count(*) FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_late')),
  9::bigint,
  'a schedule that starts on day 5 only fills the remainder of the horizon (days 5..13)'
);
UPDATE public.recurring_schedules SET start_date = pg_temp.day(1) WHERE assignment_id = pg_temp.recall('asg_late');
SELECT is(
  ARRAY[app_private.generate_recurring_occurrences()::text, app_private.generate_recurring_occurrences()::text],
  ARRAY['4', '0'],
  'the generator fills exactly the newly eligible days 1..4 once, and a second run creates nothing'
);
-- Organization timezone is authoritative: the horizon starts at the ORG-local date.
UPDATE public.organizations SET timezone = 'Pacific/Kiritimati' WHERE id = '00000000-0000-4000-8000-000000000001';
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_kiri', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000008']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', (pg_temp.day(-2))::text, 'timezone', 'Pacific/Kiritimati')
) ->> 'assignment_id')::uuid);
RESET ROLE;
UPDATE public.organizations SET timezone = 'Pacific/Pago_Pago' WHERE id = '00000000-0000-4000-8000-000000000001';
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_pago', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000008']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', (pg_temp.day(-2))::text)
) ->> 'assignment_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[
    (SELECT min(scheduled_date)::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_kiri')),
    (SELECT min(scheduled_date)::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_pago'))
  ],
  ARRAY[(now() AT TIME ZONE 'Pacific/Kiritimati')::date::text, (now() AT TIME ZONE 'Pacific/Pago_Pago')::date::text],
  'the horizon begins at the ORGANIZATION-LOCAL date: UTC+14 and UTC-11 organizations start on different calendar days at the same instant'
);
SELECT ok(
  (SELECT (SELECT min(scheduled_date) FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_kiri'))
       <> (SELECT min(scheduled_date) FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_pago'))),
  'and the two organizations really do differ (the local-date rule is exercised, not degenerate)'
);
SELECT ok(
  (SELECT bool_and(scheduled_at AT TIME ZONE 'Pacific/Kiritimati' = scheduled_date::timestamp
                   AND due_datetime AT TIME ZONE 'Pacific/Kiritimati' = (scheduled_date + 1)::timestamp)
   FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_kiri')),
  'every generated scheduled_at / due_datetime is the local midnight pair in the organization timezone'
);
-- DST: a spring-forward day is 23h long, a fall-back day 25h; due_datetime is the next LOCAL midnight.
UPDATE public.organizations SET timezone = 'America/New_York' WHERE id = '00000000-0000-4000-8000-000000000001';
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_dst1', (pg_temp.mk_asg(ARRAY['b5000000-0000-4000-8000-000000000008']::uuid[], DATE '2026-03-08', false, NULL) ->> 'assignment_id')::uuid);
SELECT pg_temp.remember('asg_dst2', (pg_temp.mk_asg(ARRAY['b5000000-0000-4000-8000-000000000008']::uuid[], DATE '2026-11-01', false, NULL) ->> 'assignment_id')::uuid);
RESET ROLE;
SELECT is(
  (SELECT array_agg(round(EXTRACT(EPOCH FROM (due_datetime - scheduled_at)) / 3600)::text ORDER BY scheduled_date) FROM public.assignment_occurrences
   WHERE assignment_id IN (pg_temp.recall('asg_dst1'), pg_temp.recall('asg_dst2'))),
  ARRAY['23', '25'],
  'DST: the spring-forward day spans 23h and the fall-back day 25h — due_datetime is the next local midnight, not scheduled_at + 24h'
);
UPDATE public.organizations SET timezone = 'Asia/Manila' WHERE id = '00000000-0000-4000-8000-000000000001';

-- 4. Overdue -> missed cron (F-S5-P07, F-S5-P09) ----------------------------------------------
INSERT INTO public.workout_assignments (id, organization_id, workout_template_id, workout_version_id, assigned_by, is_recurring, target_date) VALUES
  ('b5000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-000000000001', pg_temp.recall('tpl'), pg_temp.recall('ver'),
   'b5000000-0000-4000-8000-000000000005', false, pg_temp.day(0));
INSERT INTO public.assignment_targets (assignment_id, athlete_id) VALUES
  ('b5000000-0000-4000-8000-0000000000e1', 'b5000000-0000-4000-8000-000000000002');
SELECT pg_temp.mk_occ('c_overdue1', 'b5000000-0000-4000-8000-0000000000e1', 'b5000000-0000-4000-8000-000000000002', -3, 'upcoming');
SELECT pg_temp.mk_occ('c_overdue2', 'b5000000-0000-4000-8000-0000000000e1', 'b5000000-0000-4000-8000-000000000002', -4, 'upcoming');
SELECT pg_temp.mk_occ('c_inprog', 'b5000000-0000-4000-8000-0000000000e1', 'b5000000-0000-4000-8000-000000000002', -5, 'in_progress');
SELECT pg_temp.mk_occ('c_future', 'b5000000-0000-4000-8000-0000000000e1', 'b5000000-0000-4000-8000-000000000002', 6, 'upcoming');
SELECT pg_temp.mk_occ('c_today', 'b5000000-0000-4000-8000-0000000000e1', 'b5000000-0000-4000-8000-000000000002', 0, 'upcoming');
-- Run with an authenticated athlete's JWT claims present: the cron actor must not depend on auth.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000002');
-- Three rows are overdue: the two fixtures above plus the PAST-dated (2026-03-08) DST assignment created earlier.
SELECT is(
  app_private.mark_overdue_assignments_as_missed()::text,
  '3',
  'the overdue job moves exactly the expired upcoming occurrences (2 fixtures + the past-dated DST one) to missed'
);
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('c_overdue1')), pg_temp.occ_status(pg_temp.recall('c_overdue2')),
        pg_temp.occ_status(pg_temp.recall('c_inprog')), pg_temp.occ_status(pg_temp.recall('c_future')), pg_temp.occ_status(pg_temp.recall('c_today'))],
  ARRAY['missed', 'missed', 'in_progress', 'upcoming', 'upcoming'],
  'an in_progress occurrence is NEVER marked missed, and not-yet-due upcoming occurrences are left alone'
);
SELECT is(
  (SELECT ARRAY[count(*)::text, min(actor_type::text), (bool_and(actor_user_id IS NULL))::text,
                (bool_and(old_values ->> 'status' = 'upcoming' AND new_values ->> 'status' = 'missed'))::text]
   FROM public.audit_logs WHERE entity_type = 'assignment_occurrence'
     AND entity_id IN (pg_temp.recall('c_overdue1')::text, pg_temp.recall('c_overdue2')::text)),
  ARRAY['2', 'cron', 'true', 'true'],
  'F-S5-P09: each transition is audited as actor_type cron with NO user id — even though an athlete''s JWT was present in the session'
);
SELECT is(
  app_private.mark_overdue_assignments_as_missed()::text,
  '0',
  'the overdue job is idempotent: a second run moves nothing'
);

-- 5. Start -> complete lifecycle through the RPCs --------------------------------------------
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('occ1', pg_temp.occ_for(pg_temp.recall('asg1'), 'b5000000-0000-4000-8000-000000000001', 1));
SELECT pg_temp.remember('start_key', gen_random_uuid());
SELECT pg_temp.remember('s1', (public.start_workout_session(pg_temp.recall('ver2'), pg_temp.recall('start_key'), pg_temp.recall('occ1')) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('occ1')),
        (SELECT assignment_occurrence_id::text FROM public.workout_sessions WHERE id = pg_temp.recall('s1'))],
  ARRAY['in_progress', pg_temp.recall('occ1')::text],
  'starting an assigned session links it to the occurrence and moves it upcoming -> in_progress'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (public.start_workout_session(pg_temp.recall('ver2'), pg_temp.recall('start_key'), pg_temp.recall('occ1')) ->> 'session_id'),
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, %L, %L) $sql$,
      pg_temp.recall('ver2'), pg_temp.recall('start_key'), pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 3))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, %L) $sql$, pg_temp.recall('ver2'), pg_temp.recall('start_key')))
  ],
  ARRAY[pg_temp.recall('s1')::text, '42501', '42501'],
  'F-S5-P11: the SAME key replays the cached session; the same key reused for a different occurrence — or as a direct start — fails 42501 (the hash carries the occurrence identity)'
);
SELECT is(
  ARRAY[
    -- a DIFFERENT key racing for the SAME occurrence: the occurrence is no longer upcoming
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), %L) $sql$, pg_temp.recall('ver2'), pg_temp.recall('occ1'))),
    -- a direct start while a session is active keeps its Sprint 4 behaviour
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid()) $sql$, pg_temp.recall('ver2'))),
    -- another occurrence while a session is active
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), %L) $sql$,
      pg_temp.recall('ver2'), pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 3)))
  ],
  ARRAY['22000', '23505', '23505'],
  'a second start of the SAME occurrence with a different key fails 22000 (not upcoming) BEFORE the active-session rule; other starts keep 23505'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), %L) $sql$,
      pg_temp.recall('ver'), pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 4))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), gen_random_uuid()) $sql$, pg_temp.recall('ver')))
  ],
  ARRAY['42501', '22000'],
  'an athlete cannot start ANOTHER athlete''s occurrence (42501); an unknown occurrence id is simply unavailable (22000)'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT public.complete_workout_session(pg_temp.recall('s1'), 'completed', NULL, NULL, NULL, gen_random_uuid());
RESET ROLE;
SELECT is(
  (SELECT ARRAY[o.status, (o.completed_at = s.completed_at)::text]
   FROM public.assignment_occurrences o JOIN public.workout_sessions s ON s.assignment_occurrence_id = o.id WHERE o.id = pg_temp.recall('occ1')),
  ARRAY['completed', 'true'],
  'completing the session moves the occurrence in_progress -> completed with completed_at equal to the session''s'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), %L) $sql$, pg_temp.recall('ver2'), pg_temp.recall('occ1'))),
    -- wrong version for a still-upcoming occurrence
    pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), %L) $sql$,
      pg_temp.recall('ver'), pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 3)))
  ],
  ARRAY['22000', '22000'],
  'a completed occurrence can never be started again, and starting with a version other than the occurrence''s pinned one fails 22000'
);
-- Abandon WITH a recorded set -> partially_completed; abandon with NO sets -> abandoned.
SELECT pg_temp.remember('s2', (public.start_workout_session(pg_temp.recall('ver2'), gen_random_uuid(),
  pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 3)) ->> 'session_id')::uuid);
SELECT public.record_session_set(pg_temp.recall('s2'), pg_temp.first_se(pg_temp.recall('s2')), '{"set_number":1,"actual_reps":5,"is_completed":true}'::jsonb, gen_random_uuid());
SELECT public.complete_workout_session(pg_temp.recall('s2'), 'abandoned', 'time_constraint', NULL, NULL, gen_random_uuid());
SELECT pg_temp.remember('s3', (public.start_workout_session(pg_temp.recall('ver2'), gen_random_uuid(),
  pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 4)) ->> 'session_id')::uuid);
SELECT public.complete_workout_session(pg_temp.recall('s3'), 'abandoned', 'other', NULL, NULL, gen_random_uuid());
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 3)),
        pg_temp.occ_status(pg_temp.occ_for(pg_temp.recall('asg_all'), 'b5000000-0000-4000-8000-000000000001', 4))],
  ARRAY['partially_completed', 'abandoned'],
  'abandoning with >= 1 recorded set -> partially_completed; abandoning with 0 sets -> abandoned'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('s_direct', (public.start_workout_session(pg_temp.recall('ver'), gen_random_uuid()) ->> 'session_id')::uuid);
SELECT public.complete_workout_session(pg_temp.recall('s_direct'), 'completed', NULL, NULL, NULL, gen_random_uuid());
RESET ROLE;
SELECT is(
  (SELECT assignment_occurrence_id FROM public.workout_sessions WHERE id = pg_temp.recall('s_direct')),
  NULL::uuid,
  'the 2-arg start still creates a plain direct session with no occurrence (Sprint 4 behaviour preserved)'
);

-- 6. Cancellation: temporal authority & the past/future deletion boundary (F-S5-P06, F-S5-P12) ---
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_c', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000002']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', pg_temp.day(0)::text)
) ->> 'assignment_id')::uuid);
RESET ROLE;
-- History that must survive: overdue upcoming (-2), missed (-3), completed (-4), in_progress (-5) for A1.
SELECT pg_temp.mk_occ('cx_past_up', pg_temp.recall('asg_c'), 'b5000000-0000-4000-8000-000000000001', -2, 'upcoming');
SELECT pg_temp.mk_occ('cx_missed', pg_temp.recall('asg_c'), 'b5000000-0000-4000-8000-000000000001', -3, 'missed');
SELECT pg_temp.mk_occ('cx_done', pg_temp.recall('asg_c'), 'b5000000-0000-4000-8000-000000000001', -4, 'completed');
SELECT pg_temp.mk_occ('cx_inprog', pg_temp.recall('asg_c'), 'b5000000-0000-4000-8000-000000000001', -5, 'in_progress');
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    -- C1 coaches A1 but NOT A2 -> cannot cancel a shared assignment
    pg_temp.sqlstate_of(format($sql$ SELECT public.cancel_workout_assignment(%L, gen_random_uuid()) $sql$, pg_temp.recall('asg_c'))),
    -- an unrelated outsider
    pg_temp.sqlstate_of(format($sql$ SELECT public.cancel_workout_assignment(%L, gen_random_uuid()) $sql$, pg_temp.recall('asg_mwf')))
  ],
  ARRAY['42501', '42501'],
  'F-S5-P06: a coach who does not currently coach EVERY target cannot cancel the assignment (42501) — creating it confers no permanent right'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000006');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.cancel_workout_assignment(%L, gen_random_uuid()) $sql$, pg_temp.recall('asg_c'))),
  '42501',
  'a Leader of ANOTHER organization cannot cancel it either (42501)'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('cancel_key', gen_random_uuid());
SELECT is(
  ARRAY[
    (public.cancel_workout_assignment(pg_temp.recall('asg_c'), pg_temp.recall('cancel_key')) ->> 'status'),
    (public.cancel_workout_assignment(pg_temp.recall('asg_c'), pg_temp.recall('cancel_key')) ->> 'status'),
    pg_temp.sqlstate_of(format($sql$ SELECT public.cancel_workout_assignment(%L, gen_random_uuid()) $sql$, pg_temp.recall('asg_c')))
  ],
  ARRAY['cancelled', 'cancelled', '22000'],
  'organization leadership cancels it; the same key replays the cached result; cancelling an already-cancelled assignment with a new key fails 22000'
);
RESET ROLE;
SELECT is(
  ARRAY[
    (SELECT status FROM public.workout_assignments WHERE id = pg_temp.recall('asg_c')),
    (SELECT is_active::text FROM public.recurring_schedules WHERE assignment_id = pg_temp.recall('asg_c')),
    (SELECT count(*)::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_c') AND status = 'upcoming' AND scheduled_date >= pg_temp.day(0))
  ],
  ARRAY['cancelled', 'false', '0'],
  'cancellation marks the assignment cancelled, deactivates its schedule and purges every future / today upcoming occurrence'
);
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('cx_past_up')), pg_temp.occ_status(pg_temp.recall('cx_missed')),
        pg_temp.occ_status(pg_temp.recall('cx_done')), pg_temp.occ_status(pg_temp.recall('cx_inprog'))],
  ARRAY['upcoming', 'missed', 'completed', 'in_progress'],
  'F-S5-P12: the overdue upcoming, missed, completed and in_progress history all SURVIVE cancellation untouched'
);
SELECT is(
  (SELECT ARRAY[actor_type::text, (new_values ->> 'status'), (new_values ->> 'deleted_occurrences')]
   FROM public.audit_logs WHERE action = 'cancelled' AND entity_id = pg_temp.recall('asg_c')::text),
  ARRAY['user', 'cancelled', (2 * 14)::text],
  'cancellation is audited as actor_type user, recording how many future occurrences it deleted (14 days x 2 athletes)'
);
CREATE TEMP TABLE gen_probe AS SELECT (SELECT count(*) FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_c')) AS before_n;
SELECT app_private.generate_recurring_occurrences();
SELECT is(
  (SELECT count(*) FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_c')),
  (SELECT before_n FROM gen_probe),
  'a cancelled assignment can never gain occurrences from the generator (its row count is unchanged after a run)'
);
SELECT is(
  (SELECT count(*) FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_c') AND scheduled_date >= pg_temp.day(0)),
  0::bigint,
  '...and none exist after the generator ran'
);
-- Starting on a cancelled assignment whose overdue occurrence still exists fails closed (22000).
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.start_workout_session(%L, gen_random_uuid(), %L) $sql$, pg_temp.recall('ver'), pg_temp.recall('cx_past_up'))),
  '22000',
  'F-S5-P12: starting an occurrence of a CANCELLED assignment fails closed (22000)'
);
RESET ROLE;
-- Coach authority follows the CURRENT coaching relationship.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_two', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000008']::uuid[], current_date + 50, false, NULL) ->> 'assignment_id')::uuid);
RESET ROLE;
UPDATE public.coach_assignments SET ended_at = now() WHERE athlete_id = 'b5000000-0000-4000-8000-000000000008' AND ended_at IS NULL;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('b5000000-0000-4000-8000-000000000008', 'b5000000-0000-4000-8000-000000000009', 'b5000000-0000-4000-8000-000000000005');
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.cancel_workout_assignment(%L, gen_random_uuid()) $sql$, pg_temp.recall('asg_two'))),
  '42501',
  'F-S5-P06: once one target athlete was reassigned to another coach, the original coach can no longer cancel (42501); leadership must intervene'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.cancel_workout_assignment(%L, gen_random_uuid()) $sql$, pg_temp.recall('asg_two'))),
  'ok',
  'and organization leadership still can'
);
RESET ROLE;

-- 7. Rule C: assignment-version migration (F-S5-P01, F-S5-P10, F-S5-P13) -------------------------
-- Publish v3 for the template, then two recurring assignments that start late in the horizon so the
-- generator has future days left to fill.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('ver3', (public.publish_new_workout_version(pg_temp.recall('tpl'), 'v3', jsonb_build_array(jsonb_build_object(
  'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
    jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'),
      'measurement_mode', 'duration', 'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 45)))))))->> 'version_id')::uuid);
SELECT pg_temp.remember('asg_r', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', pg_temp.day(9)::text), pg_temp.recall('ver')
) ->> 'assignment_id')::uuid);
SELECT pg_temp.remember('asg_f', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], NULL, true,
  jsonb_build_object('days_of_week', jsonb_build_array(1, 2, 3, 4, 5, 6, 7), 'start_date', pg_temp.day(9)::text), pg_temp.recall('ver')
) ->> 'assignment_id')::uuid);
RESET ROLE;
SELECT pg_temp.remember('rc_o1', pg_temp.occ_for(pg_temp.recall('asg_r'), 'b5000000-0000-4000-8000-000000000001', 10));
SELECT pg_temp.remember('rc_o2', pg_temp.occ_for(pg_temp.recall('asg_r'), 'b5000000-0000-4000-8000-000000000001', 11));
SELECT pg_temp.remember('rc_o3', pg_temp.occ_for(pg_temp.recall('asg_r'), 'b5000000-0000-4000-8000-000000000001', 12));
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT ARRAY[r ->> 'choice', r ->> 'updated_occurrences'] FROM (SELECT public.migrate_assignment_version(
    pg_temp.recall('asg_r'), pg_temp.recall('ver3'), 'template_only', NULL, gen_random_uuid()) AS r) x),
  ARRAY['template_only', '0'],
  'template_only reports 0 updated occurrences'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[
     (SELECT workout_version_id = pg_temp.recall('ver') FROM public.workout_assignments WHERE id = pg_temp.recall('asg_r'))::text,
     (SELECT bool_and(workout_version_id = pg_temp.recall('ver'))::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_r'))]),
  ARRAY['true', 'true'],
  'Rule C template_only: the assignment and EVERY occurrence stay pinned to the prior version'
);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT ARRAY[r ->> 'choice', r ->> 'updated_occurrences'] FROM (SELECT public.migrate_assignment_version(
    pg_temp.recall('asg_r'), pg_temp.recall('ver3'), 'selected_upcoming_assignments',
    ARRAY[pg_temp.recall('rc_o2'), pg_temp.recall('rc_o3'), pg_temp.recall('rc_o3')], gen_random_uuid()) AS r) x),
  ARRAY['selected_upcoming_assignments', '2'],
  'selected_upcoming_assignments migrates exactly the (distinct) selected occurrences'
);
RESET ROLE;
SELECT is(
  ARRAY[
    (SELECT workout_version_id::text FROM public.workout_assignments WHERE id = pg_temp.recall('asg_r')),
    (SELECT workout_version_id::text FROM public.assignment_occurrences WHERE id = pg_temp.recall('rc_o1')),
    (SELECT workout_version_id::text FROM public.assignment_occurrences WHERE id = pg_temp.recall('rc_o2')),
    (SELECT workout_version_id::text FROM public.assignment_occurrences WHERE id = pg_temp.recall('rc_o3'))
  ],
  ARRAY[pg_temp.recall('ver')::text, pg_temp.recall('ver')::text, pg_temp.recall('ver3')::text, pg_temp.recall('ver3')::text],
  'Rule C selected: the assignment DEFAULT version is untouched; only the selected occurrences moved; the unselected one stays on the old version'
);
UPDATE public.recurring_schedules SET start_date = pg_temp.day(6) WHERE assignment_id = pg_temp.recall('asg_r');
SELECT app_private.generate_recurring_occurrences();
SELECT is(
  (SELECT bool_and(workout_version_id = pg_temp.recall('ver'))::text FROM public.assignment_occurrences
   WHERE assignment_id = pg_temp.recall('asg_r') AND scheduled_date BETWEEN pg_temp.day(6) AND pg_temp.day(8)),
  'true',
  'Rule C selected: occurrences generated AFTERWARDS still use the assignment''s unchanged default version'
);
SELECT is(
  (SELECT ARRAY[actor_type::text, new_values ->> 'migration_choice', (new_values ->> 'old_version_id'), (new_values ->> 'new_version_id'),
                jsonb_array_length(new_values -> 'migrated_occurrence_ids')::text]
   FROM public.audit_logs WHERE action = 'version_migrated' AND entity_id = pg_temp.recall('asg_r')::text
     AND new_values ->> 'migration_choice' = 'selected_upcoming_assignments'),
  ARRAY['user', 'selected_upcoming_assignments', pg_temp.recall('ver')::text, pg_temp.recall('ver3')::text, '2'],
  'the migration is audited as version_migrated with old/new versions, the choice and the migrated occurrence ids'
);
-- Safety boundary: in_progress / terminal / foreign occurrences can never be migrated.
SELECT pg_temp.mk_occ('rc_done', pg_temp.recall('asg_r'), 'b5000000-0000-4000-8000-000000000001', -2, 'completed');
SELECT pg_temp.mk_occ('rc_prog', pg_temp.recall('asg_r'), 'b5000000-0000-4000-8000-000000000001', -3, 'in_progress');
SELECT pg_temp.mk_occ('rc_miss', pg_temp.recall('asg_r'), 'b5000000-0000-4000-8000-000000000001', -4, 'missed');
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', ARRAY[%L]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('rc_done'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', ARRAY[%L]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('rc_prog'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', ARRAY[%L]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('rc_miss'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', ARRAY[%L]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('cx_past_up'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', ARRAY[%L, %L]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('rc_o1'), pg_temp.recall('rc_done')))
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000'],
  'Rule C safety boundary: a completed / in_progress / missed / foreign occurrence anywhere in the selection fails 22000'
);
SELECT is(
  (SELECT workout_version_id::text FROM public.assignment_occurrences WHERE id = pg_temp.recall('rc_o1')),
  pg_temp.recall('ver')::text,
  '...and the failed batch was atomic: the valid occurrence in it was NOT migrated'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', NULL, gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'selected_upcoming_assignments', ARRAY[]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'template_only', ARRAY[%L]::uuid[], gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('rc_o1'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'both', NULL, gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'template_only', NULL, gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver_other')))
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023'],
  'the three choices are mutually exclusive and validated: selected needs ids, the others take none, unknown choices and foreign-template versions fail 22023'
);
SELECT pg_temp.remember('rk', gen_random_uuid());
SELECT is(
  ARRAY[
    (public.migrate_assignment_version(pg_temp.recall('asg_r'), pg_temp.recall('ver2'), 'template_only', NULL, pg_temp.recall('rk')) ->> 'status'),
    (public.migrate_assignment_version(pg_temp.recall('asg_r'), pg_temp.recall('ver2'), 'template_only', NULL, pg_temp.recall('rk')) ->> 'status'),
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'future_assignments_only', NULL, %L) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'), pg_temp.recall('rk')))
  ],
  ARRAY['migrated', 'migrated', '42501'],
  'migration is idempotent per key (replay = cached result) and a reused key with a different choice fails closed (42501)'
);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000004');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'template_only', NULL, gen_random_uuid()) $sql$, pg_temp.recall('asg_r'), pg_temp.recall('ver2'))),
  '42501',
  'a coach with no scope over the assignment''s targets cannot migrate it (42501)'
);
RESET ROLE;
-- future_assignments_only on a separate recurring assignment.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT public.migrate_assignment_version(pg_temp.recall('asg_f'), pg_temp.recall('ver3'), 'future_assignments_only', NULL, gen_random_uuid());
RESET ROLE;
SELECT is(
  ARRAY[
    (SELECT workout_version_id::text FROM public.workout_assignments WHERE id = pg_temp.recall('asg_f')),
    (SELECT bool_and(workout_version_id = pg_temp.recall('ver'))::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('asg_f'))
  ],
  ARRAY[pg_temp.recall('ver3')::text, 'true'],
  'Rule C future_assignments_only: the assignment default moves to the new version while every EXISTING occurrence stays on the old one'
);
UPDATE public.recurring_schedules SET start_date = pg_temp.day(6) WHERE assignment_id = pg_temp.recall('asg_f');
SELECT app_private.generate_recurring_occurrences();
SELECT is(
  (SELECT bool_and(workout_version_id = pg_temp.recall('ver3'))::text FROM public.assignment_occurrences
   WHERE assignment_id = pg_temp.recall('asg_f') AND scheduled_date BETWEEN pg_temp.day(6) AND pg_temp.day(8)),
  'true',
  '...and occurrences generated AFTERWARDS use the new default version'
);
SELECT is(
  (SELECT count(*) FROM public.workout_sessions s WHERE s.workout_version_id = pg_temp.recall('ver3')),
  0::bigint,
  'no workout session was ever mutated or re-pinned by a version migration'
);
-- F-S5-P13: a hidden version cannot be migrated to. A1 owns a private routine; A1 later publishes a
-- version containing A1's own PRIVATE custom exercise, which a coach cannot see.
INSERT INTO public.exercises (id, name, slug, category, measurement_types, equipment_needed, created_by, status, is_official) VALUES
  ('b5000000-0000-4000-8000-0000000000c1', 'A1 Private Move', 'a1-private-move-s5', 'core', ARRAY['reps'], ARRAY['none'],
   'b5000000-0000-4000-8000-000000000001', 'private', false);
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('a1_tpl', (public.create_workout_template('A1 Own Routine', NULL, 'private', jsonb_build_array(jsonb_build_object(
  'title', 'B', 'block_type', 'standard_set', 'items', jsonb_build_array(jsonb_build_object(
    'exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 'measurement_mode', 'reps',
    'sets', jsonb_build_array(jsonb_build_object('target_reps', 5)))))))->> 'template_id')::uuid);
RESET ROLE;
-- While the routine is still all-approved, C1 (A1's coach) programs it back to A1.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('asg_priv', (pg_temp.mk_asg(
  ARRAY['b5000000-0000-4000-8000-000000000001']::uuid[], current_date + 60, false, NULL,
  (SELECT id FROM public.workout_versions WHERE template_id = pg_temp.recall('a1_tpl') AND version_number = 1), gen_random_uuid(), pg_temp.recall('a1_tpl')
) ->> 'assignment_id')::uuid);
RESET ROLE;
-- A1 then publishes v2 containing their own PRIVATE custom exercise: the latest sealed version now holds an
-- unapproved exercise, so a non-creator coach can no longer see it.
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('a1_hidden', (public.publish_new_workout_version(pg_temp.recall('a1_tpl'), 'hidden', jsonb_build_array(jsonb_build_object(
  'title', 'B', 'block_type', 'standard_set', 'items', jsonb_build_array(jsonb_build_object(
    'exercise_id', 'b5000000-0000-4000-8000-0000000000c1', 'measurement_mode', 'reps',
    'sets', jsonb_build_array(jsonb_build_object('target_reps', 5)))))))->> 'version_id')::uuid);
RESET ROLE;
SELECT pg_temp.act('b5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.migrate_assignment_version(%L, %L, 'future_assignments_only', NULL, gen_random_uuid()) $sql$, pg_temp.recall('asg_priv'), pg_temp.recall('a1_hidden'))),
    pg_temp.sqlstate_of(format($sql$ SELECT pg_temp.mk_asg(ARRAY[%L]::uuid[], current_date + 61, false, NULL, %L, gen_random_uuid(), %L) $sql$,
      'b5000000-0000-4000-8000-000000000001', pg_temp.recall('a1_hidden'), pg_temp.recall('a1_tpl')))
  ],
  ARRAY['42501', '42501'],
  'F-S5-P13: migrating to — or assigning — a HIDDEN version (the athlete''s private custom exercise) fails 42501'
);
RESET ROLE;

-- 8. Structural lock-ordering statements (behaviour is proven by the hosted concurrency probes) --
SELECT ok(
  (SELECT prosrc ~* 'FOR SHARE OF a' AND prosrc ~* 'FROM public\.assignment_occurrences WHERE id = p_assignment_occurrence_id FOR UPDATE'
          AND prosrc ~* 'FROM public\.profiles WHERE id = v_uid FOR UPDATE'
          AND position('FOR SHARE OF a' IN prosrc) < position('FROM public.assignment_occurrences WHERE id = p_assignment_occurrence_id FOR UPDATE' IN prosrc)
          AND position('FROM public.assignment_occurrences WHERE id = p_assignment_occurrence_id FOR UPDATE' IN prosrc) < position('FROM public.profiles WHERE id = v_uid FOR UPDATE' IN prosrc)
   FROM pg_proc WHERE oid = 'app_private.start_workout_session_internal(uuid, uuid, uuid)'::regprocedure),
  'F-S5-P12: start locks assignment FOR SHARE, then the occurrence FOR UPDATE, then the athlete profile — in that order'
);
SELECT ok(
  (SELECT prosrc ~* 'FROM public\.workout_assignments WHERE id = p_assignment_id FOR UPDATE'
   FROM pg_proc WHERE oid = 'app_private.cancel_workout_assignment_internal(uuid, uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FROM public\.workout_assignments WHERE id = p_assignment_id FOR UPDATE'
       FROM pg_proc WHERE oid = 'app_private.migrate_assignment_version_internal(uuid, uuid, text, uuid[], uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FOR SHARE OF a' FROM pg_proc WHERE oid = 'app_private.generate_recurring_occurrences()'::regprocedure)
  AND (SELECT prosrc ~* 'FOR UPDATE SKIP LOCKED' FROM pg_proc WHERE oid = 'app_private.mark_overdue_assignments_as_missed()'::regprocedure),
  'cancel / migrate lock the assignment FOR UPDATE, the generator FOR SHARE, and the overdue job locks each occurrence FOR UPDATE SKIP LOCKED'
);

SELECT * FROM finish();
ROLLBACK;
