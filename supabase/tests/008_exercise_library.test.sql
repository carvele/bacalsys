-- Sprint 2 · Task 2.11 — exercise library: schema invariants, column privileges,
-- visibility RLS, the private → pending_approval → approved | rejected state
-- machine, D4 approval authority, and fail-closed behaviour for inactive members.
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(67);

-- Helpers (data-modifying CTEs cannot be nested in subqueries, finding F-05):
--   affected(sql)  → row count of an UPDATE/DELETE run as the current role
--   insert_id(sql) → the id returned by an INSERT … RETURNING id::text
CREATE FUNCTION pg_temp.affected(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE n bigint;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;
CREATE FUNCTION pg_temp.insert_id(p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE v text;
BEGIN
  EXECUTE p_sql INTO v;
  RETURN v;
END;
$fn$;
-- ADR-002: functions are not executable by PUBLIC by default; rolled back with the test.
GRANT EXECUTE ON FUNCTION pg_temp.affected(text), pg_temp.insert_id(text) TO authenticated;

-- Fixtures -------------------------------------------------------------------------
--   …01 Athlete A (creator) · …02 Athlete B · …03 Coach (exercises:approve)
--   …04 Leader (no exercises:approve) · …05 Vice President · …06 suspended Coach
--   …07 President
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('e2000000-0000-4000-8000-000000000001', 'creator@s2ex.test', '{"full_name":"Creator"}'),
  ('e2000000-0000-4000-8000-000000000002', 'athlete.b@s2ex.test', '{"full_name":"Athlete B"}'),
  ('e2000000-0000-4000-8000-000000000003', 'coach@s2ex.test', '{"full_name":"Coach"}'),
  ('e2000000-0000-4000-8000-000000000004', 'leader@s2ex.test', '{"full_name":"Leader"}'),
  ('e2000000-0000-4000-8000-000000000005', 'vp@s2ex.test', '{"full_name":"VP"}'),
  ('e2000000-0000-4000-8000-000000000006', 'suspended.coach@s2ex.test', '{"full_name":"Suspended Coach"}'),
  ('e2000000-0000-4000-8000-000000000007', 'pres@s2ex.test', '{"full_name":"President"}');
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'e2000000-0000-4000-8000-00000000000%';
UPDATE public.profiles SET status = 'suspended' WHERE id = 'e2000000-0000-4000-8000-000000000006';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT f.profile_id::uuid, pos.id
FROM (VALUES
  ('e2000000-0000-4000-8000-000000000001', 'Athlete'),
  ('e2000000-0000-4000-8000-000000000002', 'Athlete'),
  ('e2000000-0000-4000-8000-000000000003', 'Coach'),
  ('e2000000-0000-4000-8000-000000000004', 'Leader'),
  ('e2000000-0000-4000-8000-000000000005', 'Vice President'),
  ('e2000000-0000-4000-8000-000000000006', 'Coach'),
  ('e2000000-0000-4000-8000-000000000007', 'President')
) AS f(profile_id, position_name)
JOIN public.positions pos ON pos.name = f.position_name;

-- 1. Schema, seeds & privileges ----------------------------------------------------
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exercises'::regclass),
  'RLS is enabled on exercises'
);
SELECT ok(
  (SELECT count(*) >= 32 FROM public.exercises WHERE status = 'approved' AND is_official AND created_by IS NULL),
  'official seed catalog is present (approved, official, no creator)'
);
SELECT is(
  (SELECT array_agg(DISTINCT category ORDER BY category) FROM public.exercises WHERE is_official AND created_by IS NULL),
  ARRAY['core', 'legs', 'mobility', 'pull', 'push', 'skill'],
  'seeds cover all six Feature 3.1 categories'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.exercises', 'SELECT'),
  'anon cannot read exercises'
);
SELECT ok(
  NOT has_column_privilege('authenticated', 'public.exercises', 'status', 'UPDATE')
  AND NOT has_column_privilege('authenticated', 'public.exercises', 'is_official', 'UPDATE')
  AND NOT has_column_privilege('authenticated', 'public.exercises', 'reviewed_by', 'UPDATE')
  AND NOT has_column_privilege('authenticated', 'public.exercises', 'reviewed_at', 'UPDATE')
  AND NOT has_column_privilege('authenticated', 'public.exercises', 'rejection_reason', 'UPDATE'),
  'no UPDATE privilege on workflow columns (status, is_official, reviewed_*, rejection_reason)'
);
SELECT ok(
  has_column_privilege('authenticated', 'public.exercises', 'name', 'UPDATE')
  AND has_column_privilege('authenticated', 'public.exercises', 'description', 'UPDATE')
  AND has_column_privilege('authenticated', 'public.exercises', 'measurement_types', 'UPDATE')
  AND has_column_privilege('authenticated', 'public.exercises', 'equipment_needed', 'UPDATE'),
  'UPDATE granted exclusively on creator-editable content columns'
);
SELECT ok(
  NOT has_column_privilege('authenticated', 'public.exercises', 'status', 'INSERT')
  AND NOT has_column_privilege('authenticated', 'public.exercises', 'is_official', 'INSERT'),
  'no INSERT privilege on workflow columns'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.exercises', 'DELETE'),
  'authenticated cannot DELETE exercises'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.submit_custom_exercise(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.review_custom_exercise(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.submit_custom_exercise(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.review_custom_exercise(uuid, text, text)', 'EXECUTE'),
  'workflow wrappers: authenticated only, never anon'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, slug, category, measurement_types, equipment_needed, is_official, status)
     VALUES ('Bad', 'bad', 'push', '{reps}', '{none}', false, 'private') $$,
  '23514', NULL,
  'exercise_creator_check: a non-approved exercise requires created_by'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, slug, category, measurement_types, equipment_needed, is_official, status, created_by)
     VALUES ('Bad', 'bad-2', 'push', '{reps}', '{none}', true, 'private', 'e2000000-0000-4000-8000-000000000001') $$,
  '23514', NULL,
  'exercise_status_consistency: a private exercise cannot be official'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, slug, category, measurement_types, equipment_needed, is_official, status)
     VALUES ('Push-up Copy', 'push-up', 'push', '{reps}', '{none}', true, 'approved') $$,
  '23505', NULL,
  'approved_exercise_slug_idx: approved slugs are globally unique'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, slug, category, measurement_types, equipment_needed, created_by)
     VALUES ('Bad Category', 'bad-cat', 'cardio', '{reps}', '{none}', 'e2000000-0000-4000-8000-000000000001') $$,
  '23514', NULL,
  'category must be one of the Feature 3.1 categories'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, slug, category, measurement_types, equipment_needed, created_by)
     VALUES ('Bad Measure', 'bad-measure', 'push', '{calories}', '{none}', 'e2000000-0000-4000-8000-000000000001') $$,
  '23514', NULL,
  'measurement types must be Feature 3.1 measurement types'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, slug, category, measurement_types, equipment_needed, created_by)
     VALUES ('Bad Equip', 'bad-equip', 'push', '{reps}', '{none,rings}', 'e2000000-0000-4000-8000-000000000001') $$,
  '23514', NULL,
  '"none" (bodyweight) cannot be combined with equipment'
);

-- 2. Athlete A creates "Weighted Ring Dips" ------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$ SELECT set_config('test.ex', pg_temp.insert_id($q$INSERT INTO public.exercises (name, category, description, measurement_types, equipment_needed, created_by)
         VALUES ('Weighted Ring Dips', 'push', 'Ring dips with a vest.', '{reps,added_weight}', '{rings,weight_vest}',
                 'e2000000-0000-4000-8000-000000000001')
         RETURNING id::text$q$), true) $$,
  'Athlete creates a custom exercise'
);
SELECT ok(
  (SELECT status = 'private' AND NOT is_official AND slug = 'weighted-ring-dips'
   FROM public.exercises WHERE id = current_setting('test.ex')::uuid),
  'status = private, is_official = false, slug derived from the name'
);
SELECT is(
  (SELECT count(*) FROM public.exercises WHERE id = current_setting('test.ex')::uuid),
  1::bigint,
  'creator queries catalog: 1 row returned (visible to creator)'
);
SELECT throws_ok(
  $$ UPDATE public.exercises SET status = 'approved' WHERE id = current_setting('test.ex')::uuid $$,
  '42501', NULL,
  'creator cannot directly UPDATE exercise.status'
);
SELECT throws_ok(
  $$ UPDATE public.exercises SET is_official = true WHERE id = current_setting('test.ex')::uuid $$,
  '42501', NULL,
  'creator cannot directly UPDATE exercise.is_official'
);
SELECT throws_ok(
  $$ UPDATE public.exercises SET reviewed_by = 'e2000000-0000-4000-8000-000000000001' WHERE id = current_setting('test.ex')::uuid $$,
  '42501', NULL,
  'creator cannot forge reviewed_by'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, category, measurement_types, equipment_needed, created_by, status)
     VALUES ('Forged', 'core', '{reps}', '{none}', 'e2000000-0000-4000-8000-000000000001', 'approved') $$,
  '42501', NULL,
  'creator cannot INSERT an exercise with a workflow status'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, category, measurement_types, equipment_needed, created_by)
     VALUES ('Impersonated', 'core', '{reps}', '{none}', 'e2000000-0000-4000-8000-000000000002') $$,
  '42501', NULL,
  'creator cannot INSERT an exercise in another member''s name (RLS WITH CHECK)'
);
SELECT is(
  pg_temp.affected($q$UPDATE public.exercises SET description = 'Ring dips, vest, full range.'
              WHERE id = current_setting('test.ex')::uuid$q$),
  1::bigint,
  'creator can edit content of their private draft'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'approve') $$,
  '42501', NULL,
  'an Athlete cannot use review_custom_exercise'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE id = current_setting('test.ex')::uuid $$,
  'other athlete queries catalog: 0 rows returned'
);
SELECT is(
  pg_temp.affected($q$UPDATE public.exercises SET description = 'hacked' WHERE id = current_setting('test.ex')::uuid$q$),
  0::bigint,
  'another member''s edit affects 0 rows'
);
SELECT throws_ok(
  $$ SELECT public.submit_custom_exercise(current_setting('test.ex')::uuid) $$,
  '42501', NULL,
  'only the creator can submit'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE id = current_setting('test.ex')::uuid $$,
  'coach (even with exercises:approve) queries catalog: 0 rows while private'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'approve') $$,
  '55000', NULL,
  'illegal transition: private → approve is rejected'
);
RESET ROLE;

-- 3. Submit ------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT status FROM public.submit_custom_exercise(current_setting('test.ex')::uuid)),
  'pending_approval',
  'creator submits via public.submit_custom_exercise(): status = pending_approval'
);
SELECT throws_ok(
  $$ SELECT public.submit_custom_exercise(current_setting('test.ex')::uuid) $$,
  '55000', NULL,
  'a pending exercise cannot be submitted again'
);
SELECT is(
  pg_temp.affected($q$UPDATE public.exercises SET description = 'late edit' WHERE id = current_setting('test.ex')::uuid$q$),
  0::bigint,
  'a submitted exercise can no longer be edited by its creator'
);
SELECT is(
  (SELECT count(*) FROM public.exercises WHERE id = current_setting('test.ex')::uuid),
  1::bigint,
  'creator still sees their pending exercise'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.exercises WHERE status = 'pending_approval' AND id = current_setting('test.ex')::uuid),
  1::bigint,
  'user with exercises:approve (Coach) queries review queue: 1 row returned'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE id = current_setting('test.ex')::uuid $$,
  'ordinary member queries catalog: 0 rows while pending'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE status = 'pending_approval' $$,
  'Leader (no exercises:approve, D4) cannot see the review queue'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'approve') $$,
  '42501', NULL,
  'Leader cannot approve exercises (D4)'
);
RESET ROLE;

-- 4. Suspended members fail closed -------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE status = 'pending_approval' $$,
  'suspended Coach cannot see the review queue'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'approve') $$,
  '42501', NULL,
  'suspended Coach cannot use exercises:approve (wrapper)'
);
SELECT throws_ok(
  $$ SELECT app_private.review_custom_exercise_internal(current_setting('test.ex')::uuid, 'approve', NULL) $$,
  '42501', NULL,
  'suspended Coach is rejected by the internal implementation too'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises $$,
  'suspended member sees nothing at all, not even the official catalog'
);
RESET ROLE;

-- 5. Review guards, then approve ---------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'reject') $$,
  '22023', NULL,
  'illegal transition: reject without a reason'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'reject', '   ') $$,
  '22023', NULL,
  'a blank rejection reason is rejected'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'publish') $$,
  '22023', NULL,
  'an unknown review action is rejected'
);
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise('e2000000-0000-4000-8000-0000000000ff', 'approve') $$,
  'P0002', NULL,
  'reviewing an unknown exercise is rejected'
);
SELECT is(
  (SELECT status FROM public.review_custom_exercise(current_setting('test.ex')::uuid, 'approve')),
  'approved',
  'reviewer approves via public.review_custom_exercise(id, ''approve'')'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '', true);
SELECT ok(
  (SELECT is_official AND reviewed_by = 'e2000000-0000-4000-8000-000000000003' AND reviewed_at IS NOT NULL
          AND rejection_reason IS NULL
   FROM public.exercises WHERE id = current_setting('test.ex')::uuid),
  'approved: is_official = true, reviewed_by and reviewed_at populated'
);

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.exercises WHERE id = current_setting('test.ex')::uuid),
  1::bigint,
  'all active members query catalog: 1 row returned (Athlete B)'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*) FROM public.exercises WHERE id = current_setting('test.ex')::uuid),
  1::bigint,
  'all active members query catalog: 1 row returned (Leader)'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.submit_custom_exercise(current_setting('test.ex')::uuid) $$,
  '55000', NULL,
  'illegal transition: approved → submit is rejected'
);
SELECT is(
  pg_temp.affected($q$UPDATE public.exercises SET name = 'Renamed' WHERE id = current_setting('test.ex')::uuid$q$),
  0::bigint,
  'an approved exercise can no longer be edited by its creator'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.ex')::uuid, 'reject', 'too late') $$,
  '55000', NULL,
  'an approved exercise cannot be reviewed again'
);

-- 6. Rejection branch (VP holds exercises:approve) --------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT set_config('test.rej', pg_temp.insert_id($q$INSERT INTO public.exercises (name, category, measurement_types, equipment_needed, created_by)
    VALUES ('Weighted Ring Dips Variant', 'push', '{reps}', '{rings}', 'e2000000-0000-4000-8000-000000000001')
    RETURNING id::text$q$), true);
SELECT is(
  (SELECT status FROM public.submit_custom_exercise(current_setting('test.rej')::uuid)),
  'pending_approval',
  'second exercise submitted'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT status FROM public.review_custom_exercise(current_setting('test.rej')::uuid, 'reject', 'Form cues unclear')),
  'rejected',
  'VP rejects via public.review_custom_exercise(id, ''reject'', ''Form cues unclear'')'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT rejection_reason FROM public.exercises WHERE id = current_setting('test.rej')::uuid),
  'Form cues unclear',
  'creator views the custom exercise and sees the rejection reason'
);
SELECT throws_ok(
  $$ SELECT public.submit_custom_exercise(current_setting('test.rej')::uuid) $$,
  '55000', NULL,
  'a rejected exercise cannot be resubmitted'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE id = current_setting('test.rej')::uuid $$,
  'ordinary members query catalog: 0 rows for the rejected exercise'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE id = current_setting('test.rej')::uuid $$,
  'a rejected exercise leaves the review queue'
);
RESET ROLE;

-- 7. Slug clash on approval, suspended creator, audit -----------------------------
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT set_config('test.dup', pg_temp.insert_id($q$INSERT INTO public.exercises (name, category, measurement_types, equipment_needed, created_by)
    VALUES ('Push-up', 'push', '{reps}', '{none}', 'e2000000-0000-4000-8000-000000000002')
    RETURNING id::text$q$), true);
SELECT is(
  (SELECT status FROM public.submit_custom_exercise(current_setting('test.dup')::uuid)),
  'pending_approval',
  'a custom exercise may reuse an official slug while not approved'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.review_custom_exercise(current_setting('test.dup')::uuid, 'approve') $$,
  '23505', NULL,
  'approving a duplicate of an official slug is rejected (approved slugs stay globally unique)'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '', true);
INSERT INTO public.exercises (id, name, category, measurement_types, equipment_needed, created_by)
VALUES ('e2000000-0000-4000-8000-0000000000d1', 'Draft Before Suspension', 'core', '{reps}', '{none}',
        'e2000000-0000-4000-8000-000000000001');
UPDATE public.profiles SET status = 'suspended' WHERE id = 'e2000000-0000-4000-8000-000000000001';

SELECT set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.exercises WHERE id = 'e2000000-0000-4000-8000-0000000000d1' $$,
  'suspended creator cannot see their private custom exercise'
);
SELECT is(
  pg_temp.affected($q$UPDATE public.exercises SET description = 'edit while suspended'
              WHERE id = 'e2000000-0000-4000-8000-0000000000d1'$q$),
  0::bigint,
  'suspended creator cannot edit their private custom exercise'
);
SELECT throws_ok(
  $$ SELECT public.submit_custom_exercise('e2000000-0000-4000-8000-0000000000d1') $$,
  '42501', NULL,
  'suspended creator cannot submit'
);
SELECT throws_ok(
  $$ INSERT INTO public.exercises (name, category, measurement_types, equipment_needed, created_by)
     VALUES ('New While Suspended', 'core', '{reps}', '{none}', 'e2000000-0000-4000-8000-000000000001') $$,
  '42501', NULL,
  'suspended member cannot create exercises'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '', true);
SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_logs
          WHERE entity_type = 'exercises' AND entity_id = current_setting('test.ex')
            AND action = 'exercises.update' AND new_values ->> 'status' = 'approved'
            AND actor_user_id = 'e2000000-0000-4000-8000-000000000003'),
  'audit: approval recorded with the reviewer as actor'
);
SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_logs
          WHERE entity_type = 'exercises' AND entity_id = current_setting('test.rej')
            AND new_values ->> 'status' = 'rejected'
            AND new_values ->> 'rejection_reason' = 'Form cues unclear'
            AND actor_user_id = 'e2000000-0000-4000-8000-000000000005'),
  'audit: rejection (with reason) recorded with the VP as actor'
);

SELECT * FROM finish();
ROLLBACK;
