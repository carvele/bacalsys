-- Sprint 5 · Task 5.8 (offline half) — sync_offline_session_bundle with assignment
-- occurrences: fully-offline linked sessions, the terminal outcome mapping,
-- STRUCTURAL late-sync reconciliation of a `missed` occurrence (F-S5-P15),
-- post-deadline / pre-schedule starts that must NOT reconcile, the offline
-- resilience fallback for legitimately deleted or cancelled occurrences (the
-- workout is preserved as a direct session, the occurrence is never recreated
-- or altered), ownership / version / continuation checks, and the ordinary
-- direct-session rules that still bind the fallback path.
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(24);

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
CREATE FUNCTION pg_temp.day(p_days integer) RETURNS date LANGUAGE sql AS $fn$
  SELECT ((now() AT TIME ZONE 'Asia/Manila')::date + p_days);
$fn$;
CREATE FUNCTION pg_temp.item_for(p_version uuid, p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT i.id FROM public.workout_items i JOIN public.workout_blocks b ON b.id = i.block_id JOIN public.exercises e ON e.id = i.exercise_id
  WHERE b.workout_version_id = p_version AND e.slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.asg(p_targets uuid[], p_offset integer) RETURNS uuid LANGUAGE sql AS $fn$
  SELECT (public.create_workout_assignment(pg_temp.recall('tpl'), pg_temp.recall('ver'), p_targets, pg_temp.day(p_offset), false, NULL, NULL, gen_random_uuid()) ->> 'assignment_id')::uuid;
$fn$;
CREATE FUNCTION pg_temp.occ_of(p_assignment uuid) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT id FROM public.assignment_occurrences WHERE assignment_id = p_assignment;
$fn$;
CREATE FUNCTION pg_temp.occ_status(p_id uuid) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT status FROM public.assignment_occurrences WHERE id = p_id;
$fn$;
-- The OfflineSessionBundle wire shape (Sprint 4) plus the nullable occurrence id (Sprint 5).
CREATE FUNCTION pg_temp.bundle(p_version uuid, p_occ uuid, p_status text, p_started timestamptz, p_completed timestamptz,
  p_with_set boolean DEFAULT true, p_existing uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'workout_version_id', p_version,
    'assignment_occurrence_id', p_occ,
    'existing_session_id', p_existing,
    'status', p_status,
    'abandonment_reason_code', CASE WHEN p_status = 'abandoned' THEN 'time_constraint' END,
    'started_at', p_started,
    'completed_at', p_completed,
    'sets', CASE WHEN p_with_set THEN jsonb_build_array(jsonb_build_object(
        'workout_item_id', pg_temp.item_for(p_version, 'push-up'), 'set_number', 1, 'actual_reps', 5, 'is_completed', true))
      ELSE '[]'::jsonb END
  ));
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text), pg_temp.act(text), pg_temp.remember(text, uuid), pg_temp.recall(text), pg_temp.day(integer),
  pg_temp.item_for(uuid, text), pg_temp.asg(uuid[], integer), pg_temp.occ_of(uuid), pg_temp.occ_status(uuid),
  pg_temp.bundle(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid) TO authenticated;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete A1   …02 Athlete A2   …03 Coach C1 (coaches A1 and A2)   …04 Leader
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('c5000000-0000-4000-8000-000000000001', 'a1@s5c.test', '{"full_name":"Athlete One"}'),
  ('c5000000-0000-4000-8000-000000000002', 'a2@s5c.test', '{"full_name":"Athlete Two"}'),
  ('c5000000-0000-4000-8000-000000000003', 'c1@s5c.test', '{"full_name":"Coach One"}'),
  ('c5000000-0000-4000-8000-000000000004', 'la@s5c.test', '{"full_name":"Leader"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'c5000000-0000-4000-8000-0000000000%';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id FROM (VALUES
  ('c5000000-0000-4000-8000-000000000001', 'Athlete'), ('c5000000-0000-4000-8000-000000000002', 'Athlete'),
  ('c5000000-0000-4000-8000-000000000003', 'Coach'), ('c5000000-0000-4000-8000-000000000004', 'Leader')
) AS f(profile_id, position_name) JOIN public.positions pos ON pos.name = f.position_name;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('c5000000-0000-4000-8000-000000000001', 'c5000000-0000-4000-8000-000000000003', 'c5000000-0000-4000-8000-000000000004'),
  ('c5000000-0000-4000-8000-000000000002', 'c5000000-0000-4000-8000-000000000003', 'c5000000-0000-4000-8000-000000000004');

SELECT pg_temp.act('c5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('tpl', (public.create_workout_template(
  'Offline Fixture Routine', NULL, 'organization',
  jsonb_build_array(jsonb_build_object(
    'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
        'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 10))),
      jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'plank'),
        'measurement_mode', 'duration', 'sets', jsonb_build_array(jsonb_build_object('target_duration_seconds', 30))))))
) ->> 'template_id')::uuid);
RESET ROLE;
SELECT pg_temp.remember('ver', id) FROM public.workout_versions WHERE template_id = pg_temp.recall('tpl');
-- A second version (never assigned) to provoke the pinned-version check.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('ver2', (public.publish_new_workout_version(pg_temp.recall('tpl'), 'v2', jsonb_build_array(jsonb_build_object(
  'title', 'Main', 'block_type', 'standard_set', 'items', jsonb_build_array(
    jsonb_build_object('exercise_id', (SELECT id FROM public.exercises WHERE slug = 'push-up'),
      'measurement_mode', 'reps', 'sets', jsonb_build_array(jsonb_build_object('target_reps', 8)))))))->> 'version_id')::uuid);
-- Assignments (each is a single-date assignment with ONE occurrence for A1, unless noted).
SELECT pg_temp.remember('a_today', pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], 0));
SELECT pg_temp.remember('a_part',  pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], 1));
SELECT pg_temp.remember('a_abn',   pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], 2));
SELECT pg_temp.remember('a_late',  pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], -1));
SELECT pg_temp.remember('a_post',  pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], -2));
SELECT pg_temp.remember('a_pre',   pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], -3));
SELECT pg_temp.remember('a_cancel', pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], 4));
SELECT pg_temp.remember('a_cxpast', pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], -4));
SELECT pg_temp.remember('a_a2',     pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000002']::uuid[], 5));
SELECT pg_temp.remember('a_ver',    pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], 6));
SELECT pg_temp.remember('a_cont',   pg_temp.asg(ARRAY['c5000000-0000-4000-8000-000000000001']::uuid[], 7));
RESET ROLE;
SELECT pg_temp.remember('o_' || k, pg_temp.occ_of(pg_temp.recall(k))) FROM unnest(ARRAY['a_today', 'a_part', 'a_abn', 'a_late', 'a_post', 'a_pre', 'a_cancel', 'a_cxpast', 'a_a2', 'a_ver', 'a_cont']) AS k;

-- The overdue job runs (as it would hourly): the three past-dated occurrences go missed, and the
-- cancelled assignment's overdue occurrence is preserved (F-S5-P12) alongside them.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000004');
SET LOCAL ROLE authenticated;
SELECT public.cancel_workout_assignment(pg_temp.recall('a_cancel'), gen_random_uuid());
SELECT public.cancel_workout_assignment(pg_temp.recall('a_cxpast'), gen_random_uuid());
RESET ROLE;
SELECT app_private.mark_overdue_assignments_as_missed();
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_late')), pg_temp.occ_status(pg_temp.recall('o_a_post')), pg_temp.occ_status(pg_temp.recall('o_a_pre')),
        pg_temp.occ_status(pg_temp.recall('o_a_cxpast')),
        (SELECT count(*)::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('a_cancel'))],
  ARRAY['missed', 'missed', 'missed', 'missed', '0'],
  'fixture check: the overdue occurrences are missed (including the cancelled assignment''s preserved one); the cancelled future occurrence is gone'
);

-- 1. Fully-offline session against an UPCOMING occurrence ---------------------------------
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('bk1', gen_random_uuid());
SELECT pg_temp.remember('b1_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_today'), 'completed', now() - interval '2 hours', now() - interval '1 hour'),
  pg_temp.recall('bk1')) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[o.status, (o.completed_at = s.completed_at)::text, (s.started_at = now() - interval '2 hours')::text, s.status,
                (SELECT count(*)::text FROM public.audit_logs WHERE action = 'reconciled_from_missed' AND entity_id = o.id::text)]
   FROM public.assignment_occurrences o JOIN public.workout_sessions s ON s.assignment_occurrence_id = o.id WHERE o.id = pg_temp.recall('o_a_today')),
  ARRAY['completed', 'true', 'true', 'completed', '0'],
  'a fully-offline workout links to its upcoming occurrence, keeps the CLIENT''s wall-clock times and completes it (no reconciliation involved)'
);
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    (public.sync_offline_session_bundle(
      pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_today'), 'completed', now() - interval '2 hours', now() - interval '1 hour'),
      pg_temp.recall('bk1')) ->> 'session_id'),
    (SELECT count(*)::text FROM public.workout_sessions WHERE assignment_occurrence_id = pg_temp.recall('o_a_today'))
  ],
  ARRAY[pg_temp.recall('b1_sid')::text, '1'],
  'replaying the same bundle + key returns the cached session and creates no second one'
);
-- Terminal mapping: abandoned WITH a set -> partially_completed; abandoned with NO set -> abandoned.
SELECT public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_part'), 'abandoned', now() - interval '5 hours', now() - interval '4 hours', true), gen_random_uuid());
SELECT public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_abn'), 'abandoned', now() - interval '7 hours', now() - interval '6 hours', false), gen_random_uuid());
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_part')), pg_temp.occ_status(pg_temp.recall('o_a_abn'))],
  ARRAY['partially_completed', 'abandoned'],
  'an offline abandoned bundle maps to partially_completed (>= 1 set) or abandoned (0 sets) exactly like the online path'
);

-- 2. Structural late-sync reconciliation of a MISSED occurrence (F-S5-P15) ----------------------
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('b2_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_late'), 'completed',
    (SELECT scheduled_at + interval '3 hours' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_late')),
    (SELECT scheduled_at + interval '4 hours' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_late'))),
  gen_random_uuid()) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  (SELECT ARRAY[o.status, (o.completed_at = s.completed_at)::text, s.status, (s.assignment_occurrence_id = o.id)::text,
                (s.started_at = o.scheduled_at + interval '3 hours')::text]
   FROM public.assignment_occurrences o JOIN public.workout_sessions s ON s.assignment_occurrence_id = o.id WHERE o.id = pg_temp.recall('o_a_late')),
  ARRAY['completed', 'true', 'completed', 'true', 'true'],
  'F-S5-P15: an offline workout started BEFORE the deadline reconciles a MISSED occurrence to completed, keeping the client''s start time'
);
SELECT is(
  (SELECT ARRAY[actor_type::text, (actor_user_id = 'c5000000-0000-4000-8000-000000000001')::text, entity_type,
                old_values ->> 'status', new_values ->> 'status', new_values ->> 'reason',
                (new_values ->> 'session_id' = pg_temp.recall('b2_sid')::text)::text]
   FROM public.audit_logs WHERE action = 'reconciled_from_missed' AND entity_id = pg_temp.recall('o_a_late')::text),
  ARRAY['user', 'true', 'assignment_occurrence', 'missed', 'completed', 'offline_started_before_due', 'true'],
  'the reconciliation is audited as reconciled_from_missed by the athlete (actor_type user), recording old/new status, the reason and the session'
);
SELECT is(
  (SELECT count(*) FROM public.audit_logs WHERE entity_type = 'assignment_occurrence' AND entity_id = pg_temp.recall('o_a_late')::text AND actor_type = 'cron'),
  1::bigint,
  'the earlier upcoming -> missed transition remains in the audit trail as a cron event (history is append-only)'
);
-- Post-deadline start: the occurrence STAYS missed, the workout is kept as an unassigned session.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('b3_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_post'), 'completed',
    (SELECT due_datetime + interval '1 minute' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_post')),
    (SELECT due_datetime + interval '30 minutes' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_post'))),
  gen_random_uuid()) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_post')),
        (SELECT assignment_occurrence_id::text FROM public.workout_sessions WHERE id = pg_temp.recall('b3_sid')),
        (SELECT status FROM public.workout_sessions WHERE id = pg_temp.recall('b3_sid')),
        (SELECT count(*)::text FROM public.audit_logs WHERE action = 'reconciled_from_missed' AND entity_id = pg_temp.recall('o_a_post')::text)],
  ARRAY['missed', NULL, 'completed', '0'],
  'F-S5-P15: a workout that started AT/AFTER the deadline does NOT reconcile — the occurrence stays missed and the session is preserved unassigned'
);
-- A start BEFORE the occurrence's scheduled_at is also outside the adherence window.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('b4_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_pre'), 'completed',
    (SELECT scheduled_at - interval '2 hours' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_pre')),
    (SELECT scheduled_at - interval '1 hour' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_pre'))),
  gen_random_uuid()) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_pre')), (SELECT assignment_occurrence_id::text FROM public.workout_sessions WHERE id = pg_temp.recall('b4_sid'))],
  ARRAY['missed', NULL],
  'a workout started BEFORE scheduled_at is outside [scheduled_at, due_datetime): the occurrence stays missed, the session is unassigned'
);
-- Reconciliation is all-or-nothing: an active session elsewhere aborts it and the occurrence stays missed.
INSERT INTO public.workout_sessions (id, athlete_id, workout_version_id, status, started_at)
VALUES ('c5000000-0000-4000-8000-0000000000a1', 'c5000000-0000-4000-8000-000000000001', pg_temp.recall('ver'), 'in_progress', now() - interval '10 minutes');
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(%L::jsonb, gen_random_uuid()) $sql$,
    pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_cxpast'), 'completed', now() - interval '3 days', now() - interval '3 days' + interval '1 hour'))),
  '23505',
  'the ordinary one-active-session rule still binds every offline sync (23505)'
);
RESET ROLE;
DELETE FROM public.workout_sessions WHERE id = 'c5000000-0000-4000-8000-0000000000a1';

-- 3. Offline resilience: a deleted / cancelled occurrence never dead-letters the workout ----------
-- a_cancel's future occurrence was deleted by cancellation while the athlete was offline.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('gone_occ', gen_random_uuid());
SELECT pg_temp.remember('b5_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('gone_occ'), 'completed', now() - interval '2 hours', now() - interval '1 hour'),
  gen_random_uuid()) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[(SELECT assignment_occurrence_id::text FROM public.workout_sessions WHERE id = pg_temp.recall('b5_sid')),
        (SELECT status FROM public.workout_sessions WHERE id = pg_temp.recall('b5_sid')),
        (SELECT count(*)::text FROM public.assignment_occurrences WHERE id = pg_temp.recall('gone_occ'))],
  ARRAY[NULL, 'completed', '0'],
  'F-S5-P15: a workout referencing an occurrence that no longer exists is preserved as a direct session — the occurrence is NOT resurrected'
);
SELECT is(
  ARRAY[(SELECT status FROM public.workout_assignments WHERE id = pg_temp.recall('a_cancel')),
        (SELECT count(*)::text FROM public.assignment_occurrences WHERE assignment_id = pg_temp.recall('a_cancel'))],
  ARRAY['cancelled', '0'],
  '...and the cancelled assignment''s adherence is untouched (still cancelled, still no occurrences)'
);
-- The cancelled assignment's PRESERVED overdue occurrence (missed) also must not be touched or linked.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('b6_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_cxpast'), 'completed',
    (SELECT scheduled_at + interval '2 hours' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_cxpast')),
    (SELECT scheduled_at + interval '3 hours' FROM public.assignment_occurrences WHERE id = pg_temp.recall('o_a_cxpast'))),
  gen_random_uuid()) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_cxpast')), (SELECT assignment_occurrence_id::text FROM public.workout_sessions WHERE id = pg_temp.recall('b6_sid'))],
  ARRAY['missed', NULL],
  'an occurrence of a CANCELLED assignment is never reconciled or linked: the workout is preserved unassigned and the occurrence stays as it was'
);
-- The fallback is still a DIRECT session: every ordinary rule applies.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    -- an unavailable version
    pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(jsonb_set(%L::jsonb, '{workout_version_id}', to_jsonb(gen_random_uuid()::text)), gen_random_uuid()) $sql$,
      pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('gone_occ'), 'completed', now() - interval '2 hours', now() - interval '1 hour'))),
    -- a set correlated to an item that is not part of the version (lineage)
    pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(jsonb_set(%L::jsonb, '{sets,0,workout_item_id}', to_jsonb(gen_random_uuid()::text)), gen_random_uuid()) $sql$,
      pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('gone_occ'), 'completed', now() - interval '2 hours', now() - interval '1 hour'))),
    -- a mode-invalid actual set (duration on a reps item)
    pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(jsonb_set(%L::jsonb, '{sets,0,actual_duration_seconds}', '30'::jsonb), gen_random_uuid()) $sql$,
      pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('gone_occ'), 'completed', now() - interval '2 hours', now() - interval '1 hour')))
  ],
  ARRAY['P0002', '22000', '22023'],
  'the direct-session fallback still enforces version availability, prescription lineage and mode validation'
);
RESET ROLE;

-- 4. Ownership, pinned version, existing execution ---------------------------------------------
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(%L::jsonb, gen_random_uuid()) $sql$,
    pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_a2'), 'completed', now() - interval '2 hours', now() - interval '1 hour'))),
  '42501',
  'a bundle may not claim ANOTHER athlete''s occurrence (42501)'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(%L::jsonb, gen_random_uuid()) $sql$,
    pg_temp.bundle(pg_temp.recall('ver2'), pg_temp.recall('o_a_ver'), 'completed', now() - interval '2 hours', now() - interval '1 hour'))),
  '22000',
  'a bundle whose version differs from the occurrence''s pinned version fails 22000'
);
SELECT pg_temp.remember('b7_sid', (public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_today'), 'completed', now() - interval '9 hours', now() - interval '8 hours'),
  gen_random_uuid()) ->> 'session_id')::uuid);
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_today')),
        (SELECT assignment_occurrence_id::text FROM public.workout_sessions WHERE id = pg_temp.recall('b7_sid')),
        (SELECT count(*)::text FROM public.workout_sessions WHERE assignment_occurrence_id = pg_temp.recall('o_a_today'))],
  ARRAY['completed', NULL, '1'],
  'an occurrence that already has its own execution is not linked twice: the second workout is preserved as an unassigned session'
);
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(jsonb_set(%L::jsonb, '{assignment_occurrence_id}', '"not-a-uuid"'::jsonb), gen_random_uuid()) $sql$,
      pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_today'), 'completed', now() - interval '2 hours', now() - interval '1 hour'))),
    (public.sync_offline_session_bundle(
      pg_temp.bundle(pg_temp.recall('ver'), NULL, 'completed', now() - interval '12 hours', now() - interval '11 hours'), gen_random_uuid()) ->> 'occurrence_link')
  ],
  ARRAY['22023', 'unassigned'],
  'a malformed occurrence id is rejected (22023); a bundle with NO occurrence id is an ordinary direct session (Sprint 4 behaviour)'
);
RESET ROLE;

-- 5. Continuation of an ONLINE-started session --------------------------------------------------
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('s_cont', (public.start_workout_session(pg_temp.recall('ver'), gen_random_uuid(), pg_temp.recall('o_a_cont')) ->> 'session_id')::uuid);
SELECT is(
  ARRAY[
    -- omitting the occurrence id, or naming a different one, contradicts the session's own link
    pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(%L::jsonb, gen_random_uuid()) $sql$,
      pg_temp.bundle(pg_temp.recall('ver'), NULL, 'completed', now() - interval '1 hour', now(), true, pg_temp.recall('s_cont')))),
    pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(%L::jsonb, gen_random_uuid()) $sql$,
      pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_ver'), 'completed', now() - interval '1 hour', now(), true, pg_temp.recall('s_cont'))))
  ],
  ARRAY['22000', '22000'],
  'continuing an assigned session requires the bundle''s occurrence id to match the session''s own link (IS NOT DISTINCT FROM, else 22000)'
);
SELECT public.sync_offline_session_bundle(
  pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_cont'), 'completed', now() - interval '1 hour', now(), true, pg_temp.recall('s_cont')), gen_random_uuid());
RESET ROLE;
SELECT is(
  ARRAY[pg_temp.occ_status(pg_temp.recall('o_a_cont')), (SELECT status FROM public.workout_sessions WHERE id = pg_temp.recall('s_cont'))],
  ARRAY['completed', 'completed'],
  'a matching continuation completes the session AND moves its occurrence in_progress -> completed'
);
-- A direct session cannot be continued with an occurrence claim.
SELECT pg_temp.act('c5000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.remember('s_direct', (public.start_workout_session(pg_temp.recall('ver'), gen_random_uuid()) ->> 'session_id')::uuid);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.sync_offline_session_bundle(%L::jsonb, gen_random_uuid()) $sql$,
    pg_temp.bundle(pg_temp.recall('ver'), pg_temp.recall('o_a_ver'), 'completed', now() - interval '1 hour', now(), true, pg_temp.recall('s_direct')))),
  '22000',
  'a direct (unassigned) session cannot be continued with an occurrence claim (22000)'
);
RESET ROLE;

-- 6. Structural lock ordering & the no-GUC guarantee -------------------------------------------------
SELECT ok(
  (SELECT position('FROM public.workout_assignments WHERE id = v_occ.assignment_id FOR SHARE' IN prosrc) > 0
          AND position('FROM public.workout_assignments WHERE id = v_occ.assignment_id FOR SHARE' IN prosrc)
              < position('FROM public.assignment_occurrences WHERE id = v_occ_id FOR UPDATE' IN prosrc)
          AND position('FROM public.assignment_occurrences WHERE id = v_occ_id FOR UPDATE' IN prosrc)
              < position('FROM public.profiles WHERE id = v_uid FOR UPDATE' IN prosrc)
   FROM pg_proc WHERE oid = 'app_private.sync_offline_session_bundle_internal(jsonb, uuid)'::regprocedure),
  'F-S5-P12: the bundle path locks assignment FOR SHARE, then occurrence FOR UPDATE, then the profile — the same order as an online start'
);
SELECT ok(
  (SELECT prosrc !~* 'set_config|current_setting' FROM pg_proc WHERE oid = 'app_private.sync_offline_session_bundle_internal(jsonb, uuid)'::regprocedure)
  AND (SELECT position('INSERT INTO public.workout_sessions' IN prosrc) < position('SET status = ''in_progress'' WHERE id = v_link_occ' IN prosrc)
       FROM pg_proc WHERE oid = 'app_private.sync_offline_session_bundle_internal(jsonb, uuid)'::regprocedure),
  'F-S5-P15: the bundle reads no GUC, and inserts the linked session BEFORE moving the occurrence to in_progress'
);
SELECT ok(
  EXISTS (SELECT 1 FROM app_private.idempotency_keys WHERE mutation_type = 'SYNC_BUNDLE' AND key = pg_temp.recall('bk1') AND status = 'completed'),
  'bundle syncs stay scoped under the SYNC_BUNDLE idempotency type (no new type was needed)'
);

SELECT * FROM finish();
ROLLBACK;
