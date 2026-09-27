-- Sprint 3 · Task 3.11 — atomic creation with mode validation, versioning, D5
-- temporal authority (demoted coach, moved creator), visibility promotion,
-- deep cloning, and the historical-version safety matrix.
-- Concurrency itself (two real sessions) is proven by scripts/e2e/sprint3-slices.mjs
-- on the hosted project; here the serialization statements are asserted structurally.
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(77);

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
CREATE FUNCTION pg_temp.bx(p text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r record; t text := p;
BEGIN
  FOR r IN SELECT slug, id FROM public.exercises WHERE status = 'approved' LOOP
    t := replace(t, '"exercise":"' || r.slug || '"', '"exercise_id":"' || r.id || '"');
  END LOOP;
  RETURN t::jsonb;
END;
$fn$;
-- One block, one item, one set: for the mode-rule matrix.
CREATE FUNCTION pg_temp.one(p_slug text, p_mode text, p_set text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('title', 't', 'block_type', 'standard_set', 'items', jsonb_build_array(
    jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = p_slug AND status = 'approved'),
                       'measurement_mode', p_mode, 'sets', jsonb_build_array(p_set::jsonb)))));
$fn$;
-- One block of the given type with one item per element of p_item_set_counts, each item
-- holding that many reps-mode 'push-up' sets. For the F-S3-03/F-S3-04 limit matrix.
CREATE FUNCTION pg_temp.block_with_items(p_block_type text, p_circuit_rounds integer, p_item_set_counts integer[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_push_up uuid := (SELECT id FROM public.exercises WHERE slug = 'push-up' AND status = 'approved');
  v_items jsonb := '[]'::jsonb;
  v_count integer;
BEGIN
  FOREACH v_count IN ARRAY p_item_set_counts LOOP
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'exercise_id', v_push_up, 'measurement_mode', 'reps',
      'sets', (SELECT jsonb_agg(jsonb_build_object('target_reps', 5)) FROM generate_series(1, v_count))
    ));
  END LOOP;
  RETURN jsonb_build_array(jsonb_build_object(
    'title', 't', 'block_type', p_block_type, 'circuit_rounds', p_circuit_rounds, 'items', v_items
  ));
END;
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
-- Canonical text signature of one version's whole prescription, for deep-copy equality.
CREATE FUNCTION pg_temp.sig(p_tpl uuid, p_ver integer) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT string_agg(concat_ws('|', b.order_in_workout, b.title, b.block_type,
           coalesce(b.circuit_rounds::text, ''), coalesce(b.amrap_duration_seconds::text, ''),
           i.order_in_block, i.exercise_id, i.measurement_mode, s.set_number,
           coalesce(s.target_reps::text, ''), coalesce(s.target_duration_seconds::text, ''),
           coalesce(s.target_distance_meters::text, ''), coalesce(s.target_load_kg::text, ''),
           coalesce(s.load_type, ''), coalesce(s.target_rest_seconds::text, ''),
           coalesce(s.target_rpe::text, ''), coalesce(s.notes, '')),
         ';' ORDER BY b.order_in_workout, i.order_in_block, s.set_number)
  FROM public.workout_versions v
  JOIN public.workout_blocks b ON b.workout_version_id = v.id
  JOIN public.workout_items i ON i.block_id = b.id
  JOIN public.workout_item_sets s ON s.workout_item_id = i.id
  WHERE v.template_id = p_tpl AND v.version_number = p_ver;
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.act(text), pg_temp.bx(text), pg_temp.one(text, text, text),
  pg_temp.block_with_items(text, integer, integer[]),
  pg_temp.remember(text, uuid), pg_temp.recall(text), pg_temp.sig(uuid, integer) TO authenticated;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete A · …02 Coach (A's current coach) · …03 VP · …04 President
--   …05 Mover coach (Org A → Org B) · …06 Coach (demoted later) · …07 Athlete B
--   …08 Coach in Org B · …09 Leader · …0a Athlete C · …0b other Coach
INSERT INTO public.organizations (id, name, slug)
VALUES ('d4000000-0000-4000-8000-0000000000f1', 'Club B', 'club-b-s3v-test');
INSERT INTO public.branches (id, organization_id, name)
VALUES ('d4000000-0000-4000-8000-0000000000f2', 'd4000000-0000-4000-8000-0000000000f1', 'Club B Branch');

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('d4000000-0000-4000-8000-000000000001', 'athlete.a@s3v.test', '{"full_name":"Athlete A"}'),
  ('d4000000-0000-4000-8000-000000000002', 'coach@s3v.test', '{"full_name":"Coach"}'),
  ('d4000000-0000-4000-8000-000000000003', 'vp@s3v.test', '{"full_name":"VP"}'),
  ('d4000000-0000-4000-8000-000000000004', 'pres@s3v.test', '{"full_name":"President"}'),
  ('d4000000-0000-4000-8000-000000000005', 'mover@s3v.test', '{"full_name":"Mover"}'),
  ('d4000000-0000-4000-8000-000000000006', 'demoted@s3v.test', '{"full_name":"Soon Demoted"}'),
  ('d4000000-0000-4000-8000-000000000007', 'athlete.b@s3v.test', '{"full_name":"Athlete B"}'),
  ('d4000000-0000-4000-8000-000000000008', 'coach.b@s3v.test', '{"full_name":"Coach B"}'),
  ('d4000000-0000-4000-8000-000000000009', 'leader@s3v.test', '{"full_name":"Leader"}'),
  ('d4000000-0000-4000-8000-00000000000a', 'athlete.c@s3v.test', '{"full_name":"Athlete C"}'),
  ('d4000000-0000-4000-8000-00000000000b', 'coach.other@s3v.test', '{"full_name":"Other Coach"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'd4000000-0000-4000-8000-0000000000%';
UPDATE public.profiles SET home_branch_id = 'd4000000-0000-4000-8000-0000000000f2'
WHERE id = 'd4000000-0000-4000-8000-000000000008';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id
FROM (VALUES
  ('d4000000-0000-4000-8000-000000000001', 'Athlete'),
  ('d4000000-0000-4000-8000-000000000002', 'Coach'),
  ('d4000000-0000-4000-8000-000000000003', 'Vice President'),
  ('d4000000-0000-4000-8000-000000000004', 'President'),
  ('d4000000-0000-4000-8000-000000000005', 'Coach'),
  ('d4000000-0000-4000-8000-000000000006', 'Coach'),
  ('d4000000-0000-4000-8000-000000000007', 'Athlete'),
  ('d4000000-0000-4000-8000-000000000008', 'Coach'),
  ('d4000000-0000-4000-8000-000000000009', 'Leader'),
  ('d4000000-0000-4000-8000-00000000000a', 'Athlete'),
  ('d4000000-0000-4000-8000-00000000000b', 'Coach')
) AS f(profile_id, position_name)
JOIN public.positions pos ON pos.name = f.position_name;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by)
VALUES ('d4000000-0000-4000-8000-000000000001', 'd4000000-0000-4000-8000-000000000002', 'd4000000-0000-4000-8000-000000000003');

-- Custom exercises: A's and C's private ones, and one APPROVED custom exercise of A's.
INSERT INTO public.exercises (id, name, slug, category, measurement_types, equipment_needed, created_by, status, is_official) VALUES
  ('d4000000-0000-4000-8000-0000000000c1', 'A Private Move', 'a-private-move', 'core', ARRAY['reps'], ARRAY['none'],
   'd4000000-0000-4000-8000-000000000001', 'private', false),
  ('d4000000-0000-4000-8000-0000000000c2', 'C Private Move', 'c-private-move', 'core', ARRAY['reps'], ARRAY['none'],
   'd4000000-0000-4000-8000-00000000000a', 'private', false),
  ('d4000000-0000-4000-8000-0000000000c3', 'A Approved Move', 'a-approved-move', 'core', ARRAY['reps'], ARRAY['none'],
   'd4000000-0000-4000-8000-000000000001', 'approved', true);

-- 1. Atomic creation: Slice 1 shape, audit trail ------------------------------------
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('slice1', (public.create_workout_template(
       '  Upper Body Calisthenics Strength  ', 'Pyramid + back-off', 'organization',
       pg_temp.bx('[
         {"title":"Primary Strength","block_type":"superset","items":[
           {"exercise":"pull-up","measurement_mode":"added_weight","sets":[
             {"target_reps":5,"target_load_kg":10.00,"load_type":"added","target_rest_seconds":120,"target_rpe":7.5},
             {"target_reps":3,"target_load_kg":15.00,"load_type":"added","target_rest_seconds":120,"target_rpe":8.5},
             {"target_reps":1,"target_load_kg":20.00,"load_type":"added","target_rest_seconds":180,"target_rpe":9.5}]},
           {"exercise":"parallel-bar-dip","measurement_mode":"added_weight","sets":[
             {"target_reps":5,"target_load_kg":15.00,"load_type":"added","target_rest_seconds":120},
             {"target_reps":5,"target_load_kg":15.00,"load_type":"added","target_rest_seconds":120},
             {"target_reps":8,"target_load_kg":10.00,"load_type":"added","target_rest_seconds":120,"notes":"back-off set"}]}]},
         {"title":"Core Finisher","block_type":"amrap","amrap_duration_seconds":420,"items":[
           {"exercise":"hanging-leg-raise","measurement_mode":"reps","sets":[{"target_reps":10}]}]}
       ]')) ->> 'template_id')::uuid) $$,
  'Coach creates the Slice 1 routine (name trimmed, pyramid and back-off sets, AMRAP finisher)'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[t.name, t.visibility, t.organization_id::text, t.created_by::text]
   FROM public.workout_templates t WHERE t.id = pg_temp.recall('slice1')),
  ARRAY['Upper Body Calisthenics Strength', 'organization', '00000000-0000-4000-8000-000000000001',
        'd4000000-0000-4000-8000-000000000002'],
  'the template is homed in the caller''s organization and owned by the caller'
);
SELECT is(
  (SELECT ARRAY[
     count(*) FILTER (WHERE s.set_number = 1 AND s.target_load_kg = 10.00 AND s.load_type = 'added' AND s.target_reps = 5 AND s.target_rest_seconds = 120 AND s.target_rpe = 7.5),
     count(*) FILTER (WHERE s.set_number = 3 AND s.target_load_kg = 20.00 AND s.target_reps = 1 AND s.target_rest_seconds = 180 AND s.target_rpe = 9.5),
     count(*) FILTER (WHERE s.notes = 'back-off set' AND s.target_reps = 8 AND s.target_load_kg = 10.00),
     count(*)]
   FROM public.workout_item_sets s
   JOIN public.workout_items i ON i.id = s.workout_item_id
   JOIN public.workout_blocks b ON b.id = i.block_id
   JOIN public.workout_versions v ON v.id = b.workout_version_id
   WHERE v.template_id = pg_temp.recall('slice1')),
  ARRAY[1::bigint, 1, 1, 7],
  'sets carry the exact pyramid and back-off targets (7 sets in total)'
);
SELECT is(
  (SELECT ARRAY[b.order_in_workout::text || b.block_type, b.amrap_duration_seconds::text]
   FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id
   WHERE v.template_id = pg_temp.recall('slice1') AND b.order_in_workout = 2),
  ARRAY['2amrap', '420'],
  'block 2 is the AMRAP finisher with a 420-second round timer'
);
SELECT is(
  (SELECT ARRAY[a.actor_type::text, (a.actor_user_id = 'd4000000-0000-4000-8000-000000000002')::text,
                a.new_values ->> 'visibility', a.new_values ->> 'version_number', a.new_values ->> 'blocks',
                a.new_values ->> 'items', a.new_values ->> 'sets']
   FROM public.audit_logs a
   WHERE a.entity_type = 'workout_template' AND a.entity_id = pg_temp.recall('slice1')::text AND a.action = 'created'),
  ARRAY['user', 'true', 'organization', '1', '2', '3', '7'],
  'creation appends one audit row (actor, visibility, version and counts)'
);

-- 2. Payload validation matrix: every rejection is 22023 and leaves nothing behind ---
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    -- structure
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', '[]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', '{"a":1}'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', NULL) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      (SELECT jsonb_agg(jsonb_build_object('title','b','block_type','standard_set','items','[]'::jsonb)) FROM generate_series(1, 21))) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"standard_set","items":[]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"nonsense","items":[]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":" ","block_type":"standard_set","items":[]}]'::jsonb) $$),
    -- block type consistency
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"amrap","items":[]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"amrap","amrap_duration_seconds":10,"items":[]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"circuit","items":[]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"superset","circuit_rounds":3,"items":[]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"standard_set","amrap_duration_seconds":300,"items":[]}]'::jsonb) $$),
    -- template fields
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('   ', NULL, 'private', '[]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'public', '[]'::jsonb) $$)
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023', '22023', '22023',
        '22023', '22023', '22023', '22023', '22023', '22023', '22023'],
  'invalid structure, block-type consistency and template fields are rejected with 22023'
);
SELECT is(
  ARRAY[
    -- exercise problems
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"not-a-uuid","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"11111111-1111-4111-8111-111111111111","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      pg_temp.one('push-up', 'holds', '{"target_duration_seconds":30}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      pg_temp.one('push-up', 'amrap', '{"target_reps":30}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c2","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private',
      '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c1","measurement_mode":"reps","sets":[]}]}]'::jsonb) $$)
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023', '22023'],
  'bad/unknown ids, unsupported or amrap modes, another member''s private exercise and empty set lists are rejected with 22023'
);
-- Mode-aware set rules.
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5,"target_load_kg":5,"load_type":"added"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5,"target_duration_seconds":30}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('hollow-body-hold', 'duration', '{"target_reps":5}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('hollow-body-hold', 'holds', '{"target_reps":5,"target_duration_seconds":30}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('walking-lunge', 'distance', '{"target_reps":10}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pull-up', 'added_weight', '{"target_reps":5}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pull-up', 'added_weight', '{"target_reps":5,"target_load_kg":10}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pull-up', 'added_weight', '{"target_reps":5,"target_load_kg":10,"load_type":"assisted"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pull-up', 'added_weight', '{"target_load_kg":10,"load_type":"added"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pull-up', 'added_weight', '{"target_reps":5,"target_load_kg":0,"load_type":"added"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pull-up', 'assisted_weight', '{"target_reps":5,"target_load_kg":10,"load_type":"added"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'until_failure', '{"target_distance_meters":10}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('pistol-squat', 'technique_practice', '{}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":1001}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5.5}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":"5"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5,"target_rpe":11}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('t', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5,"target_rest_seconds":1801}')) $$)
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023',
        '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023', '22023'],
  'mode-aware validation rejects every malformed reps / duration / holds / distance / added / assisted / failure / technique set'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m1', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":12}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m2', NULL, 'private', pg_temp.one('hollow-body-hold', 'duration', '{"target_duration_seconds":45}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m3', NULL, 'private', pg_temp.one('hollow-body-hold', 'holds', '{"target_duration_seconds":20,"target_rest_seconds":60}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m4', NULL, 'private', pg_temp.one('walking-lunge', 'distance', '{"target_distance_meters":25.5}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m5', NULL, 'private', pg_temp.one('pull-up', 'added_weight', '{"target_duration_seconds":10,"target_load_kg":5,"load_type":"added"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m6', NULL, 'private', pg_temp.one('pull-up', 'assisted_weight', '{"target_reps":6,"target_load_kg":20,"load_type":"assisted"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m7', NULL, 'private', pg_temp.one('push-up', 'until_failure', '{}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m8', NULL, 'private', pg_temp.one('push-up', 'until_failure', '{"target_load_kg":5,"load_type":"added","target_duration_seconds":90}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m9', NULL, 'private', pg_temp.one('pistol-squat', 'technique_practice', '{"notes":"box pistols, slow tempo"}')) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('m10', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5,"load_type":"bodyweight"}')) $$)
  ],
  ARRAY['ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok'],
  'every measurement mode accepts its own well-formed set (including bodyweight, until_failure and notes-only technique work)'
);
-- F-S3-03 / F-S3-04 (reviewer gate rework): item/set/total-set limits and
-- compound-block minimum cardinality. Every over-limit payload here is
-- otherwise well-formed (single approved exercise, valid reps sets), so the
-- rejection isolates exactly the limit or cardinality rule under test.
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim1', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('standard_set', NULL, array_fill(1, ARRAY[16])))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim2', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('standard_set', NULL, ARRAY[31]))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim3', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('standard_set', NULL, ARRAY[30, 30, 30, 30, 30, 1]))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim4', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('superset', NULL, ARRAY[5]))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim5', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('circuit', 2, ARRAY[5])))
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023'],
  'F-S3-03/F-S3-04: 16 items/block, 31 sets/item, 151 total sets, a 1-item superset and a 1-item circuit are all rejected with 22023'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim6', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('standard_set', NULL, array_fill(1, ARRAY[15])))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim7', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('standard_set', NULL, ARRAY[30]))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim8', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('standard_set', NULL, ARRAY[30, 30, 30, 30, 30]))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim9', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('superset', NULL, ARRAY[5, 5]))),
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('lim10', NULL, 'private', %L::jsonb) $$,
      pg_temp.block_with_items('circuit', 2, ARRAY[5, 5])))
  ],
  ARRAY['ok', 'ok', 'ok', 'ok', 'ok'],
  'F-S3-03/F-S3-04 boundaries remain valid: exactly 15 items/block, 30 sets/item, 150 total sets, a 2-item superset and a 2-item circuit'
);

-- Atomicity: the first block is valid, the second is not → nothing at all is stored.
SELECT is(
  pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Atomic probe', NULL, 'private',
    pg_temp.bx('[{"title":"ok","block_type":"standard_set","items":[{"exercise":"push-up","measurement_mode":"reps","sets":[{"target_reps":5}]}]},
                 {"title":"bad","block_type":"standard_set","items":[{"exercise":"push-up","measurement_mode":"reps","sets":[{"target_reps":5,"target_rpe":99}]}]}]')) $$),
  '22023',
  'a payload that fails in its second block is rejected'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.workout_templates WHERE name = 'Atomic probe'),
     (SELECT count(*) FROM public.workout_blocks WHERE title IN ('ok', 'bad')),
     (SELECT count(*) FROM public.workout_versions WHERE created_by = 'd4000000-0000-4000-8000-000000000001' AND NOT is_sealed)]),
  ARRAY[0::bigint, 0, 0],
  'atomicity: no template, block or unsealed version survives a failed creation (all-or-nothing)'
);
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE created_by = 'd4000000-0000-4000-8000-000000000001'
     AND name IN ('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10') AND visibility = 'private'),
  10::bigint,
  'the ten valid mode payloads created ten private templates'
);

-- Organization templates take approved library exercises only.
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Org custom', NULL, 'organization',
      '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c1","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb) $$),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Org custom approved', NULL, 'organization',
      '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c3","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb) $$)
  ],
  ARRAY['22023', 'ok'],
  'an organization template rejects a private custom exercise but accepts an approved one'
);
RESET ROLE;

-- 3. Serialization statements are present (behaviour proven by the hosted probes) ----
SELECT ok(
  (SELECT prosrc ~* 'FROM public\.workout_templates WHERE id = p_template_id FOR UPDATE'
   FROM pg_proc WHERE oid = 'app_private.publish_new_workout_version_internal(uuid, text, jsonb)'::regprocedure)
  AND (SELECT prosrc ~* 'FROM public\.workout_templates WHERE id = p_source_template_id FOR SHARE'
       FROM pg_proc WHERE oid = 'app_private.clone_workout_template_internal(uuid, text, uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FROM public\.workout_templates WHERE id = p_template_id FOR UPDATE'
       FROM pg_proc WHERE oid = 'app_private.set_template_visibility_internal(uuid, text)'::regprocedure),
  'publish and visibility lock the parent template FOR UPDATE; clone locks its source FOR SHARE'
);

-- 4. Versioning: publish v2 / v3, v1 untouched ---------------------------------------
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT public.publish_new_workout_version(pg_temp.recall('slice1'), 'Lighter pyramid',
     pg_temp.bx('[{"title":"Primary Strength v2","block_type":"standard_set","items":[
       {"exercise":"pull-up","measurement_mode":"added_weight","sets":[{"target_reps":5,"target_load_kg":12.5,"load_type":"added"}]}]}]'))
   ->> 'version_number'),
  '2',
  'the creator publishes version 2'
);
SELECT is(
  (SELECT public.publish_new_workout_version(pg_temp.recall('slice1'), NULL,
     pg_temp.bx('[{"title":"v3","block_type":"standard_set","items":[{"exercise":"push-up","measurement_mode":"reps","sets":[{"target_reps":20}]}]}]'))
   ->> 'version_number'),
  '3',
  'a second publish continues the sequence (version 3)'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[count(*)::text, string_agg(version_number::text || is_sealed::text, ',' ORDER BY version_number),
                (SELECT notes FROM public.workout_versions WHERE template_id = pg_temp.recall('slice1') AND version_number = 2),
                (SELECT (notes IS NULL)::text FROM public.workout_versions WHERE template_id = pg_temp.recall('slice1') AND version_number = 3)]
   FROM public.workout_versions WHERE template_id = pg_temp.recall('slice1')),
  ARRAY['3', '1true,2true,3true', 'Lighter pyramid', 'true'],
  'three sealed versions exist; the changelog note is stored on the version'
);
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('slice1') AND v.version_number = 1),
     (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('slice1') AND v.version_number = 1),
     (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('slice1') AND v.version_number = 2)]),
  ARRAY[2::bigint, 7, 1],
  'version 1 is unchanged (2 blocks, 7 sets) while version 2 holds its own single set'
);
SELECT ok(
  pg_temp.sig(pg_temp.recall('slice1'), 1) LIKE '1|Primary Strength|superset|||1|%|added_weight|1|5|||10.00|added|120|7.5|;%',
  'version 1 keeps its original prescription after later versions were published'
);
SELECT is(
  (SELECT string_agg(a.action, ',' ORDER BY a.created_at)
   FROM public.audit_logs a WHERE a.entity_type = 'workout_template' AND a.entity_id = pg_temp.recall('slice1')::text),
  'created,version_published,version_published',
  'each publish appends a version_published audit event'
);

-- 5. D5 temporal authority: a demoted coach ---------------------------------------
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000006');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('demoted_org', (public.create_workout_template(
       'Demoted Coach Routine', NULL, 'organization',
       pg_temp.bx('[{"title":"Pull","block_type":"standard_set","items":[{"exercise":"pull-up","measurement_mode":"reps","sets":[{"target_reps":6}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'a Coach authors an organization template'
);
RESET ROLE;
-- The Coach position ends and the member becomes a plain Athlete.
UPDATE public.member_positions SET ended_at = now()
WHERE profile_id = 'd4000000-0000-4000-8000-000000000006'
  AND position_id = (SELECT id FROM public.positions WHERE name = 'Coach');
INSERT INTO public.member_positions (profile_id, position_id)
SELECT 'd4000000-0000-4000-8000-000000000006', id FROM public.positions WHERE name = 'Athlete';

SELECT pg_temp.act('d4000000-0000-4000-8000-000000000006');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, 'v2', pg_temp.one('push-up', 'reps', '{"target_reps":5}')) $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'Renamed', NULL) $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'private') $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Now an athlete', NULL, 'organization', pg_temp.one('push-up', 'reps', '{"target_reps":5}')) $$)
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'a creator demoted to Athlete can no longer publish, edit, archive, re-scope or author organization templates'
);
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('demoted_org')),
  1::bigint,
  'the demoted creator can still READ the organization template as a same-organization member'
);
SELECT is(
  pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Athlete private', NULL, 'private', pg_temp.one('push-up', 'reps', '{"target_reps":5}')) $$),
  'ok',
  'but may keep authoring private routines'
);
RESET ROLE;
-- Executives with workouts:manage_org keep maintenance authority.
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, 'Executive fix', pg_temp.one('pull-up', 'reps', '{"target_reps":7}')) $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'Renamed by VP', 'edited') $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, false) $$, pg_temp.recall('demoted_org')))
  ],
  ARRAY['ok', 'ok', 'ok', 'ok'],
  'a Vice President (workouts:manage_org) can publish, edit and archive another member''s organization template'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, '  ', NULL) $$, pg_temp.recall('demoted_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, %L, NULL) $$, pg_temp.recall('demoted_org'), repeat('x', 101))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, NULL) $$, pg_temp.recall('demoted_org')))
  ],
  ARRAY['22023', '22023', '22023'],
  'metadata and archive validate their inputs (22023)'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[name, description, is_archived::text] FROM public.workout_templates WHERE id = pg_temp.recall('demoted_org')),
  ARRAY['Renamed by VP', 'edited', 'false'],
  'the executive''s metadata edit and the archive round-trip were applied'
);
SELECT is(
  (SELECT string_agg(a.action, ',' ORDER BY a.created_at)
   FROM public.audit_logs a WHERE a.entity_type = 'workout_template' AND a.entity_id = pg_temp.recall('demoted_org')::text),
  'created,version_published,metadata_updated,archived,unarchived',
  'every executive maintenance action is audited'
);

-- 6. Private creator who moves organization ---------------------------------------
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('mover_priv', (public.create_workout_template(
       'Mover Private', 'old club', 'private',
       pg_temp.bx('[{"title":"Core","block_type":"standard_set","items":[{"exercise":"plank","measurement_mode":"duration","sets":[{"target_duration_seconds":60}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'the Mover creates a private routine in Organization A'
);
RESET ROLE;
UPDATE public.profiles SET home_branch_id = 'd4000000-0000-4000-8000-0000000000f2'
WHERE id = 'd4000000-0000-4000-8000-000000000005';
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000005');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('mover_priv')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('mover_priv')),
    (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('mover_priv'))
  ],
  ARRAY[1::bigint, 1, 1],
  'after moving to Organization B the creator still reads their private routine and its hierarchy'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, 'from the new club', pg_temp.one('plank', 'duration', '{"target_duration_seconds":90}')) $$, pg_temp.recall('mover_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'Mover Private (renamed)', NULL) $$, pg_temp.recall('mover_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('mover_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, false) $$, pg_temp.recall('mover_priv')))
  ],
  ARRAY['ok', 'ok', 'ok', 'ok'],
  'the creator keeps versioning, metadata editing and archiving of the private routine across organizations'
);
SELECT is(
  pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('mover_priv'))),
  '42501',
  'but cannot promote the old-organization routine into the new organization (clone first)'
);
SELECT lives_ok(
  format($$ SELECT pg_temp.remember('mover_clone', (public.clone_workout_template(%L, 'Mover Clone') ->> 'template_id')::uuid) $$,
         pg_temp.recall('mover_priv')),
  'cloning the routine works and homes the clone in the caller''s current organization'
);
SELECT is(
  pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('mover_clone'))),
  'ok',
  'the clone can be promoted in the new organization (Coach holds workouts:publish_org)'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[
     (SELECT organization_id::text FROM public.workout_templates WHERE id = pg_temp.recall('mover_priv')),
     (SELECT organization_id::text FROM public.workout_templates WHERE id = pg_temp.recall('mover_clone')),
     (SELECT visibility FROM public.workout_templates WHERE id = pg_temp.recall('mover_priv')),
     (SELECT visibility FROM public.workout_templates WHERE id = pg_temp.recall('mover_clone'))]),
  ARRAY['00000000-0000-4000-8000-000000000001', 'd4000000-0000-4000-8000-0000000000f1', 'private', 'organization'],
  'the original stays homed in Organization A (never silently re-homed); the clone is homed in Organization B'
);
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000008');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id IN (pg_temp.recall('mover_clone'), pg_temp.recall('mover_priv'))),
  1::bigint,
  'Organization B members see only the promoted clone, never the old-organization original'
);
RESET ROLE;

-- 7. Visibility transition matrix ---------------------------------------------------
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('coach_priv', (public.create_workout_template(
       'Coach Private Safe', NULL, 'private',
       pg_temp.bx('[{"title":"Pull","block_type":"standard_set","items":[{"exercise":"chin-up","measurement_mode":"reps","sets":[{"target_reps":6}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'the Coach creates a private routine of approved exercises'
);
-- A private routine whose V1 used a private exercise and whose V2 is clean.
SELECT lives_ok(
  $$ SELECT pg_temp.remember('coach_hist', (public.create_workout_template(
       'Coach Private History', NULL, 'private',
       '[{"title":"Mine","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c3","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb
     ) ->> 'template_id')::uuid) $$,
  'the Coach creates a private routine on someone else''s approved custom exercise (allowed: it is approved)'
);
RESET ROLE;
-- Privileged fixture: the approved custom exercise is withdrawn, so V1 of coach_hist is now unsafe.
UPDATE public.exercises SET status = 'private', is_official = false WHERE id = 'd4000000-0000-4000-8000-0000000000c3';
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($$ SELECT public.publish_new_workout_version(%L, 'clean up', pg_temp.bx('[{"title":"Pull","block_type":"standard_set","items":[{"exercise":"push-up","measurement_mode":"reps","sets":[{"target_reps":10}]}]}]')) $$,
         pg_temp.recall('coach_hist')),
  'the creator publishes a clean version 2'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('coach_hist'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('coach_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('coach_priv')))
  ],
  ARRAY['22023', 'ok', '55000'],
  'promotion scans EVERY version (22023 for a history containing an unapproved exercise), succeeds when clean, and is not repeatable (55000)'
);
RESET ROLE;
SELECT is(
  (SELECT visibility FROM public.workout_templates WHERE id = pg_temp.recall('coach_priv')),
  'organization',
  'the clean routine is now organization-visible'
);
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('a_priv', (public.create_workout_template(
       'A Private Safe', NULL, 'private',
       pg_temp.bx('[{"title":"Pull","block_type":"standard_set","items":[{"exercise":"pull-up","measurement_mode":"reps","sets":[{"target_reps":8}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'Athlete A creates a private routine'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('a_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'private') $$, pg_temp.recall('coach_priv')))
  ],
  ARRAY['42501', '42501'],
  'an Athlete cannot promote (no publish_org) and cannot demote someone else''s organization routine'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('a_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'Hijack', NULL) $$, pg_temp.recall('a_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('a_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, 'x', pg_temp.one('push-up', 'reps', '{"target_reps":5}')) $$, pg_temp.recall('a_priv')))
  ],
  ARRAY['42501', '42501', '42501', '42501'],
  'workouts:manage_org does not let an executive publish, edit, archive or expose another member''s PRIVATE routine'
);
SELECT is(
  pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'private') $$, pg_temp.recall('coach_priv'))),
  'ok',
  'a Vice President may demote another member''s organization routine back to private'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('coach_priv'))),
  'ok',
  'the creator (publish_org) may re-promote it'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-00000000000b');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'private') $$, pg_temp.recall('coach_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'Not mine', NULL) $$, pg_temp.recall('coach_priv'))),
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, 'x', pg_temp.one('push-up', 'reps', '{"target_reps":5}')) $$, pg_temp.recall('coach_priv')))
  ],
  ARRAY['42501', '42501', '42501'],
  'another Coach (publish_org, but not the creator and without manage_org) cannot alter the routine'
);
RESET ROLE;
SELECT is(
  (SELECT string_agg(a.action || ':' || COALESCE(a.old_values ->> 'visibility', '') || '>' || COALESCE(a.new_values ->> 'visibility', ''), ',' ORDER BY a.created_at)
   FROM public.audit_logs a
   WHERE a.entity_type = 'workout_template' AND a.entity_id = pg_temp.recall('coach_priv')::text AND a.action = 'visibility_changed'),
  'visibility_changed:private>organization,visibility_changed:organization>private,visibility_changed:private>organization',
  'every visibility change is audited with its before and after'
);

-- 8. Deep cloning --------------------------------------------------------------------
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000007');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($$ SELECT pg_temp.remember('slice1_clone', (public.clone_workout_template(%L, NULL) ->> 'template_id')::uuid) $$,
         pg_temp.recall('demoted_org')),
  'an Athlete clones an organization routine (default name)'
);
SELECT lives_ok(
  format($$ SELECT pg_temp.remember('slice1_named', (public.clone_workout_template(%L, '  My Pyramid  ') ->> 'template_id')::uuid) $$,
         pg_temp.recall('slice1')),
  'an Athlete clones the Slice 1 routine under a chosen name'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[t.visibility, t.created_by::text, t.organization_id::text, t.name,
                (SELECT count(*)::text FROM public.workout_versions v WHERE v.template_id = t.id AND v.is_sealed AND v.version_number = 1),
                (SELECT count(*)::text FROM public.workout_versions v WHERE v.template_id = t.id)]
   FROM public.workout_templates t WHERE t.id = pg_temp.recall('slice1_named')),
  ARRAY['private', 'd4000000-0000-4000-8000-000000000007', '00000000-0000-4000-8000-000000000001', 'My Pyramid', '1', '1'],
  'the clone is a new PRIVATE template owned by the caller, in their organization, with one sealed version 1'
);
SELECT is(
  pg_temp.sig(pg_temp.recall('slice1_named'), 1),
  pg_temp.sig(pg_temp.recall('slice1'), 3),
  'the clone is an exact deep copy of the LATEST sealed version (V3), not of version 1'
);
SELECT is(
  (SELECT ARRAY[
     (SELECT v.notes FROM public.workout_versions v WHERE v.template_id = pg_temp.recall('slice1_named')),
     (SELECT v.notes FROM public.workout_versions v WHERE v.template_id = pg_temp.recall('slice1_clone')),
     (SELECT name FROM public.workout_templates WHERE id = pg_temp.recall('slice1_clone'))]),
  ARRAY['Cloned from "Upper Body Calisthenics Strength" version 3', 'Cloned from "Renamed by VP" version 2', 'Renamed by VP (copy)'],
  'clone provenance is recorded in the version notes; the default name appends "(copy)"'
);
SELECT is(
  (SELECT string_agg(a.action, ',') FROM public.audit_logs a
   WHERE a.entity_type = 'workout_template' AND a.entity_id = pg_temp.recall('slice1_named')::text),
  'cloned',
  'cloning appends a cloned audit event'
);
-- The clone belongs to the cloner alone.
SELECT pg_temp.act('d4000000-0000-4000-8000-00000000000a');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id IN (pg_temp.recall('slice1_named'), pg_temp.recall('slice1_clone'))),
  0::bigint,
  'other members cannot see the private clone'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L) $$, pg_temp.recall('a_priv'))),
    pg_temp.sqlstate_of($$ SELECT public.clone_workout_template('11111111-1111-4111-8111-111111111111') $$)
  ],
  ARRAY['42501', 'P0002'],
  'cloning another member''s private routine is rejected (42501); a missing template is P0002'
);
RESET ROLE;
-- Defense in depth: an exercise inside a published routine stops being approved → clone rejected atomically.
UPDATE public.exercises SET status = 'approved', is_official = true WHERE id = 'd4000000-0000-4000-8000-0000000000c3';
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('org_with_custom', (public.create_workout_template(
       'Org With Approved Custom', NULL, 'organization',
       '[{"title":"b","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c3","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]'::jsonb
     ) ->> 'template_id')::uuid) $$,
  'an organization routine may use an approved custom exercise'
);
RESET ROLE;
UPDATE public.exercises SET status = 'private', is_official = false WHERE id = 'd4000000-0000-4000-8000-0000000000c3';
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000007');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L, 'Should not exist') $$, pg_temp.recall('org_with_custom'))),
  '42501',
  'a routine referencing another member''s now-private exercise cannot be cloned (42501)'
);
RESET ROLE;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE name = 'Should not exist'),
  0::bigint,
  'the rejected clone left nothing behind (atomic)'
);

-- 9. Historical version safety matrix (Acceptance Slice 2) -------------------------
UPDATE public.exercises SET status = 'approved', is_official = true WHERE id = 'd4000000-0000-4000-8000-0000000000c3';
-- Athlete A: V1 contains A's private exercise.
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('hist', (public.create_workout_template(
       'A History Routine', NULL, 'private',
       '[{"title":"Mine","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c1","measurement_mode":"reps","sets":[{"target_reps":12}]}]}]'::jsonb
     ) ->> 'template_id')::uuid) $$,
  'Slice 2 step 1: the athlete creates a private routine using an athlete-private exercise (V1)'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('hist')),
  0::bigint,
  'step 2: the assigned coach sees 0 rows (the latest sealed version V1 is unsafe)'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT public.publish_new_workout_version(pg_temp.recall('hist'), 'Now with official exercises',
     pg_temp.bx('[{"title":"Strength","block_type":"standard_set","items":[
       {"exercise":"pull-up","measurement_mode":"reps","sets":[{"target_reps":8}]},
       {"exercise":"parallel-bar-dip","measurement_mode":"reps","sets":[{"target_reps":8}]}]}]')) ->> 'version_number'),
  '2',
  'step 3: the athlete publishes version 2 with approved exercises'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('hist')),
     (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist') AND version_number = 2),
     (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist') AND version_number = 1),
     (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist') AND v.version_number = 2),
     (SELECT count(*) FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist') AND v.version_number = 2),
     (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist') AND v.version_number = 2),
     (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist') AND v.version_number = 1),
     (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist') AND v.version_number = 1)]),
  ARRAY[1::bigint, 1, 0, 1, 2, 2, 0, 0],
  'step 4: the coach now sees the routine; V2 and all its descendants are visible, V1 (unsafe) is completely inaccessible'
);
SELECT lives_ok(
  $$ SELECT pg_temp.remember('hist_clone', (public.clone_workout_template(pg_temp.recall('hist'), 'Coach copy') ->> 'template_id')::uuid) $$,
  'step 5: the coach clones while V2 is the latest safe version'
);
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.sig(pg_temp.recall('hist_clone'), 1), (SELECT (v.notes) FROM public.workout_versions v WHERE v.template_id = pg_temp.recall('hist_clone'))],
  ARRAY[pg_temp.sig(pg_temp.recall('hist'), 2), 'Cloned from "A History Routine" version 2'],
  'the clone copied VERSION 2 (pull-up + dip), not the unsafe version 1'
);
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT public.publish_new_workout_version(pg_temp.recall('hist'), 'Oops, custom again',
     '[{"title":"Mine","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c1","measurement_mode":"reps","sets":[{"target_reps":15}]}]}]'::jsonb) ->> 'version_number'),
  '3',
  'step 6: the athlete publishes version 3 introducing an unapproved custom exercise'
);
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('hist')),
     (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist')),
     (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist')),
     (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist'))]),
  ARRAY[1::bigint, 3, 3, 4],
  'step 8: the creator sees the template, all three versions and every descendant (creator shortcut)'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('hist')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist')),
    (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist')),
    (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist')),
    pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L) $$, pg_temp.recall('hist')))::bigint
  ],
  ARRAY[0::bigint, 0, 0, 0, 42501],
  'step 7: the coach receives 0 rows (V3 is unsafe, so even the safe V2 is hidden) and cannot clone'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000008');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*)::text FROM public.workout_templates WHERE id = pg_temp.recall('hist')),
    pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L) $$, pg_temp.recall('hist')))
  ],
  ARRAY['0', '42501'],
  'step 9: a Coach in another organization sees 0 rows and is rejected with 42501'
);
RESET ROLE;

-- V1 safe, V2 unsafe: the template is hidden and V1 is not discoverable.
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('hist2', (public.create_workout_template(
       'A Reverse History', NULL, 'private',
       pg_temp.bx('[{"title":"Safe","block_type":"standard_set","items":[{"exercise":"push-up","measurement_mode":"reps","sets":[{"target_reps":10}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'V1 of a second routine holds approved exercises only'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT ARRAY[(SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('hist2')),
                (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist2'))]),
  ARRAY[1::bigint, 1],
  'while V1 is the latest and safe, the coach sees the routine and V1'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($$ SELECT public.publish_new_workout_version(%L, 'unsafe v2',
     '[{"title":"Mine","block_type":"standard_set","items":[{"exercise_id":"d4000000-0000-4000-8000-0000000000c1","measurement_mode":"reps","sets":[{"target_reps":15}]}]}]'::jsonb) $$,
         pg_temp.recall('hist2')),
  'the athlete publishes an unsafe V2'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT ARRAY[(SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('hist2')),
                (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist2')),
                (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('hist2'))]),
  ARRAY[0::bigint, 0, 0],
  'V1 safe, V2 unsafe: the routine is hidden from the coach and the earlier safe V1 is not discoverable'
);
RESET ROLE;
SELECT pg_temp.act('d4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('hist2')),
  2::bigint,
  'the creator still sees both versions of that routine'
);
RESET ROLE;

-- 10. Version pinning never migrates anything: earlier versions stay byte-identical ---
SELECT is(
  (SELECT pg_temp.sig(pg_temp.recall('hist'), 2) = pg_temp.sig(pg_temp.recall('hist_clone'), 1)),
  true,
  'publishing V3 did not disturb V2 (the clone still equals V2)'
);

SELECT * FROM finish();
ROLLBACK;
