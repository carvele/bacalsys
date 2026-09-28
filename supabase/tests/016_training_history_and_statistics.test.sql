-- Sprint 6 · Task 6.8 — training history, session replay and summary statistics.
--
--   * Calendar read model: sessions and occurrences under RLS for the athlete, the
--     current coach, a former coach (half-open tenure window), a leader, a peer
--     and an unassigned coach.
--   * get_session_replay (F-S6-P02): prescribed items/sets of an athlete's PRIVATE
--     template are readable through the replay although the viewing coach cannot
--     read the template itself; paired sets flag is_skipped / is_extra
--     (F-S6-P11 / P12); Rule E — private feedback and MEDICAL substitutions are
--     redacted for viewers who may not see them.
--   * get_my_athlete_summary / get_athlete_summary (Feature 7.2, F-S6-P08):
--     adherence math, zero scheduled → NULL, the organization's timezone decides
--     the calendar day, window validation, and a former coach is refused (42501).
--   * F-S6-P15 privilege delegation: the SECURITY INVOKER wrappers run for
--     `authenticated` and are refused (42501) for `anon`; the private delegates are
--     not executable by anon.
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(49);

-- Helpers (rolled back with the test) ------------------------------------------------
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE FUNCTION pg_temp.remember(p_k text, p_v uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  INSERT INTO pg_temp.ids VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = excluded.v;
  RETURN p_v;
END;
$fn$;
CREATE FUNCTION pg_temp.recall(p_k text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $fn$
  SELECT v FROM pg_temp.ids WHERE k = p_k;
$fn$;
CREATE FUNCTION pg_temp.u(p_n integer) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT 'd6000000-0000-4000-8000-0000000000' || lpad(p_n::text, 2, '0');
$fn$;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;
-- Run p_sql as `authenticated` acting as p_uid, returning a scalar; role restored after.
CREATE FUNCTION pg_temp.as_jsonb(p_uid text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(p_uid);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO r;
  EXECUTE 'RESET ROLE';
  RETURN r;
END;
$fn$;
CREATE FUNCTION pg_temp.as_bigint(p_uid text, p_sql text) RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE r bigint;
BEGIN
  PERFORM pg_temp.act(p_uid);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO r;
  EXECUTE 'RESET ROLE';
  RETURN r;
END;
$fn$;
-- SQLSTATE of p_sql run as `authenticated` (p_uid) or `anon` (p_uid IS NULL).
CREATE FUNCTION pg_temp.as_sqlstate(p_uid text, p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE 'SET LOCAL ROLE anon';
  ELSE
    PERFORM pg_temp.act(p_uid);
    EXECUTE 'SET LOCAL ROLE authenticated';
  END IF;
  EXECUTE p_sql;
  EXECUTE 'RESET ROLE';
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END;
$fn$;
CREATE FUNCTION pg_temp.replay(p_uid text, p_session uuid) RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.as_jsonb(p_uid, format('SELECT public.get_session_replay(%L)', p_session));
$fn$;
CREATE FUNCTION pg_temp.summary(p_uid text, p_start date DEFAULT NULL, p_end date DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.as_jsonb(p_uid, format('SELECT public.get_my_athlete_summary(%L, %L)', p_start, p_end));
$fn$;
-- The replay item for a prescribed exercise slug.
CREATE FUNCTION pg_temp.item(p_replay jsonb, p_slug text) RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_path_query_first(p_replay, '$.items[*] ? (@.prescribed_exercise_name == $n)',
    jsonb_build_object('n', (SELECT name FROM public.exercises WHERE slug = p_slug)));
$fn$;
-- Compact "set:is_skipped:is_extra" fingerprint of an item's paired sets.
CREATE FUNCTION pg_temp.sets_of(p_item jsonb) RETURNS text[] LANGUAGE sql AS $fn$
  SELECT array_agg((s ->> 'set_number') || ':' || (s ->> 'is_skipped') || ':' || (s ->> 'is_extra')
                   ORDER BY (s ->> 'set_number')::integer)
  FROM jsonb_array_elements(p_item -> 'sets') s;
$fn$;
CREATE FUNCTION pg_temp.item_for(p_version uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.exercises e ON e.id = i.exercise_id
  WHERE b.workout_version_id = p_version AND e.slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.se_for(p_session uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT se.id FROM public.session_exercises se JOIN public.exercises e ON e.id = se.exercise_id
  WHERE se.session_id = p_session AND e.slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.set_id_of(p_item uuid, p_set_number integer) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT id FROM public.workout_item_sets WHERE workout_item_id = p_item AND set_number = p_set_number;
$fn$;
CREATE FUNCTION pg_temp.day(p_days integer) RETURNS date LANGUAGE sql AS $fn$
  SELECT ((now() AT TIME ZONE 'Asia/Manila')::date + p_days);
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.remember(text, uuid), pg_temp.recall(text), pg_temp.u(integer), pg_temp.act(text),
  pg_temp.item_for(uuid, text), pg_temp.se_for(uuid, text), pg_temp.set_id_of(uuid, integer), pg_temp.day(integer) TO authenticated;

-- Fixtures ------------------------------------------------------------------------------
--   01 Juan (athlete)        02 Coach A (Juan's current coach)   03 Former coach of Juan
--   04 Leader                05 Vice President                   06 Peer athlete (Manila)
--   07 Unassigned coach      08 LA athlete (another organization, America/Los_Angeles)
INSERT INTO auth.users (id, email, raw_user_meta_data) SELECT pg_temp.u(n)::uuid, 'u' || n || '@s6h.test', '{"full_name":"S6 History"}'::jsonb
  FROM generate_series(1, 8) n;
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'd6000000-0000-4000-8000-0000000000%';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT pg_temp.u(f.n)::uuid, pos.id FROM (VALUES
  (1, 'Athlete'), (2, 'Coach'), (3, 'Coach'), (4, 'Leader'), (5, 'Vice President'), (6, 'Athlete'), (7, 'Coach'), (8, 'Athlete')
) AS f(n, position_name) JOIN public.positions pos ON pos.name = f.position_name;

-- Juan's coaching history: the former coach's CLOSED window is [now-60d, now-30d); Coach A takes over then.
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at, ended_by) VALUES
  (pg_temp.u(1)::uuid, pg_temp.u(3)::uuid, pg_temp.u(5)::uuid, now() - interval '60 days', now() - interval '30 days', pg_temp.u(5)::uuid);
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at) VALUES
  (pg_temp.u(1)::uuid, pg_temp.u(2)::uuid, pg_temp.u(5)::uuid, now() - interval '30 days');

-- A second organization on a non-Manila timezone, holding the LA athlete.
INSERT INTO public.organizations (id, name, slug, timezone)
VALUES ('d6000000-0000-4000-8000-00000000f001', 'LA Club', 'la-club-s6', 'America/Los_Angeles');
INSERT INTO public.branches (id, organization_id, name, is_default)
VALUES ('d6000000-0000-4000-8000-00000000f101', 'd6000000-0000-4000-8000-00000000f001', 'LA Main', true);
UPDATE public.profiles SET home_branch_id = 'd6000000-0000-4000-8000-00000000f101' WHERE id = pg_temp.u(8)::uuid;

-- Juan's PRIVATE template: a prescription only Juan (its owner) may read through table RLS.
SELECT pg_temp.act(pg_temp.u(1));
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('tpl', (public.create_workout_template(
  'Juan Private Routine', NULL, 'private',
  jsonb_build_array(jsonb_build_object(
    'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 'measurement_mode', 'reps',
        'sets', jsonb_build_array(jsonb_build_object('target_reps', 10), jsonb_build_object('target_reps', 10))),
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'), 'measurement_mode', 'duration',
        'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 30))),
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'bodyweight-squat'), 'measurement_mode', 'reps',
        'sets', jsonb_build_array(jsonb_build_object('target_reps', 15), jsonb_build_object('target_reps', 15)))))
  )) ->> 'template_id')::uuid);
RESET ROLE;
SELECT pg_temp.remember('ver', id) FROM public.workout_versions WHERE template_id = pg_temp.recall('tpl');

-- Juan runs the session through the real RPCs: two substitutions (one MEDICAL, one operational),
-- a not-completed prescribed set, an unlogged prescribed set, an athlete-added extra set, and
-- ordinary + private feedback.
SELECT pg_temp.act(pg_temp.u(1));
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('s1', (public.start_workout_session(pg_temp.recall('ver'), gen_random_uuid()) ->> 'session_id')::uuid);
SELECT public.record_exercise_substitution(pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'plank'),
  (SELECT id FROM public.exercises WHERE slug = 'hollow-body-hold'), 'duration', 'pain_discomfort', gen_random_uuid());
SELECT public.record_exercise_substitution(pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'bodyweight-squat'),
  (SELECT id FROM public.exercises WHERE slug = 'walking-lunge'), 'reps', 'equipment_unavailable', gen_random_uuid());
-- push-up: set 1 done (paired), set 2 logged NOT completed (paired), set 3 an athlete-added extra.
SELECT public.record_session_set(pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'push-up'),
  jsonb_build_object('set_number', 1, 'actual_reps', 10, 'is_completed', true,
    'prescribed_item_set_id', pg_temp.set_id_of(pg_temp.item_for(pg_temp.recall('ver'), 'push-up'), 1)), gen_random_uuid());
SELECT public.record_session_set(pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'push-up'),
  jsonb_build_object('set_number', 2, 'is_completed', false,
    'prescribed_item_set_id', pg_temp.set_id_of(pg_temp.item_for(pg_temp.recall('ver'), 'push-up'), 2)), gen_random_uuid());
SELECT public.record_session_set(pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'push-up'),
  '{"set_number":3,"actual_reps":8,"is_completed":true}'::jsonb, gen_random_uuid());
-- plank → hollow body hold: its one prescribed set is paired.
SELECT public.record_session_set(pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'hollow-body-hold'),
  jsonb_build_object('set_number', 1, 'actual_duration_seconds', 30, 'is_completed', true,
    'prescribed_item_set_id', pg_temp.set_id_of(pg_temp.item_for(pg_temp.recall('ver'), 'plank'), 1)), gen_random_uuid());
-- squat → walking lunge: prescribed set 1 logged, prescribed set 2 NEVER logged.
SELECT public.record_session_set(pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'walking-lunge'),
  jsonb_build_object('set_number', 1, 'actual_reps', 12, 'is_completed', true,
    'prescribed_item_set_id', pg_temp.set_id_of(pg_temp.item_for(pg_temp.recall('ver'), 'bodyweight-squat'), 1)), gen_random_uuid());
SELECT public.complete_workout_session(pg_temp.recall('s1'), 'completed', NULL,
  '{"difficulty_rating":8,"energy_level":3}'::jsonb,
  '{"has_discomfort":true,"discomfort_area":"Left Shoulder","note_to_coach":"pinch at the top"}'::jsonb, gen_random_uuid());
RESET ROLE;

-- History fixtures inserted directly (fixed instants / states the RPCs cannot produce).
SELECT pg_temp.remember('s_old', gen_random_uuid());
INSERT INTO public.workout_sessions (id, athlete_id, workout_version_id, status, started_at, completed_at)
VALUES (pg_temp.recall('s_old'), pg_temp.u(1)::uuid, pg_temp.recall('ver'), 'completed',
        now() - interval '40 days', now() - interval '40 days' + interval '1 hour');
INSERT INTO public.session_feedback (session_id, difficulty_rating, energy_level) VALUES (pg_temp.recall('s_old'), 6, 4);
INSERT INTO public.session_private_feedback (session_id, has_discomfort, discomfort_area, note_to_coach)
VALUES (pg_temp.recall('s_old'), true, 'Wrist', 'sore wrist');
-- The same UTC instant for a Manila athlete (peer) and an LA athlete: 2026-03-15 20:00Z is
-- 2026-03-16 04:00 in Manila but 2026-03-15 13:00 in Los Angeles.
INSERT INTO public.workout_sessions (athlete_id, workout_version_id, status, started_at, completed_at) VALUES
  (pg_temp.u(6)::uuid, pg_temp.recall('ver'), 'completed', '2026-03-15 20:00:00+00', '2026-03-15 21:00:00+00'),
  (pg_temp.u(8)::uuid, pg_temp.recall('ver'), 'completed', '2026-03-15 20:00:00+00', '2026-03-15 21:00:00+00');

-- Juan's assigned occurrences: completed ×2, missed, partial (inside the default 30-day window),
-- one upcoming (never counted as due), and a completed one 40 days ago (inside the former coach's tenure).
INSERT INTO public.workout_assignments (id, organization_id, workout_template_id, workout_version_id, assigned_by, target_date, is_recurring)
SELECT gen_random_uuid(), '00000000-0000-4000-8000-000000000001', pg_temp.recall('tpl'), pg_temp.recall('ver'), pg_temp.u(2)::uuid,
       pg_temp.day(o.off), false
FROM (VALUES (-3), (-5), (-7), (-9), (2), (-40)) AS o(off);
INSERT INTO public.assignment_occurrences (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status, completed_at)
SELECT a.id, pg_temp.u(1)::uuid, pg_temp.recall('ver'), a.target_date,
       (a.target_date::timestamp AT TIME ZONE 'Asia/Manila'),
       ((a.target_date + 1)::timestamp AT TIME ZONE 'Asia/Manila'),
       CASE (a.target_date - pg_temp.day(0))
         WHEN -3 THEN 'completed' WHEN -5 THEN 'completed' WHEN -7 THEN 'missed'
         WHEN -9 THEN 'partially_completed' WHEN 2 THEN 'upcoming' ELSE 'completed' END,
       CASE WHEN (a.target_date - pg_temp.day(0)) IN (-3, -5, -9, -40)
            THEN (a.target_date::timestamp AT TIME ZONE 'Asia/Manila') + interval '1 hour' END
FROM public.workout_assignments a
WHERE a.workout_template_id = pg_temp.recall('tpl');

-- 1. Session replay: prescribed vs actual, set by set (F-S6-P11 / P12) ------------------------
SELECT is(
  jsonb_array_length((pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1'))) -> 'items'),
  3,
  'Juan''s replay lists all three prescribed items of the session''s sealed version'
);
SELECT is(
  pg_temp.sets_of(pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'push-up')),
  ARRAY['1:false:false', '2:true:false', '3:false:true'],
  'push-up: set 1 paired and done, set 2 paired but NOT completed (is_skipped), set 3 athlete-added (is_extra)'
);
SELECT is(
  pg_temp.sets_of(pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'bodyweight-squat')),
  ARRAY['1:false:false', '2:true:false'],
  'squat: a prescribed set that was NEVER logged still appears (FULL OUTER JOIN) and is is_skipped'
);
SELECT is(
  (SELECT s ->> 'session_set_id' FROM jsonb_array_elements(
     pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'bodyweight-squat') -> 'sets') s
   WHERE s ->> 'set_number' = '2'),
  NULL,
  'the unlogged prescribed set carries no session_set_id'
);
SELECT is(
  (SELECT ARRAY[s ->> 'target_reps', s ->> 'actual_reps', s ->> 'prescribed_item_set_id']
   FROM jsonb_array_elements(pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'push-up') -> 'sets') s
   WHERE s ->> 'set_number' = '1'),
  ARRAY['10', '10', pg_temp.set_id_of(pg_temp.item_for(pg_temp.recall('ver'), 'push-up'), 1)::text],
  'a paired set carries the prescription (target 10) beside the actual (10), joined on prescribed_item_set_id'
);
SELECT is(
  (SELECT ARRAY[s ->> 'target_reps', s ->> 'actual_reps', s ->> 'prescribed_item_set_id']
   FROM jsonb_array_elements(pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'push-up') -> 'sets') s
   WHERE s ->> 'set_number' = '3'),
  ARRAY[NULL, '8', NULL],
  'the extra set has no prescription (Rule B: prescribed_item_set_id may be null) and keeps its actual reps'
);
SELECT is(
  (SELECT ARRAY[i ->> 'prescribed_exercise_name', i ->> 'performed_exercise_name', i ->> 'is_substituted']
   FROM (SELECT pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'plank') AS i) x),
  ARRAY[(SELECT name FROM public.exercises WHERE slug = 'plank'), (SELECT name FROM public.exercises WHERE slug = 'hollow-body-hold'), 'true'],
  'a substituted item shows BOTH the prescribed exercise and the one actually performed (lineage preserved)'
);
SELECT is(
  (SELECT ARRAY[s ->> 'target_duration_seconds', s ->> 'actual_duration_seconds']
   FROM jsonb_array_elements(pg_temp.item(pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')), 'plank') -> 'sets') s),
  ARRAY['30', '30'],
  'the substituted exercise''s set is still paired with the ORIGINAL item''s prescription'
);
SELECT is(
  jsonb_array_length((pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1'))) -> 'substitutions'),
  2,
  'the athlete sees both substitutions (operational and medical)'
);
SELECT is(
  (SELECT ARRAY[r #>> '{private_feedback,discomfort_area}', r #>> '{feedback,difficulty_rating}']
   FROM (SELECT pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')) AS r) x),
  ARRAY['Left Shoulder', '8'],
  'the athlete sees their own private feedback and ordinary feedback'
);
SELECT is(
  (SELECT r #>> '{session,status}' FROM (SELECT pg_temp.replay(pg_temp.u(1), pg_temp.recall('s1')) AS r) x),
  'completed',
  'the replay header carries the session''s explicit status (never derived)'
);

-- 2. F-S6-P02: replay reads a PRIVATE template's prescription for viewers who cannot read the template.
--    A private template is readable only by its creator, the creator's CURRENT primary coach, and
--    workouts:manage_org holders (VP/President) — so a Leader and a FORMER coach get nothing from
--    table RLS, yet both may legitimately review the athlete's session.
SELECT is(
  ARRAY[
    pg_temp.as_bigint(pg_temp.u(4), format('SELECT count(*) FROM public.workout_versions WHERE id = %L', pg_temp.recall('ver'))),
    pg_temp.as_bigint(pg_temp.u(3), format('SELECT count(*) FROM public.workout_versions WHERE id = %L', pg_temp.recall('ver')))
  ],
  ARRAY[0, 0]::bigint[],
  'F-S6-P02 setup: a Leader and a FORMER coach cannot read Juan''s private template version through table RLS'
);
SELECT is(
  ARRAY[
    pg_temp.as_bigint(pg_temp.u(4), format(
      'SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id
         JOIN public.workout_blocks b ON b.id = i.block_id WHERE b.workout_version_id = %L', pg_temp.recall('ver'))),
    pg_temp.as_bigint(pg_temp.u(3), format(
      'SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id
         JOIN public.workout_blocks b ON b.id = i.block_id WHERE b.workout_version_id = %L', pg_temp.recall('ver')))
  ],
  ARRAY[0, 0]::bigint[],
  'F-S6-P02 setup: ...nor its prescribed sets'
);
SELECT is(
  pg_temp.sets_of(pg_temp.item(pg_temp.replay(pg_temp.u(3), pg_temp.recall('s_old')), 'push-up')),
  ARRAY['1:true:false', '2:true:false'],
  'F-S6-P02: ...yet the former coach''s replay of a session inside their tenure returns the prescribed sets (unperformed ones flagged is_skipped)'
);
SELECT is(
  (SELECT s ->> 'target_reps' FROM jsonb_array_elements(
     pg_temp.item(pg_temp.replay(pg_temp.u(4), pg_temp.recall('s1')), 'push-up') -> 'sets') s WHERE s ->> 'set_number' = '1'),
  '10',
  'F-S6-P02: ...and the Leader''s replay of the athlete''s session carries the private template''s prescribed target (10 reps)'
);
SELECT is(
  (SELECT ARRAY[r #>> '{private_feedback,discomfort_area}', jsonb_array_length(r -> 'substitutions')::text]
   FROM (SELECT pg_temp.replay(pg_temp.u(2), pg_temp.recall('s1')) AS r) x),
  ARRAY['Left Shoulder', '2'],
  'the current primary coach sees private feedback and the medical substitution'
);

-- 3. Rule E: redaction for viewers who may not see sensitive data -----------------------------
SELECT is(
  (SELECT r -> 'private_feedback' FROM (SELECT pg_temp.replay(pg_temp.u(4), pg_temp.recall('s1')) AS r) x),
  'null'::jsonb,
  'Rule E: a Leader''s replay has NO private feedback (null)'
);
SELECT is(
  (SELECT ARRAY[jsonb_array_length(r -> 'substitutions')::text, r #>> '{substitutions,0,reason_code}', r #>> '{feedback,difficulty_rating}']
   FROM (SELECT pg_temp.replay(pg_temp.u(4), pg_temp.recall('s1')) AS r) x),
  ARRAY['1', 'equipment_unavailable', '8'],
  'Rule E: a Leader sees the operational substitution and ordinary feedback, but the pain_discomfort substitution row is omitted'
);
SELECT is(
  pg_temp.sets_of(pg_temp.item(pg_temp.replay(pg_temp.u(4), pg_temp.recall('s1')), 'push-up')),
  ARRAY['1:false:false', '2:true:false', '3:false:true'],
  'a Leader still sees the workout sets themselves (organization-wide training visibility)'
);
SELECT is(
  pg_temp.as_bigint(pg_temp.u(4), 'SELECT count(*) FROM public.session_private_feedback'),
  0::bigint,
  'Rule E: a Leader reads 0 rows of session_private_feedback directly'
);
SELECT is(
  (SELECT ARRAY[r #>> '{private_feedback,discomfort_area}', jsonb_array_length(r -> 'substitutions')::text]
   FROM (SELECT pg_temp.replay(pg_temp.u(5), pg_temp.recall('s1')) AS r) x),
  ARRAY['Left Shoulder', '2'],
  'a Vice President (training:view_private_feedback) sees private feedback and both substitutions'
);
SELECT is(
  (SELECT ARRAY[r #>> '{session,id}', (r -> 'private_feedback')::text, r #>> '{feedback,difficulty_rating}']
   FROM (SELECT pg_temp.replay(pg_temp.u(3), pg_temp.recall('s_old')) AS r) x),
  ARRAY[pg_temp.recall('s_old')::text, 'null', '6'],
  'a FORMER coach can replay a session inside their tenure, but private feedback is redacted (current coach only)'
);

-- 4. Replay authorization: everyone else fails closed ---------------------------------------
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(3), format('SELECT public.get_session_replay(%L)', pg_temp.recall('s1'))),
    pg_temp.as_sqlstate(pg_temp.u(6), format('SELECT public.get_session_replay(%L)', pg_temp.recall('s1'))),
    pg_temp.as_sqlstate(pg_temp.u(7), format('SELECT public.get_session_replay(%L)', pg_temp.recall('s1'))),
    pg_temp.as_sqlstate(pg_temp.u(8), format('SELECT public.get_session_replay(%L)', pg_temp.recall('s1'))),
    pg_temp.as_sqlstate(pg_temp.u(1), 'SELECT public.get_session_replay(NULL)'),
    pg_temp.as_sqlstate(pg_temp.u(1), format('SELECT public.get_session_replay(%L)', gen_random_uuid()))
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501'],
  'replay is refused (42501) for a former coach outside tenure, a peer, an unassigned coach, another organization, NULL and an unknown id'
);

-- 5. Calendar read model: sessions and occurrences under RLS --------------------------------
SELECT is(
  ARRAY[
    pg_temp.as_bigint(pg_temp.u(1), 'SELECT count(*) FROM public.workout_sessions'),
    pg_temp.as_bigint(pg_temp.u(2), 'SELECT count(*) FROM public.workout_sessions'),
    pg_temp.as_bigint(pg_temp.u(3), 'SELECT count(*) FROM public.workout_sessions'),
    pg_temp.as_bigint(pg_temp.u(4), 'SELECT count(*) FROM public.workout_sessions'),
    pg_temp.as_bigint(pg_temp.u(6), 'SELECT count(*) FROM public.workout_sessions'),
    pg_temp.as_bigint(pg_temp.u(7), 'SELECT count(*) FROM public.workout_sessions'),
    pg_temp.as_bigint(pg_temp.u(8), 'SELECT count(*) FROM public.workout_sessions')
  ],
  ARRAY[2, 2, 1, 3, 1, 0, 1]::bigint[],
  'sessions visible: Juan 2, current coach 2, FORMER coach only the one inside tenure (1), Leader the Manila organization (3), peer own (1), unassigned coach 0, LA athlete own (1)'
);
SELECT is(
  ARRAY[
    pg_temp.as_bigint(pg_temp.u(1), 'SELECT count(*) FROM public.assignment_occurrences'),
    pg_temp.as_bigint(pg_temp.u(2), 'SELECT count(*) FROM public.assignment_occurrences'),
    pg_temp.as_bigint(pg_temp.u(3), 'SELECT count(*) FROM public.assignment_occurrences'),
    pg_temp.as_bigint(pg_temp.u(4), 'SELECT count(*) FROM public.assignment_occurrences'),
    pg_temp.as_bigint(pg_temp.u(6), 'SELECT count(*) FROM public.assignment_occurrences'),
    pg_temp.as_bigint(pg_temp.u(7), 'SELECT count(*) FROM public.assignment_occurrences')
  ],
  ARRAY[6, 6, 1, 6, 0, 0]::bigint[],
  'occurrences visible: Juan 6, current coach 6, FORMER coach only the one scheduled inside tenure (1), Leader 6, peer 0, unassigned coach 0'
);
SELECT is(
  pg_temp.as_bigint(pg_temp.u(3), format('SELECT count(*) FROM public.workout_sessions WHERE id = %L', pg_temp.recall('s1'))),
  0::bigint,
  'a former coach reads 0 rows for a session that started AFTER their tenure ended'
);

-- 6. Summary metrics: adherence math and volume ---------------------------------------------
SELECT is(
  (SELECT ARRAY[s ->> 'scheduled_workouts', s ->> 'completed_workouts', s ->> 'partially_completed_workouts',
                s ->> 'missed_workouts', s ->> 'abandoned_workouts', s ->> 'adherence_rate']
   FROM (SELECT pg_temp.summary(pg_temp.u(1)) AS s) x),
  ARRAY['4', '2', '1', '1', '0', '50.0'],
  'Juan''s default 30-day window: 4 due (2 completed, 1 partial, 1 missed) → adherence 2/4 = 50.0; the upcoming occurrence is not due'
);
SELECT is(
  (SELECT ARRAY[s ->> 'scheduled_workouts', s ->> 'adherence_rate']
   FROM (SELECT pg_temp.summary(pg_temp.u(1), pg_temp.day(-45), pg_temp.day(0)) AS s) x),
  ARRAY['5', '60.0'],
  'an explicit window reaching back 45 days also counts the older completed occurrence: 3/5 = 60.0'
);
SELECT is(
  (SELECT ARRAY[s ->> 'total_sessions_completed', s ->> 'total_completed_sets', s ->> 'total_reps', s ->> 'total_duration_seconds']
   FROM (SELECT pg_temp.summary(pg_temp.u(1)) AS s) x),
  ARRAY['1', '4', '30', '30'],
  'volume counts only completed sets of completed sessions: 4 sets, 10+8+12 = 30 reps, 30 s hold (the not-completed set is excluded)'
);
SELECT is(
  (SELECT s -> 'volume_by_category' FROM (SELECT pg_temp.summary(pg_temp.u(1)) AS s) x),
  '[{"category":"push","sets":2,"reps":18,"duration_seconds":0},
    {"category":"core","sets":1,"reps":0,"duration_seconds":30},
    {"category":"legs","sets":1,"reps":12,"duration_seconds":0}]'::jsonb,
  'volume is grouped by the PERFORMED exercise category (the substituted plank counts as core via hollow body hold, squat as legs via lunge)'
);
SELECT is(
  (SELECT ARRAY[s ->> 'scheduled_workouts', s ->> 'total_completed_sets']
   FROM (SELECT pg_temp.summary(pg_temp.u(1), pg_temp.day(-45), pg_temp.day(-35)) AS s) x),
  ARRAY['1', '0'],
  'the window bounds both occurrences and sessions (the 40-day-old session has no completed sets)'
);
SELECT is(
  (SELECT ARRAY[s ->> 'scheduled_workouts', (s -> 'adherence_rate')::text, s ->> 'total_completed_sets', (s -> 'volume_by_category')::text]
   FROM (SELECT pg_temp.summary(pg_temp.u(6)) AS s) x),
  ARRAY['0', 'null', '0', '[]'],
  'zero scheduled workouts: adherence_rate is NULL (never a division by zero), volume is empty'
);
SELECT is(
  ARRAY[pg_temp.as_sqlstate(pg_temp.u(1), format('SELECT public.get_my_athlete_summary(%L, %L)', pg_temp.day(0), pg_temp.day(-1))),
        pg_temp.as_sqlstate(pg_temp.u(1), format('SELECT public.get_my_athlete_summary(%L, %L)', pg_temp.day(-400), pg_temp.day(0))),
        pg_temp.as_sqlstate(pg_temp.u(1), format('SELECT public.get_my_athlete_summary(%L, %L)', pg_temp.day(-366), pg_temp.day(0)))],
  ARRAY['22023', '22023', 'ok'],
  'window validation: end before start → 22023; more than 366 days → 22023; exactly 366 days apart is allowed'
);
SELECT is(
  (SELECT ARRAY[s ->> 'window_start', s ->> 'window_end']
   FROM (SELECT pg_temp.summary(pg_temp.u(1), NULL, pg_temp.day(-10)) AS s) x),
  ARRAY[pg_temp.day(-39)::text, pg_temp.day(-10)::text],
  'with only an end date the default window is the 30 calendar days ENDING there'
);

-- 7. Dynamic organization timezone (F-S6-P08) -------------------------------------------------
SELECT is(
  (SELECT ARRAY[s ->> 'timezone', s ->> 'total_sessions_completed']
   FROM (SELECT pg_temp.summary(pg_temp.u(8), '2026-03-15', '2026-03-15') AS s) x),
  ARRAY['America/Los_Angeles', '1'],
  'F-S6-P08: the LA athlete''s 20:00Z session falls on 2026-03-15 in the organization''s own timezone'
);
SELECT is(
  (SELECT s ->> 'total_sessions_completed' FROM (SELECT pg_temp.summary(pg_temp.u(8), '2026-03-16', '2026-03-16') AS s) x),
  '0',
  'F-S6-P08: ...and NOT on 2026-03-16'
);
SELECT is(
  (SELECT ARRAY[s ->> 'timezone', s ->> 'total_sessions_completed']
   FROM (SELECT pg_temp.summary(pg_temp.u(6), '2026-03-15', '2026-03-15') AS s) x),
  ARRAY['Asia/Manila', '0'],
  'F-S6-P08: the SAME instant is NOT on 2026-03-15 for the Manila athlete'
);
SELECT is(
  (SELECT s ->> 'total_sessions_completed' FROM (SELECT pg_temp.summary(pg_temp.u(6), '2026-03-16', '2026-03-16') AS s) x),
  '1',
  'F-S6-P08: ...it is on 2026-03-16 in Manila (a hard-coded Asia/Manila would have mis-dated the LA athlete)'
);

-- 8. get_athlete_summary authorization ------------------------------------------------------
SELECT is(
  (SELECT ARRAY[
     public_summary ->> 'adherence_rate']
   FROM (SELECT pg_temp.as_jsonb(pg_temp.u(2), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))) AS public_summary) x),
  ARRAY['50.0'],
  'the current primary coach reads their athlete''s summary'
);
SELECT is(
  ARRAY[
    pg_temp.as_jsonb(pg_temp.u(4), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))) ->> 'adherence_rate',
    pg_temp.as_jsonb(pg_temp.u(5), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))) ->> 'adherence_rate',
    pg_temp.as_jsonb(pg_temp.u(1), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))) ->> 'adherence_rate'
  ],
  ARRAY['50.0', '50.0', '50.0'],
  'a Leader (training:view_org), a Vice President and the athlete themself can read the summary'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(3), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))),
    pg_temp.as_sqlstate(pg_temp.u(7), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))),
    pg_temp.as_sqlstate(pg_temp.u(6), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))),
    pg_temp.as_sqlstate(pg_temp.u(8), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1))),
    pg_temp.as_sqlstate(pg_temp.u(2), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(6)))
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'D2: a FORMER coach is denied the lifetime summary (42501), as are an unassigned coach, a peer, another organization, and a coach for a non-assigned athlete'
);
SELECT is(
  pg_temp.as_sqlstate(pg_temp.u(6), format('SELECT app_private.get_athlete_summary_metrics(%L, NULL, NULL)', pg_temp.u(1))),
  '42501',
  'defense in depth: calling the private delegate directly cannot read another athlete''s aggregates'
);

-- 9. F-S6-P15 privilege delegation ------------------------------------------------------------
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(NULL, format('SELECT public.get_session_replay(%L)', pg_temp.recall('s1'))),
    pg_temp.as_sqlstate(NULL, 'SELECT public.get_my_athlete_summary()'),
    pg_temp.as_sqlstate(NULL, format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1)))
  ],
  ARRAY['42501', '42501', '42501'],
  'F-S6-P15: anon is denied (42501) on every public history RPC'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(1), format('SELECT public.get_session_replay(%L)', pg_temp.recall('s1'))),
    pg_temp.as_sqlstate(pg_temp.u(1), 'SELECT public.get_my_athlete_summary()'),
    pg_temp.as_sqlstate(pg_temp.u(1), format('SELECT public.get_athlete_summary(%L)', pg_temp.u(1)))
  ],
  ARRAY['ok', 'ok', 'ok'],
  'F-S6-P15: the same three RPCs execute successfully as authenticated (the SECURITY INVOKER wrapper reaches the delegate with the caller''s grants)'
);
SELECT is(
  (SELECT array_agg(has_function_privilege(r, f, 'EXECUTE') ORDER BY r, f)
   FROM unnest(ARRAY['anon', 'authenticated']) r,
        unnest(ARRAY['app_private.get_session_replay_internal(uuid)',
                     'app_private.get_athlete_summary_metrics(uuid, date, date)']) f),
  ARRAY[false, false, true, true],
  'F-S6-P15: the private delegates are executable by authenticated and NOT by anon'
);
SELECT is(
  (SELECT array_agg(has_function_privilege(r, f, 'EXECUTE') ORDER BY r, f)
   FROM unnest(ARRAY['anon', 'authenticated', 'public']) r,
        unnest(ARRAY['public.get_session_replay(uuid)', 'public.get_my_athlete_summary(date, date)',
                     'public.get_athlete_summary(uuid, date, date)']) f
   WHERE r <> 'public'),
  ARRAY[false, false, false, true, true, true],
  'F-S6-P15: the public wrappers are executable by authenticated and NOT by anon'
);
SELECT is(
  (SELECT array_agg(p.prosecdef ORDER BY p.proname) FROM pg_proc p
   WHERE p.oid IN ('public.get_session_replay(uuid)'::regprocedure, 'public.get_my_athlete_summary(date, date)'::regprocedure,
                   'public.get_athlete_summary(uuid, date, date)'::regprocedure)),
  ARRAY[false, false, false],
  'F-S6-P15: every public history wrapper is SECURITY INVOKER'
);
SELECT is(
  (SELECT array_agg(p.prosecdef AND p.proconfig @> ARRAY['search_path=""'] ORDER BY p.proname) FROM pg_proc p
   WHERE p.oid IN ('app_private.get_session_replay_internal(uuid)'::regprocedure,
                   'app_private.get_athlete_summary_metrics(uuid, date, date)'::regprocedure)),
  ARRAY[true, true],
  'the private delegates are SECURITY DEFINER with search_path pinned to the empty string'
);
SELECT is(
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'app_private' AND p.proname IN ('get_session_replay_internal', 'get_athlete_summary_metrics')
     AND position('block_id = wb.id' in p.prosrc) > 0),
  1::bigint,
  'F-S6-P11: the replay joins workout_items on block_id = wb.id (not the non-existent workout_block_id)'
);

SELECT * FROM finish();
ROLLBACK;
