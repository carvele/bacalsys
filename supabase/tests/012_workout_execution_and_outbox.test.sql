-- Sprint 4 · Task 4.7 — workout execution: mutation RPC flows, idempotency
-- replay/conflict, row-level locking (serialization statements), the F-S4-P14
-- substitution lineage invariant, prescription-lineage verification on actual
-- sets, and offline bundle sync (online-start continuation, brand-new offline
-- session, and replay idempotency). Concurrency ITSELF (two real overlapping
-- transactions) is proven by scripts/e2e/sprint4-slices.mjs on the hosted
-- project; here the serialization statements are asserted structurally, same
-- convention as Sprint 3's 010.
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(30);

-- Helpers ----------------------------------------------------------------------------
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
CREATE FUNCTION pg_temp.item_for(p_version uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.exercises e ON e.id = i.exercise_id
  WHERE b.workout_version_id = p_version AND e.slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.se_for(p_session uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT se.id FROM public.session_exercises se JOIN public.exercises e ON e.id = se.exercise_id
  WHERE se.session_id = p_session AND e.slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.set_id_for(p_item uuid) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT id FROM public.workout_item_sets WHERE workout_item_id = p_item LIMIT 1;
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.act(text), pg_temp.remember(text, uuid), pg_temp.recall(text),
  pg_temp.item_for(uuid, text), pg_temp.se_for(uuid, text), pg_temp.set_id_for(uuid) TO authenticated;

-- Fixtures: one athlete, one coach (author), a routine with THREE items so
-- there is always an unrelated item to test cross-item lineage rejection.
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('b4000000-0000-4000-8000-000000000001', 'athlete@s4b.test', '{"full_name":"Athlete"}'),
  ('b4000000-0000-4000-8000-000000000002', 'coach@s4b.test', '{"full_name":"Coach"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'b4000000-0000-4000-8000-0000000000%';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id FROM (VALUES
  ('b4000000-0000-4000-8000-000000000001', 'Athlete'),
  ('b4000000-0000-4000-8000-000000000002', 'Coach')
) AS f(profile_id, position_name) JOIN public.positions pos ON pos.name = f.position_name;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('b4000000-0000-4000-8000-000000000001', 'b4000000-0000-4000-8000-000000000002', 'b4000000-0000-4000-8000-000000000002');

SELECT pg_temp.act('b4000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT pg_temp.remember('tpl', (public.create_workout_template(
       'Execution Fixture Routine', NULL, 'organization',
       jsonb_build_array(jsonb_build_object(
         'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
           jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
             'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 10))),
           jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'),
             'measurement_mode', 'duration', 'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 30))),
           jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'bodyweight-squat'),
             'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 15)))
         )
       ))
     ) ->> 'template_id')::uuid) $$,
  'the Coach creates the fixture routine (organization-visible, so the athlete can view and start from it)'
);
RESET ROLE;
SELECT pg_temp.remember('ver', id) FROM public.workout_versions WHERE template_id = pg_temp.recall('tpl');

-- 1. start_workout_session: exercise_mapping and idempotent replay -------------------
SELECT pg_temp.act('b4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('key1', %L::uuid) $sql$, gen_random_uuid()),
  'a fixed idempotency key is minted for the start call'
);
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('s1', (public.start_workout_session(%L, %L) ->> 'session_id')::uuid) $sql$,
         pg_temp.recall('ver'), pg_temp.recall('key1')),
  'the athlete starts a session'
);
SELECT is(
  (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(
     (public.start_workout_session(pg_temp.recall('ver'), pg_temp.recall('key1'))) -> 'exercise_mapping'
   ) AS k),
  (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[
     pg_temp.item_for(pg_temp.recall('ver'), 'bodyweight-squat')::text,
     pg_temp.item_for(pg_temp.recall('ver'), 'plank')::text,
     pg_temp.item_for(pg_temp.recall('ver'), 'push-up')::text
   ]) AS x),
  'REPLAYING start_workout_session with the SAME key returns the cached response, keyed by every prescribed workout_item_id'
);
SELECT is(
  (SELECT count(*) FROM public.workout_sessions WHERE id = pg_temp.recall('s1')),
  1::bigint,
  'the replayed start did NOT create a second session'
);

-- 2. record_session_set: idempotent replay, payload-hash conflict, cross-item lineage -
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('key2', %L::uuid) $sql$, gen_random_uuid()),
  'a fixed idempotency key is minted for the first set'
);
SELECT lives_ok(
  format($sql$ SELECT public.record_session_set(%L, %L, '{"set_number":1,"actual_reps":10,"is_completed":true}'::jsonb, %L) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'push-up'), pg_temp.recall('key2')),
  'a set is recorded for push-up'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.record_session_set(%L, %L, '{"set_number":1,"actual_reps":99,"is_completed":true}'::jsonb, %L) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'push-up'), pg_temp.recall('key2'))),
  '42501',
  'reusing the SAME idempotency key with a DIFFERENT payload fails closed (42501), never silently applying the new payload'
);
SELECT is(
  (SELECT actual_reps FROM public.session_sets WHERE session_exercise_id = pg_temp.se_for(pg_temp.recall('s1'), 'push-up') AND set_number = 1),
  10,
  'the original set is unchanged after the rejected replay-with-different-payload'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.record_session_set(%L, %L,
      jsonb_build_object('set_number', 1, 'actual_reps', 10, 'prescribed_item_set_id', %L::uuid, 'is_completed', true), %L) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'push-up'),
    pg_temp.set_id_for(pg_temp.item_for(pg_temp.recall('ver'), 'plank')), gen_random_uuid())),
  '22023',
  'prescription lineage: a prescribed_item_set_id from ANOTHER exercise (plank) is rejected for the push-up set'
);

-- 3. F-S4-P14 substitution lineage invariant -----------------------------------------
SELECT lives_ok(
  format($sql$ SELECT public.record_exercise_substitution(%L, %L,
    (SELECT id FROM public.exercises WHERE slug = 'hollow-body-hold'), 'duration', 'too_difficult', %L) $sql$,
    pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'plank'), gen_random_uuid()),
  'substituting plank BEFORE any of its sets are recorded succeeds'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.record_exercise_substitution(%L, %L,
      (SELECT id FROM public.exercises WHERE slug = 'hollow-body-hold'), 'holds', 'too_easy', %L) $sql$,
    pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'plank'), gen_random_uuid())),
  '23505',
  'Option A: a SECOND substitution of the same prescribed item in the same session is rejected'
);
SELECT lives_ok(
  format($sql$ SELECT public.record_session_set(%L, %L, '{"set_number":1,"actual_duration_seconds":30,"is_completed":true}'::jsonb, %L) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'hollow-body-hold'), gen_random_uuid()),
  'a set is recorded against the now-substituted hollow body hold (validated against ITS performed_measurement_mode: duration)'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.record_session_set(%L, %L, '{"set_number":2,"actual_reps":5,"is_completed":true}'::jsonb, %L) $sql$,
    pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'hollow-body-hold'), gen_random_uuid())),
  '22023',
  'a set that does not match the substituted exercise''s performed_measurement_mode (reps instead of duration) is rejected'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.record_exercise_substitution(%L, %L,
      (SELECT id FROM public.exercises WHERE slug = 'bulgarian-split-squat'), 'reps', 'too_easy', %L) $sql$,
    pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'bodyweight-squat'), gen_random_uuid())),
  'ok',
  'a DIFFERENT prescribed item (bodyweight-squat, no sets recorded yet) may still be substituted'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.record_exercise_substitution(%L, %L,
      (SELECT id FROM public.exercises WHERE slug = 'diamond-push-up'), 'reps', 'too_easy', %L) $sql$,
    pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'push-up'), gen_random_uuid())),
  '22000',
  'F-S4-P14: substituting push-up AFTER its set was already recorded is rejected with 22000'
);

-- 4. Terminal session immutability ----------------------------------------------------
SELECT lives_ok(
  format($sql$ SELECT public.complete_workout_session(%L, 'completed', NULL,
    '{"difficulty_rating":5,"energy_level":3}'::jsonb, NULL, %L) $sql$, pg_temp.recall('s1'), gen_random_uuid()),
  'the session completes'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.record_session_set(%L, %L, '{"set_number":1,"actual_reps":1,"is_completed":true}'::jsonb, %L) $sql$,
      pg_temp.recall('s1'), pg_temp.se_for(pg_temp.recall('s1'), 'bulgarian-split-squat'), gen_random_uuid())),
    pg_temp.sqlstate_of(format($sql$ SELECT public.record_exercise_substitution(%L, %L,
      (SELECT id FROM public.exercises WHERE slug = 'diamond-push-up'), 'reps', 'other', %L) $sql$,
      pg_temp.recall('s1'), pg_temp.item_for(pg_temp.recall('ver'), 'bodyweight-squat'), gen_random_uuid())),
    pg_temp.sqlstate_of(format($sql$ SELECT public.complete_workout_session(%L, 'abandoned', 'other', NULL, NULL, %L) $sql$,
      pg_temp.recall('s1'), gen_random_uuid()))
  ],
  ARRAY['22000', '22000', '22000'],
  'a terminal (completed) session can never again be mutated: set recording, substitution and re-completion all fail with 22000'
);
RESET ROLE;

-- 5. Row-level locking: the serialization statements are present (behaviour proven ---
--    by the hosted concurrency probes; structural check mirrors Sprint 3's 010).
SELECT ok(
  (SELECT prosrc ~* 'FROM public\.profiles WHERE id = v_uid FOR UPDATE'
   FROM pg_proc WHERE oid = 'app_private.start_workout_session_internal(uuid, uuid, uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FROM public\.workout_sessions WHERE id = p_session_id FOR UPDATE'
       FROM pg_proc WHERE oid = 'app_private.record_session_set_internal(uuid, uuid, jsonb, uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FROM public\.workout_sessions WHERE id = p_session_id FOR UPDATE'
       FROM pg_proc WHERE oid = 'app_private.record_exercise_substitution_internal(uuid, uuid, uuid, text, text, uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FROM public\.workout_sessions WHERE id = p_session_id FOR UPDATE'
       FROM pg_proc WHERE oid = 'app_private.complete_workout_session_internal(uuid, text, text, jsonb, jsonb, uuid)'::regprocedure)
  AND (SELECT prosrc ~* 'FOR UPDATE' FROM pg_proc WHERE oid = 'app_private.sync_offline_session_bundle_internal(jsonb, uuid)'::regprocedure),
  'every mutation locks the athlete''s profile (start) or the target session (set/substitute/complete/sync) before writing'
);

-- 6. Offline: online start → interrupted connectivity → bundle sync continuation -----
SELECT pg_temp.act('b4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('s2', (public.start_workout_session(%L, %L) ->> 'session_id')::uuid) $sql$,
         pg_temp.recall('ver'), gen_random_uuid()),
  'a second session is started ONLINE'
);
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('bundlekey', %L::uuid) $sql$, gen_random_uuid()),
  'a fixed idempotency key is minted for the bundle sync'
);
-- Fixed so the replay below is BYTE-IDENTICAL (jsonb normalizes key order, but
-- a fresh gen_random_uuid() per call would still make the two payload hashes differ).
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('corr2', %L::uuid) $sql$, gen_random_uuid()),
  'a fixed client correlation id is minted for the bundle'
);
SELECT lives_ok(
  format($sql$ SELECT public.sync_offline_session_bundle(jsonb_build_object(
    'session_correlation_id', %L::uuid, 'existing_session_id', %L, 'workout_version_id', %L,
    'status', 'completed', 'started_at', (now() - interval '20 minutes')::text, 'completed_at', now()::text,
    'substitutions', jsonb_build_array(jsonb_build_object(
      'original_workout_item_id', %L, 'replacement_exercise_id', (SELECT id FROM public.exercises WHERE slug = 'diamond-push-up'),
      'performed_measurement_mode', 'reps', 'reason_code', 'equipment_unavailable')),
    'sets', jsonb_build_array(
      jsonb_build_object('workout_item_id', %L, 'set_number', 1, 'actual_reps', 12, 'is_completed', true),
      jsonb_build_object('workout_item_id', %L, 'set_number', 1, 'actual_duration_seconds', 45, 'is_completed', true)),
    'feedback', jsonb_build_object('difficulty_rating', 6, 'energy_level', 3),
    'private_feedback', jsonb_build_object('has_discomfort', false)
  ), %L) $sql$,
    pg_temp.recall('corr2'), pg_temp.recall('s2'), pg_temp.recall('ver'), pg_temp.item_for(pg_temp.recall('ver'), 'push-up'),
    pg_temp.item_for(pg_temp.recall('ver'), 'push-up'), pg_temp.item_for(pg_temp.recall('ver'), 'plank'),
    pg_temp.recall('bundlekey')),
  'the offline bundle (substitution + 2 sets + split feedback) syncs into the EXISTING online-started session'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[status::text, (completed_at IS NOT NULL)::text] FROM public.workout_sessions WHERE id = pg_temp.recall('s2')),
  ARRAY['completed', 'true'],
  'the continued session transitioned to completed with the bundle''s outcome'
);
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.session_modifications WHERE session_id = pg_temp.recall('s2')),
     (SELECT count(*) FROM public.session_sets ss JOIN public.session_exercises se ON se.id = ss.session_exercise_id WHERE se.session_id = pg_temp.recall('s2')),
     (SELECT count(*) FROM public.session_feedback WHERE session_id = pg_temp.recall('s2'))]),
  ARRAY[1::bigint, 2, 1],
  'exactly the bundle''s 1 substitution, 2 sets and 1 feedback row exist — zero data loss, zero duplication'
);

-- Replay idempotency: resending the IDENTICAL bundle payload must not duplicate anything.
SELECT pg_temp.act('b4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ SELECT public.sync_offline_session_bundle(jsonb_build_object(
      'session_correlation_id', %L::uuid, 'existing_session_id', %L, 'workout_version_id', %L,
      'status', 'completed', 'started_at', (now() - interval '20 minutes')::text, 'completed_at', now()::text,
      'substitutions', jsonb_build_array(jsonb_build_object(
        'original_workout_item_id', %L, 'replacement_exercise_id', (SELECT id FROM public.exercises WHERE slug = 'diamond-push-up'),
        'performed_measurement_mode', 'reps', 'reason_code', 'equipment_unavailable')),
      'sets', jsonb_build_array(
        jsonb_build_object('workout_item_id', %L, 'set_number', 1, 'actual_reps', 12, 'is_completed', true),
        jsonb_build_object('workout_item_id', %L, 'set_number', 1, 'actual_duration_seconds', 45, 'is_completed', true)),
      'feedback', jsonb_build_object('difficulty_rating', 6, 'energy_level', 3),
      'private_feedback', jsonb_build_object('has_discomfort', false)
    ), %L) $sql$,
    pg_temp.recall('corr2'), pg_temp.recall('s2'), pg_temp.recall('ver'), pg_temp.item_for(pg_temp.recall('ver'), 'push-up'),
    pg_temp.item_for(pg_temp.recall('ver'), 'push-up'), pg_temp.item_for(pg_temp.recall('ver'), 'plank'),
    pg_temp.recall('bundlekey'))),
  'ok',
  'resending the EXACT SAME bundle with the same idempotency key returns the cached success (no error)'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[
     (SELECT count(*) FROM public.session_modifications WHERE session_id = pg_temp.recall('s2')),
     (SELECT count(*) FROM public.session_sets ss JOIN public.session_exercises se ON se.id = ss.session_exercise_id WHERE se.session_id = pg_temp.recall('s2')),
     (SELECT count(*) FROM public.session_feedback WHERE session_id = pg_temp.recall('s2'))]),
  ARRAY[1::bigint, 2, 1],
  'the replay created NOTHING new: still exactly 1 modification, 2 sets, 1 feedback row'
);

-- 7. Offline: a session started AND finished entirely offline (no existing_session_id) -
SELECT pg_temp.act('b4000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($sql$ SELECT pg_temp.remember('s3', (public.sync_offline_session_bundle(jsonb_build_object(
    'session_correlation_id', gen_random_uuid(), 'workout_version_id', %L,
    'status', 'abandoned', 'abandonment_reason_code', 'time_constraint',
    'started_at', (now() - interval '2 hours')::text, 'completed_at', (now() - interval '100 minutes')::text,
    'sets', jsonb_build_array(jsonb_build_object('workout_item_id', %L, 'set_number', 1, 'actual_reps', 7, 'is_completed', true))
  ), gen_random_uuid()) ->> 'session_id')::uuid) $sql$,
    pg_temp.recall('ver'), pg_temp.item_for(pg_temp.recall('ver'), 'push-up')),
  'a session that started AND ended entirely offline is created from a single bundle with no existing_session_id'
);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[status::text, abandonment_reason_code, (started_at < now() - interval '1 hour')::text]
   FROM public.workout_sessions WHERE id = pg_temp.recall('s3')),
  ARRAY['abandoned', 'time_constraint', 'true'],
  'the brand-new offline session preserves the CLIENT''s own wall-clock started_at/completed_at and outcome'
);
SELECT is(
  (SELECT count(*) FROM public.session_sets ss JOIN public.session_exercises se ON se.id = ss.session_exercise_id WHERE se.session_id = pg_temp.recall('s3')),
  1::bigint,
  'its one set was correlated by the immutable workout_item_id and recorded'
);

SELECT * FROM finish();
ROLLBACK;
