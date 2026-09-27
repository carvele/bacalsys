-- Sprint 3 · Task 3.10 — workout builder: schema constraints, explicit grants,
-- structural (sealed-version) immutability, re-parenting, null-safe organization
-- scope, fail-closed inactive callers, the D5 golden permission matrix,
-- cross-organization isolation and template/version read visibility.
--
-- Failure modes are asserted separately, exactly as the specification requires:
--   * authenticated DML                → 42501 (no table grants; never weakened)
--   * privileged DML against sealed    → 22000 (immutability triggers)
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(62);

-- Helpers (rolled back with the test) ------------------------------------------------
--   sqlstate_of(sql)   runs sql as the current role → 'ok' or the SQLSTATE it raised
--   bx(json text)      resolves  "exercise":"<slug>"  →  "exercise_id":"<uuid>" for official exercises
--   remember/recall    carry ids between statements run under different roles
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END;
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
CREATE FUNCTION pg_temp.remember(p_k text, p_v uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  INSERT INTO pg_temp.ids VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = excluded.v;
  RETURN p_v;
END;
$fn$;
CREATE FUNCTION pg_temp.recall(p_k text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $fn$
  SELECT v FROM pg_temp.ids WHERE k = p_k;
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.bx(text),
  pg_temp.remember(text, uuid), pg_temp.recall(text) TO authenticated, anon;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete A (creator; Org A)            …02 Athlete B            …03 Coach (current coach of A)
--   …04 other Coach                           …05 Leader               …06 Vice President
--   …07 President                             …08 Coach in Org B       …09 Athlete with NO organization
--   …0a Athlete (suspended later)             …0b Coach "mover"        …0c VP with NO organization
--   …0d Coach with NO organization            …0e Athlete A2 (coached by …0d)
--   …0f former Coach of A (closed assignment)
INSERT INTO public.organizations (id, name, slug)
VALUES ('d3000000-0000-4000-8000-0000000000f1', 'Club B', 'club-b-s3-test');
INSERT INTO public.branches (id, organization_id, name)
VALUES ('d3000000-0000-4000-8000-0000000000f2', 'd3000000-0000-4000-8000-0000000000f1', 'Club B Branch');

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('d3000000-0000-4000-8000-000000000001', 'athlete.a@s3.test', '{"full_name":"Athlete A"}'),
  ('d3000000-0000-4000-8000-000000000002', 'athlete.b@s3.test', '{"full_name":"Athlete B"}'),
  ('d3000000-0000-4000-8000-000000000003', 'coach@s3.test', '{"full_name":"Coach"}'),
  ('d3000000-0000-4000-8000-000000000004', 'coach.other@s3.test', '{"full_name":"Other Coach"}'),
  ('d3000000-0000-4000-8000-000000000005', 'leader@s3.test', '{"full_name":"Leader"}'),
  ('d3000000-0000-4000-8000-000000000006', 'vp@s3.test', '{"full_name":"VP"}'),
  ('d3000000-0000-4000-8000-000000000007', 'pres@s3.test', '{"full_name":"President"}'),
  ('d3000000-0000-4000-8000-000000000008', 'coach.b@s3.test', '{"full_name":"Coach B"}'),
  ('d3000000-0000-4000-8000-000000000009', 'noorg@s3.test', '{"full_name":"No Org Athlete"}'),
  ('d3000000-0000-4000-8000-00000000000a', 'susp@s3.test', '{"full_name":"Soon Suspended"}'),
  ('d3000000-0000-4000-8000-00000000000b', 'mover@s3.test', '{"full_name":"Mover Coach"}'),
  ('d3000000-0000-4000-8000-00000000000c', 'vp.noorg@s3.test', '{"full_name":"VP No Org"}'),
  ('d3000000-0000-4000-8000-00000000000d', 'coach.noorg@s3.test', '{"full_name":"Coach No Org"}'),
  ('d3000000-0000-4000-8000-00000000000e', 'athlete.a2@s3.test', '{"full_name":"Athlete A2"}'),
  ('d3000000-0000-4000-8000-00000000000f', 'former@s3.test', '{"full_name":"Former Coach"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'd3000000-0000-4000-8000-0000000000%';
UPDATE public.profiles SET home_branch_id = 'd3000000-0000-4000-8000-0000000000f2'
WHERE id = 'd3000000-0000-4000-8000-000000000008';
UPDATE public.profiles SET home_branch_id = NULL
WHERE id IN ('d3000000-0000-4000-8000-000000000009', 'd3000000-0000-4000-8000-00000000000c',
             'd3000000-0000-4000-8000-00000000000d');
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id
FROM (VALUES
  ('d3000000-0000-4000-8000-000000000001', 'Athlete'),
  ('d3000000-0000-4000-8000-000000000002', 'Athlete'),
  ('d3000000-0000-4000-8000-000000000003', 'Coach'),
  ('d3000000-0000-4000-8000-000000000004', 'Coach'),
  ('d3000000-0000-4000-8000-000000000005', 'Leader'),
  ('d3000000-0000-4000-8000-000000000006', 'Vice President'),
  ('d3000000-0000-4000-8000-000000000007', 'President'),
  ('d3000000-0000-4000-8000-000000000008', 'Coach'),
  ('d3000000-0000-4000-8000-000000000009', 'Athlete'),
  ('d3000000-0000-4000-8000-00000000000a', 'Athlete'),
  ('d3000000-0000-4000-8000-00000000000b', 'Coach'),
  ('d3000000-0000-4000-8000-00000000000c', 'Vice President'),
  ('d3000000-0000-4000-8000-00000000000d', 'Coach'),
  ('d3000000-0000-4000-8000-00000000000e', 'Athlete'),
  ('d3000000-0000-4000-8000-00000000000f', 'Coach')
) AS f(profile_id, position_name)
JOIN public.positions pos ON pos.name = f.position_name;

-- Coaching relationships (privileged fixture inserts).
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at) VALUES
  ('d3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-00000000000f',
   'd3000000-0000-4000-8000-000000000006', now() - interval '3 days', now() - interval '1 day');
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('d3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000003', 'd3000000-0000-4000-8000-000000000006'),
  ('d3000000-0000-4000-8000-00000000000e', 'd3000000-0000-4000-8000-00000000000d', 'd3000000-0000-4000-8000-000000000006');

-- Athlete-private custom exercise (status private, measurable by reps).
INSERT INTO public.exercises (id, name, slug, category, measurement_types, equipment_needed, created_by)
VALUES ('d3000000-0000-4000-8000-0000000000c1', 'Athlete A Secret Move', 'athlete-a-secret-move', 'core',
        ARRAY['reps'], ARRAY['none'], 'd3000000-0000-4000-8000-000000000001');

-- 1. Schema, grants and structure -------------------------------------------------
SELECT ok(
  (SELECT count(*) = 5 AND bool_and(relrowsecurity) FROM pg_class
   WHERE oid IN ('public.workout_templates'::regclass, 'public.workout_versions'::regclass,
                 'public.workout_blocks'::regclass, 'public.workout_items'::regclass,
                 'public.workout_item_sets'::regclass)),
  'RLS is enabled on all five hierarchy tables'
);
SELECT ok(
  (SELECT bool_and(has_table_privilege('authenticated', t, 'SELECT')
                   AND NOT has_table_privilege('authenticated', t, 'INSERT')
                   AND NOT has_table_privilege('authenticated', t, 'UPDATE')
                   AND NOT has_table_privilege('authenticated', t, 'DELETE')
                   AND NOT has_table_privilege('authenticated', t, 'TRUNCATE')
                   AND NOT has_table_privilege('authenticated', t, 'REFERENCES')
                   AND NOT has_table_privilege('authenticated', t, 'TRIGGER'))
   FROM unnest(ARRAY['public.workout_templates', 'public.workout_versions', 'public.workout_blocks',
                     'public.workout_items', 'public.workout_item_sets']) AS t),
  'authenticated holds SELECT only on every hierarchy table'
);
SELECT ok(
  (SELECT bool_and(NOT has_table_privilege('anon', t, 'SELECT') AND NOT has_table_privilege('anon', t, 'INSERT'))
   FROM unnest(ARRAY['public.workout_templates', 'public.workout_versions', 'public.workout_blocks',
                     'public.workout_items', 'public.workout_item_sets']) AS t),
  'anon holds no privilege on the hierarchy tables'
);
SELECT is(
  (SELECT count(*) FROM pg_constraint
   WHERE contype = 'f' AND confdeltype = 'r'
     AND conrelid IN ('public.workout_templates'::regclass, 'public.workout_versions'::regclass,
                      'public.workout_items'::regclass)),
  5::bigint,
  'ON DELETE RESTRICT on template→organization, template→creator, version→template, version→creator, item→exercise'
);
SELECT ok(
  (SELECT count(*) = 3 FROM pg_constraint
   WHERE contype = 'f' AND confdeltype = 'c'
     AND conrelid IN ('public.workout_blocks'::regclass, 'public.workout_items'::regclass,
                      'public.workout_item_sets'::regclass)),
  'only the descendant chain (block→version, item→block, set→item) cascades'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.create_workout_template(text, text, text, jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.publish_new_workout_version(uuid, text, jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.clone_workout_template(uuid, text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.set_template_visibility(uuid, text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.update_workout_template_metadata(uuid, text, text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.set_workout_template_archived(uuid, boolean)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.create_workout_template(text, text, text, jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.publish_new_workout_version(uuid, text, jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.clone_workout_template(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.set_template_visibility(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.update_workout_template_metadata(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.set_workout_template_archived(uuid, boolean)', 'EXECUTE'),
  'the six mutation wrappers are callable by authenticated and never by anon'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'app_private.build_workout_version(uuid, jsonb, uuid, boolean)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'app_private.seal_workout_version(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'app_private.write_audit_event(text, text, text, jsonb, jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'app_private.can_mutate_workout_template(public.workout_templates)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'app_private.prevent_sealed_version_mutation()', 'EXECUTE'),
  'internal builders, sealing, audit writer and trigger functions are not executable by clients'
);
SELECT ok(
  (SELECT bool_and(prosecdef AND proconfig @> ARRAY['search_path=""'])
   FROM pg_proc WHERE pronamespace = 'app_private'::regnamespace
     AND proname IN ('prevent_sealed_version_mutation', 'check_version_unsealed_for_block',
                     'check_version_unsealed_for_item', 'check_version_unsealed_for_set',
                     'can_view_workout_template', 'can_view_workout_version',
                     'create_workout_template_internal', 'publish_new_workout_version_internal',
                     'clone_workout_template_internal', 'set_template_visibility_internal',
                     'update_workout_template_metadata_internal', 'set_workout_template_archived_internal',
                     'build_workout_version', 'seal_workout_version', 'write_audit_event',
                     'can_mutate_workout_template')),
  'every Sprint 3 SECURITY DEFINER function pins search_path = empty'
);

-- 2. Direct authenticated DML fails with 42501 (never reaches the triggers) ---------
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_templates (organization_id, name, created_by)
      VALUES ('00000000-0000-4000-8000-000000000001', 'x', 'd3000000-0000-4000-8000-000000000003') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_versions (template_id, version_number, created_by)
      VALUES (gen_random_uuid(), 1, 'd3000000-0000-4000-8000-000000000003') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type)
      VALUES (gen_random_uuid(), 1, 'x', 'standard_set') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_items (block_id, exercise_id, order_in_block, measurement_mode)
      VALUES (gen_random_uuid(), gen_random_uuid(), 1, 'reps') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_item_sets (workout_item_id, set_number, target_reps)
      VALUES (gen_random_uuid(), 1, 5) $$)
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'authenticated INSERT into any hierarchy table fails with 42501'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ UPDATE public.workout_templates SET name = 'y' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET notes = 'y' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_blocks SET title = 'y' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_items SET notes = 'y' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_item_sets SET notes = 'y' $$)
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'authenticated UPDATE (including re-parenting columns) on any hierarchy table fails with 42501'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ DELETE FROM public.workout_templates $$),
    pg_temp.sqlstate_of($$ DELETE FROM public.workout_versions $$),
    pg_temp.sqlstate_of($$ DELETE FROM public.workout_blocks $$),
    pg_temp.sqlstate_of($$ DELETE FROM public.workout_items $$),
    pg_temp.sqlstate_of($$ DELETE FROM public.workout_item_sets $$)
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'authenticated DELETE on any hierarchy table fails with 42501'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ UPDATE public.workout_blocks SET workout_version_id = gen_random_uuid() $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_items SET block_id = gen_random_uuid() $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_item_sets SET workout_item_id = gen_random_uuid() $$)
  ],
  ARRAY['42501', '42501', '42501'],
  'authenticated re-parenting of a block, item or set fails with 42501'
);
RESET ROLE;

-- 3. Fixtures built through the public RPCs ----------------------------------------
-- Coach creates the canonical Slice 1 organization template.
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('org_tpl', (public.create_workout_template(
       'Upper Body Calisthenics Strength', 'Slice 1 routine', 'organization',
       pg_temp.bx('[
         {"title":"Primary Strength","block_type":"superset","items":[
           {"exercise":"pull-up","measurement_mode":"added_weight","sets":[
             {"target_reps":5,"target_load_kg":10.00,"load_type":"added","target_rest_seconds":120,"target_rpe":7.5},
             {"target_reps":3,"target_load_kg":15.00,"load_type":"added","target_rest_seconds":120,"target_rpe":8.5},
             {"target_reps":1,"target_load_kg":20.00,"load_type":"added","target_rest_seconds":180,"target_rpe":9.5}]},
           {"exercise":"parallel-bar-dip","measurement_mode":"added_weight","sets":[
             {"target_reps":5,"target_load_kg":15.00,"load_type":"added","target_rest_seconds":120},
             {"target_reps":5,"target_load_kg":15.00,"load_type":"added","target_rest_seconds":120},
             {"target_reps":8,"target_load_kg":10.00,"load_type":"added","target_rest_seconds":120}]}]},
         {"title":"Core Finisher","block_type":"amrap","amrap_duration_seconds":420,"items":[
           {"exercise":"hanging-leg-raise","measurement_mode":"reps","sets":[{"target_reps":10}]}]}
       ]')) ->> 'template_id')::uuid) $$,
  'Coach creates the Slice 1 organization template through the RPC'
);
RESET ROLE;

-- Athlete A: private routine with the athlete-private exercise (V1, unsafe).
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('priv_unsafe', (public.create_workout_template(
       'Athlete A Private Routine', NULL, 'private',
       jsonb_build_array(jsonb_build_object('title', 'Mine', 'block_type', 'standard_set', 'items',
         jsonb_build_array(jsonb_build_object('exercise_id', 'd3000000-0000-4000-8000-0000000000c1',
           'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 12))))))
     ) ->> 'template_id')::uuid) $$,
  'Athlete A creates a private routine using their own private exercise'
);
SELECT lives_ok(
  $$ SELECT pg_temp.remember('priv_safe', (public.create_workout_template(
       'Athlete A Safe Routine', NULL, 'private',
       pg_temp.bx('[{"title":"Pulls","block_type":"standard_set","items":[
         {"exercise":"pull-up","measurement_mode":"reps","sets":[{"target_reps":8},{"target_reps":8}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'Athlete A creates a private routine of approved exercises only'
);
RESET ROLE;

-- Athlete A2 (coached by the org-less Coach) and the soon-suspended athlete.
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000e","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('a2_safe', (public.create_workout_template(
       'A2 Safe Routine', NULL, 'private',
       pg_temp.bx('[{"title":"Push","block_type":"standard_set","items":[
         {"exercise":"push-up","measurement_mode":"reps","sets":[{"target_reps":15}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'Athlete A2 creates a private safe routine'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000a","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('susp_tpl', (public.create_workout_template(
       'Before Suspension', NULL, 'private',
       pg_temp.bx('[{"title":"Pulls","block_type":"standard_set","items":[
         {"exercise":"pull-up","measurement_mode":"reps","sets":[{"target_reps":5}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'the soon-to-be-suspended athlete creates a routine while active'
);
RESET ROLE;

-- Mover coach: one private and one organization template, then leaves the organization.
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('mover_org', (public.create_workout_template(
       'Mover Org Routine', NULL, 'organization',
       pg_temp.bx('[{"title":"Core","block_type":"standard_set","items":[
         {"exercise":"plank","measurement_mode":"duration","sets":[{"target_duration_seconds":60}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'Mover creates an organization template while in Organization A'
);
SELECT lives_ok(
  $$ SELECT pg_temp.remember('mover_priv', (public.create_workout_template(
       'Mover Private Routine', NULL, 'private',
       pg_temp.bx('[{"title":"Core","block_type":"standard_set","items":[
         {"exercise":"plank","measurement_mode":"duration","sets":[{"target_duration_seconds":45}]}]}]')
     ) ->> 'template_id')::uuid) $$,
  'Mover creates a private template while in Organization A'
);
RESET ROLE;

-- Privileged edits: suspend one member; move the mover out of any organization.
UPDATE public.profiles SET status = 'suspended' WHERE id = 'd3000000-0000-4000-8000-00000000000a';
UPDATE public.profiles SET home_branch_id = NULL WHERE id = 'd3000000-0000-4000-8000-00000000000b';

-- 4. Verified Slice 1 shape (privileged read of the counts) -------------------------
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('org_tpl') AND visibility = 'organization'),
     (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl') AND is_sealed AND version_number = 1 AND sealed_at IS NOT NULL),
     (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl')),
     (SELECT count(*) FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl')),
     (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl'))
   ]),
  ARRAY[1::bigint, 1, 2, 3, 7],
  'Slice 1 shape: 1 organization template, 1 sealed version 1, 2 blocks, 3 items, 7 sets'
);

-- 5. Column constraints (privileged actor, scratch UNSEALED version) ---------------
INSERT INTO public.workout_templates (id, organization_id, name, visibility, created_by)
VALUES ('d3000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-000000000001', 'Scratch', 'private',
        'd3000000-0000-4000-8000-000000000001');
INSERT INTO public.workout_versions (id, template_id, version_number, created_by)
VALUES ('d3000000-0000-4000-8000-0000000000e2', 'd3000000-0000-4000-8000-0000000000e1', 1,
        'd3000000-0000-4000-8000-000000000001');
INSERT INTO public.workout_blocks (id, workout_version_id, order_in_workout, title, block_type)
VALUES ('d3000000-0000-4000-8000-0000000000e3', 'd3000000-0000-4000-8000-0000000000e2', 1, 'Scratch block', 'standard_set');
INSERT INTO public.workout_items (id, block_id, exercise_id, order_in_block, measurement_mode)
VALUES ('d3000000-0000-4000-8000-0000000000e4', 'd3000000-0000-4000-8000-0000000000e3',
        (SELECT id FROM public.exercises WHERE slug = 'pull-up'), 1, 'reps');
INSERT INTO public.workout_item_sets (id, workout_item_id, set_number, target_reps)
VALUES ('d3000000-0000-4000-8000-0000000000e5', 'd3000000-0000-4000-8000-0000000000e4', 1, 5);

SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type)
      VALUES ('d3000000-0000-4000-8000-0000000000e2', 2, 'AMRAP w/o duration', 'amrap') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type, amrap_duration_seconds)
      VALUES ('d3000000-0000-4000-8000-0000000000e2', 2, 'Standard with duration', 'standard_set', 300) $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type)
      VALUES ('d3000000-0000-4000-8000-0000000000e2', 2, 'Circuit w/o rounds', 'circuit') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type, circuit_rounds)
      VALUES ('d3000000-0000-4000-8000-0000000000e2', 2, 'Superset with rounds', 'superset', 3) $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type, amrap_duration_seconds)
      VALUES ('d3000000-0000-4000-8000-0000000000e2', 2, 'Short AMRAP', 'amrap', 10) $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type)
      VALUES ('d3000000-0000-4000-8000-0000000000e2', 1, 'Duplicate order', 'standard_set') $$)
  ],
  ARRAY['23514', '23514', '23514', '23514', '23514', '23505'],
  'blocks: AMRAP duration required only for AMRAP (min 30 s), circuit rounds required only for circuit, order unique'
);
SELECT ok(
  pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type, amrap_duration_seconds)
    VALUES ('d3000000-0000-4000-8000-0000000000e2', 2, 'Valid AMRAP', 'amrap', 420) $$) = 'ok'
  AND pg_temp.sqlstate_of($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type, circuit_rounds)
    VALUES ('d3000000-0000-4000-8000-0000000000e2', 3, 'Valid circuit', 'circuit', 4) $$) = 'ok',
  'a valid AMRAP block and a valid circuit block are accepted'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_items (block_id, exercise_id, order_in_block, measurement_mode)
      VALUES ('d3000000-0000-4000-8000-0000000000e3', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 2, 'amrap') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_items (block_id, exercise_id, order_in_block, measurement_mode)
      VALUES ('d3000000-0000-4000-8000-0000000000e3', (SELECT id FROM public.exercises WHERE slug = 'push-up'), 1, 'reps') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_item_sets (workout_item_id, set_number, target_load_kg, load_type)
      VALUES ('d3000000-0000-4000-8000-0000000000e4', 2, 0, 'added') $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_item_sets (workout_item_id, set_number, target_load_kg)
      VALUES ('d3000000-0000-4000-8000-0000000000e4', 2, 10) $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_item_sets (workout_item_id, set_number, target_reps, target_rpe)
      VALUES ('d3000000-0000-4000-8000-0000000000e4', 2, 5, 10.5) $$),
    pg_temp.sqlstate_of($$ INSERT INTO public.workout_item_sets (workout_item_id, set_number, target_reps)
      VALUES ('d3000000-0000-4000-8000-0000000000e4', 1, 5) $$)
  ],
  ARRAY['23514', '23505', '23514', '23514', '23514', '23505'],
  'items/sets: amrap is not an item mode, order and set_number unique, load needs a positive value and a type, RPE ≤ 10'
);

-- 6. Sealed-version immutability under a privileged actor → 22000 --------------------
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_versions SET notes = 'edited' WHERE template_id = %L $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ DELETE FROM public.workout_versions WHERE template_id = %L $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_versions SET is_sealed = false, sealed_at = NULL WHERE template_id = %L $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_versions SET sealed_at = now() WHERE template_id = %L $$, pg_temp.recall('org_tpl')))
  ],
  ARRAY['22000', '22000', '22000', '22000'],
  'a sealed version cannot be edited, deleted, unsealed or re-stamped, even by a privileged actor'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ INSERT INTO public.workout_blocks (workout_version_id, order_in_workout, title, block_type)
      VALUES (%L, 9, 'late block', 'standard_set') $$, (SELECT id FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl')))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_blocks SET title = 'edited' WHERE workout_version_id = %L $$, (SELECT id FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl')))),
    pg_temp.sqlstate_of(format($$ DELETE FROM public.workout_blocks WHERE workout_version_id = %L $$, (SELECT id FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl'))))
  ],
  ARRAY['22000', '22000', '22000'],
  'blocks of a sealed version cannot be inserted, updated or deleted'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ INSERT INTO public.workout_items (block_id, exercise_id, order_in_block, measurement_mode)
      VALUES (%L, (SELECT id FROM public.exercises WHERE slug = 'push-up'), 9, 'reps') $$,
      (SELECT b.id FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_items SET notes = 'edited' WHERE block_id = %L $$,
      (SELECT b.id FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1))),
    pg_temp.sqlstate_of(format($$ DELETE FROM public.workout_items WHERE block_id = %L $$,
      (SELECT b.id FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1)))
  ],
  ARRAY['22000', '22000', '22000'],
  'items of a sealed version cannot be inserted, updated or deleted'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ INSERT INTO public.workout_item_sets (workout_item_id, set_number, target_reps) VALUES (%L, 9, 5) $$,
      (SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id
       WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1 AND i.order_in_block = 1))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_item_sets SET target_reps = 99 WHERE workout_item_id = %L $$,
      (SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id
       WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1 AND i.order_in_block = 1))),
    pg_temp.sqlstate_of(format($$ DELETE FROM public.workout_item_sets WHERE workout_item_id = %L $$,
      (SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id
       WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1 AND i.order_in_block = 1)))
  ],
  ARRAY['22000', '22000', '22000'],
  'sets of a sealed version cannot be inserted, updated or deleted'
);

-- 7. Re-parenting: dual-ancestry check (OLD and NEW) -------------------------------
SELECT is(
  ARRAY[
    -- out of a sealed version into the unsealed scratch version
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_blocks SET workout_version_id = 'd3000000-0000-4000-8000-0000000000e2' WHERE id = %L $$,
      (SELECT b.id FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 2))),
    -- from the unsealed scratch version into a sealed one
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_blocks SET workout_version_id = %L WHERE id = 'd3000000-0000-4000-8000-0000000000e3' $$,
      (SELECT id FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl')))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_items SET block_id = 'd3000000-0000-4000-8000-0000000000e3' WHERE id = %L $$,
      (SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id
       WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1 AND i.order_in_block = 1))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_items SET block_id = %L WHERE id = 'd3000000-0000-4000-8000-0000000000e4' $$,
      (SELECT b.id FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_item_sets SET workout_item_id = 'd3000000-0000-4000-8000-0000000000e4'
      WHERE workout_item_id = %L $$,
      (SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id
       WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1 AND i.order_in_block = 1))),
    pg_temp.sqlstate_of(format($$ UPDATE public.workout_item_sets SET workout_item_id = %L WHERE id = 'd3000000-0000-4000-8000-0000000000e5' $$,
      (SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id
       WHERE v.template_id = pg_temp.recall('org_tpl') AND b.order_in_workout = 1 AND i.order_in_block = 1)))
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000', '22000'],
  'a block, item or set can be moved neither out of nor into a sealed version (22000)'
);

-- 8. Sealing-transition loophole ------------------------------------------------------
INSERT INTO public.workout_versions (id, template_id, version_number, notes, created_by)
VALUES ('d3000000-0000-4000-8000-0000000000e6', 'd3000000-0000-4000-8000-0000000000e1', 2, 'draft note',
        'd3000000-0000-4000-8000-000000000001');
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET is_sealed = true, sealed_at = now(), notes = 'changed'
      WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET is_sealed = true, sealed_at = now(), version_number = 7
      WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET is_sealed = true, sealed_at = now(),
      created_by = 'd3000000-0000-4000-8000-000000000002' WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET is_sealed = true, sealed_at = now(),
      created_at = created_at - interval '1 day' WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$),
    pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET notes = 'edit while unsealed'
      WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$)
  ],
  ARRAY['22000', '22000', '22000', '22000', '22000'],
  'sealing may change nothing but is_sealed (notes, version_number, creator, created_at are frozen); unsealed versions cannot be edited in place'
);
SELECT is(
  pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET is_sealed = true WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$),
  'ok',
  'the clean false → true sealing transition succeeds'
);
SELECT ok(
  (SELECT is_sealed AND sealed_at IS NOT NULL AND notes = 'draft note' AND version_number = 2
   FROM public.workout_versions WHERE id = 'd3000000-0000-4000-8000-0000000000e6'),
  'sealing stamps sealed_at and keeps notes and version_number'
);
SELECT is(
  pg_temp.sqlstate_of($$ UPDATE public.workout_versions SET is_sealed = true WHERE id = 'd3000000-0000-4000-8000-0000000000e6' $$),
  '22000',
  'a sealed version cannot be sealed again (exactly one transition)'
);

-- 9. RESTRICT keeps history; only an UNSEALED version may cascade away ------------
SELECT ok(
  pg_temp.sqlstate_of(format($$ DELETE FROM public.workout_templates WHERE id = %L $$, pg_temp.recall('org_tpl'))) IN ('23001', '23503')
  AND pg_temp.sqlstate_of($$ DELETE FROM public.exercises WHERE slug = 'pull-up' $$) IN ('23001', '23503')
  AND pg_temp.sqlstate_of($$ DELETE FROM public.profiles WHERE id = 'd3000000-0000-4000-8000-000000000003' $$) IN ('23001', '23503'),
  'templates with versions, exercises used by items and creators of templates cannot be deleted (RESTRICT)'
);
SELECT is(
  pg_temp.sqlstate_of($$ DELETE FROM public.workout_versions WHERE id = 'd3000000-0000-4000-8000-0000000000e2' $$),
  'ok',
  'an unsealed version can be discarded'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.workout_blocks WHERE workout_version_id = 'd3000000-0000-4000-8000-0000000000e2')
  AND NOT EXISTS (SELECT 1 FROM public.workout_items WHERE id = 'd3000000-0000-4000-8000-0000000000e4')
  AND NOT EXISTS (SELECT 1 FROM public.workout_item_sets WHERE id = 'd3000000-0000-4000-8000-0000000000e5'),
  'its unsealed descendants cascade away with it'
);

-- 10. D5 golden permission matrix ------------------------------------------------------
SELECT is(
  (SELECT array_agg(pos.name ORDER BY pos.name)
   FROM public.position_permissions pp
   JOIN public.positions pos ON pos.id = pp.position_id
   JOIN public.permissions p ON p.id = pp.permission_id
   WHERE p.name = 'workouts:publish_org'),
  ARRAY['Coach', 'President', 'Vice President'],
  'D5: workouts:publish_org is held by Coach, Vice President and President'
);
SELECT is(
  (SELECT array_agg(pos.name ORDER BY pos.name)
   FROM public.position_permissions pp
   JOIN public.positions pos ON pos.id = pp.position_id
   JOIN public.permissions p ON p.id = pp.permission_id
   WHERE p.name = 'workouts:manage_org'),
  ARRAY['President', 'Vice President'],
  'D5: workouts:manage_org is held by Vice President and President only'
);
SELECT is_empty(
  $$ SELECT pos.name FROM public.position_permissions pp
     JOIN public.positions pos ON pos.id = pp.position_id
     JOIN public.permissions p ON p.id = pp.permission_id
     WHERE p.name LIKE 'workouts:%' AND pos.name IN ('Athlete', 'Leader') $$,
  'D5: Athlete and Leader hold neither workouts: permission'
);
SELECT is_empty(
  $$ SELECT p.name FROM public.system_role_permissions srp
     JOIN public.permissions p ON p.id = srp.permission_id
     WHERE p.name LIKE 'workouts:%' $$,
  'D5: no system role holds a workouts: permission'
);

-- 11. Visibility: organization template, same-organization scope --------------------
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_blocks b JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_item_sets s JOIN public.workout_items i ON i.id = s.workout_item_id JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.workout_versions v ON v.id = b.workout_version_id WHERE v.template_id = pg_temp.recall('org_tpl'))
  ],
  ARRAY[1::bigint, 1, 2, 3, 7],
  'an Athlete in the same organization reads the organization template and its whole hierarchy'
);
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id IN (pg_temp.recall('priv_unsafe'), pg_temp.recall('priv_safe'),
                                                            pg_temp.recall('a2_safe'), pg_temp.recall('mover_priv'))),
  0::bigint,
  'another Athlete sees none of the private routines'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_blocks),
    (SELECT count(*) FROM public.workout_items),
    (SELECT count(*) FROM public.workout_item_sets)
  ],
  ARRAY[0::bigint, 0, 0, 0, 0],
  'cross-organization isolation: a Coach in Organization B reads 0 rows of Organization A at every level'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L) $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, 'x', '[]'::jsonb) $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'x', NULL) $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('org_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'private') $$, pg_temp.recall('org_tpl')))
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501'],
  'cross-organization isolation: Organization B cannot clone, publish to, edit, archive or re-scope Organization A templates'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('org_tpl')),
    (SELECT count(*) FROM public.workout_templates WHERE id IN (pg_temp.recall('priv_unsafe'), pg_temp.recall('priv_safe'), pg_temp.recall('a2_safe')))
  ],
  ARRAY[1::bigint, 0],
  'Leader reads organization templates but no athlete-private routine (0 rows)'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Leader org', NULL, 'organization',
      jsonb_build_array(jsonb_build_object('title','x','block_type','standard_set','items', jsonb_build_array(
        jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
        'measurement_mode','reps','sets', jsonb_build_array(jsonb_build_object('target_reps', 5))))))) $$),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'x', NULL) $$, pg_temp.recall('org_tpl')))
  ],
  ARRAY['42501', '42501'],
  'Leader cannot author organization templates or edit another member''s template'
);
RESET ROLE;

-- 12. Private routine visibility matrix (athlete A's SAFE routine) -----------------
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id IN (pg_temp.recall('priv_safe'), pg_temp.recall('priv_unsafe'))),
  2::bigint,
  'the creator reads all of their own private routines, safe or not'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_safe')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('priv_safe')),
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_unsafe')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('priv_unsafe')),
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('a2_safe'))
  ],
  ARRAY[1::bigint, 1, 0, 0, 0],
  'the current primary coach sees the athlete''s safe routine, not the unsafe one, and not other athletes'' routines'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_safe')),
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_unsafe')),
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('a2_safe'))
  ],
  ARRAY[1::bigint, 0, 1],
  'Vice President (workouts:manage_org) sees safe private routines in the organization, never unsafe ones'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_safe')),
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_unsafe'))
  ],
  ARRAY[1::bigint, 0],
  'President sees safe private routines in the organization, never unsafe ones'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id IN (pg_temp.recall('priv_safe'), pg_temp.recall('a2_safe'))),
  0::bigint,
  'a Coach who is not the athlete''s primary coach sees no private routine'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000f","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('priv_safe')),
  0::bigint,
  'a FORMER coach sees no private routine (catalog visibility needs the current relationship)'
);
RESET ROLE;

-- 13. Null-safe organization scope: a caller with home_branch_id IS NULL ----------------
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000009","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE visibility = 'organization'),
    (SELECT count(*) FROM public.workout_versions),
    (SELECT count(*) FROM public.workout_item_sets)
  ],
  ARRAY[0::bigint, 0, 0],
  'an active member with no organization reads 0 organization templates (fails closed, not NULL-permissive)'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of($$ SELECT public.create_workout_template('No org', NULL, 'private',
      jsonb_build_array(jsonb_build_object('title','x','block_type','standard_set','items', jsonb_build_array(
        jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
        'measurement_mode','reps','sets', jsonb_build_array(jsonb_build_object('target_reps', 5))))))) $$),
    pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L) $$, pg_temp.recall('org_tpl')))
  ],
  ARRAY['42501', '42501'],
  'create_workout_template and clone_workout_template reject an org-less caller with 42501, not a NOT NULL error'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('a2_safe')),
  0::bigint,
  'an org-less Coach who IS the athlete''s primary coach still reads 0 private routines (null-safe org match)'
);
SELECT is(
  pg_temp.sqlstate_of($$ SELECT public.create_workout_template('Org-less org tpl', NULL, 'organization',
    jsonb_build_array(jsonb_build_object('title','x','block_type','standard_set','items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
      'measurement_mode','reps','sets', jsonb_build_array(jsonb_build_object('target_reps', 5))))))) $$),
  '42501',
  'an org-less Coach holding publish_org cannot create an organization template (42501)'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000c","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.workout_templates),
  0::bigint,
  'an org-less Vice President (manage_org) reads no organization template and no private routine of others'
);
RESET ROLE;

-- 14. Moved private creator vs org template (Mover left every organization) --------
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('mover_priv')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('mover_priv')),
    (SELECT count(*) FROM public.workout_templates WHERE id = pg_temp.recall('mover_org')),
    (SELECT count(*) FROM public.workout_versions WHERE template_id = pg_temp.recall('mover_org'))
  ],
  ARRAY[1::bigint, 1, 0, 0],
  'a creator who left the organization keeps their private routine but loses their old organization template'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'x', NULL) $$, pg_temp.recall('mover_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('mover_org'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'private') $$, pg_temp.recall('mover_org')))
  ],
  ARRAY['42501', '42501', '42501'],
  'organization-template mutation RPCs fail closed with 42501 once the caller has no current organization'
);
RESET ROLE;

-- 15. Inactive callers fail closed ---------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-00000000000a","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (SELECT count(*) FROM public.workout_templates),
    (SELECT count(*) FROM public.workout_versions),
    (SELECT count(*) FROM public.workout_blocks),
    (SELECT count(*) FROM public.workout_items),
    (SELECT count(*) FROM public.workout_item_sets)
  ],
  ARRAY[0::bigint, 0, 0, 0, 0],
  'a suspended member sees 0 rows at every level, even of the routine they created while active'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($$ SELECT public.create_workout_template('x', NULL, 'private', '[]'::jsonb) $$)),
    pg_temp.sqlstate_of(format($$ SELECT public.publish_new_workout_version(%L, NULL, '[]'::jsonb) $$, pg_temp.recall('susp_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.clone_workout_template(%L) $$, pg_temp.recall('susp_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_template_visibility(%L, 'organization') $$, pg_temp.recall('susp_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.update_workout_template_metadata(%L, 'x', NULL) $$, pg_temp.recall('susp_tpl'))),
    pg_temp.sqlstate_of(format($$ SELECT public.set_workout_template_archived(%L, true) $$, pg_temp.recall('susp_tpl')))
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501'],
  'every mutation RPC raises 42501 for a suspended member'
);
RESET ROLE;

SET LOCAL ROLE anon;
SELECT is(
  pg_temp.sqlstate_of($$ SELECT count(*) FROM public.workout_templates $$),
  '42501',
  'anon cannot read workout templates at all'
);
SELECT is(
  pg_temp.sqlstate_of($$ SELECT public.create_workout_template('x', NULL, 'private', '[]'::jsonb) $$),
  '42501',
  'anon cannot call the creation RPC'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
