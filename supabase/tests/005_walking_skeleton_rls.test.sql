-- Sprint 1 DoD #9, #10, #11, #12, #14 — walking skeleton at the database layer:
-- Register → pending → President queue → atomic approval (Athlete) →
-- access context → RLS rejection of another member's protected record.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(30);

-- 1. Juan registers -------------------------------------------------------------
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('11111111-1111-4111-8111-111111111111', 'juan@test.local', '{"full_name":"Juan"}');

-- 2. Pending Juan is gated ------------------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT status FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111'),
  'pending_approval'::public.member_status,
  'pending member can read their own status (drives PendingApprovalScreen)'
);
SELECT is(
  public.get_my_access_context(),
  '{"positions":[],"permissions":[],"is_system_admin":false}'::jsonb,
  'pending member has no positions or permissions'
);
SELECT throws_ok(
  $$ SELECT public.approve_member('11111111-1111-4111-8111-111111111111') $$,
  '42501', NULL,
  'pending member cannot approve themselves'
);
SELECT throws_ok(
  $$ SELECT * FROM public.list_pending_members() $$,
  '42501', NULL,
  'pending member cannot read the approval queue'
);
RESET ROLE;

-- 3. President reviews the queue and approves -----------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT email FROM public.list_pending_members() WHERE id = '11111111-1111-4111-8111-111111111111'),
  'juan@test.local',
  'President sees Juan (with e-mail) in the Member Approval queue'
);
SELECT set_config('test.approval', public.approve_member('11111111-1111-4111-8111-111111111111')::text, true);
SELECT is(
  current_setting('test.approval')::jsonb ->> 'position',
  'Athlete',
  'approve_member reports the Athlete assignment'
);
SELECT throws_ok(
  $$ SELECT public.approve_member('11111111-1111-4111-8111-111111111111') $$,
  '55000', NULL,
  'an already-active member cannot be approved twice'
);
SELECT throws_ok(
  $$ SELECT public.approve_member('99999999-9999-4999-8999-999999999999') $$,
  'P0002', NULL,
  'approving an unknown member fails cleanly'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.list_pending_members() WHERE id = '11111111-1111-4111-8111-111111111111' $$,
  'Juan leaves the queue once approved'
);
RESET ROLE;

SELECT is(
  (SELECT status FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111'),
  'active'::public.member_status,
  'approval set status to active'
);
SELECT ok(
  (SELECT mp.assigned_by = '00000000-0000-4000-8000-00000000a001' AND mp.assigned_at IS NOT NULL AND mp.ended_at IS NULL
   FROM public.member_positions mp JOIN public.positions pos ON pos.id = mp.position_id
   WHERE mp.profile_id = '11111111-1111-4111-8111-111111111111' AND pos.name = 'Athlete'),
  'Athlete position recorded with assigned_at and assigned_by = President'
);

-- 4. Atomicity: a failure inside approval leaves no partial state -----------------
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('22222222-2222-4222-8222-222222222222', 'pedro@test.local', '{"full_name":"Pedro"}');
-- Pre-existing active Athlete row forces the insert step of approval to fail.
INSERT INTO public.member_positions (profile_id, position_id)
SELECT '22222222-2222-4222-8222-222222222222', id FROM public.positions WHERE name = 'Athlete';

SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.approve_member('22222222-2222-4222-8222-222222222222') $$,
  '23505', NULL,
  'approval aborts when the position insert fails'
);
RESET ROLE;
SELECT is(
  (SELECT status FROM public.profiles WHERE id = '22222222-2222-4222-8222-222222222222'),
  'pending_approval'::public.member_status,
  'status update was rolled back with the failed insert (atomic approval)'
);

-- 5. Juan (now active) loads his access context ---------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  public.get_my_access_context(),
  '{"positions":["Athlete"],"permissions":[],"is_system_admin":false}'::jsonb,
  'approved Juan receives the Athlete access context'
);

-- 6. Unauthorized access to another member's protected record ------------------
SELECT is_empty(
  $$ SELECT 1 FROM public.profiles WHERE id = '00000000-0000-4000-8000-00000000a001' $$,
  'RLS: Athlete cannot read another member''s profile'
);
SELECT is(
  (SELECT count(*) FROM public.profiles),
  1::bigint,
  'RLS: Athlete sees exactly one profile — their own'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.member_positions WHERE profile_id <> '11111111-1111-4111-8111-111111111111' $$,
  'RLS: Athlete cannot read other members'' positions'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.user_system_roles $$,
  'RLS: Athlete cannot read system role assignments'
);
-- RLS filters UPDATE targets silently (0 rows affected); the effect is
-- asserted below by "President profile is untouched".
SELECT lives_ok(
  $$ UPDATE public.profiles SET full_name = 'Hacked' WHERE id = '00000000-0000-4000-8000-00000000a001' $$,
  'RLS: Athlete''s UPDATE of another member''s profile matches no rows'
);
SELECT throws_ok(
  $$ UPDATE public.profiles SET status = 'active' WHERE id = '11111111-1111-4111-8111-111111111111' $$,
  '42501', NULL,
  'Athlete cannot change their own status (column not granted)'
);
SELECT throws_ok(
  $$ INSERT INTO public.member_positions (profile_id, position_id)
     SELECT '11111111-1111-4111-8111-111111111111', id FROM public.positions WHERE name = 'President' $$,
  '42501', NULL,
  'Athlete cannot grant themselves a position'
);
SELECT throws_ok(
  $$ DELETE FROM public.profiles WHERE id = '00000000-0000-4000-8000-00000000a001' $$,
  '42501', NULL,
  'Athlete cannot delete profiles'
);
SELECT lives_ok(
  $$ UPDATE public.profiles SET full_name = 'Juan Dela Cruz' WHERE id = '11111111-1111-4111-8111-111111111111' $$,
  'Athlete can edit their own display name'
);
RESET ROLE;

SELECT is(
  (SELECT full_name FROM public.profiles WHERE id = '00000000-0000-4000-8000-00000000a001'),
  'Seed President',
  'President profile is untouched'
);

-- 7. Anonymous callers get nothing ----------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT throws_ok(
  $$ SELECT 1 FROM public.profiles $$,
  '42501', NULL,
  'anon: permission denied on profiles'
);
SELECT throws_ok(
  $$ SELECT public.get_my_access_context() $$,
  '42501', NULL,
  'anon: permission denied on get_my_access_context()'
);
RESET ROLE;

-- 8. Positive visibility and organization isolation -----------------------------
INSERT INTO public.organizations (id, name, slug) VALUES ('0000000f-0000-4000-8000-000000000001', 'Other Club', 'other-club');
INSERT INTO public.branches (id, organization_id, name) VALUES ('0000000f-0000-4000-8000-000000000101', '0000000f-0000-4000-8000-000000000001', 'Other Branch');
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('33333333-3333-4333-8333-333333333333', 'outsider@test.local', '{"full_name":"Outsider"}');
UPDATE public.profiles SET home_branch_id = '0000000f-0000-4000-8000-000000000101'
WHERE id = '33333333-3333-4333-8333-333333333333';

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT isnt_empty(
  $$ SELECT 1 FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111' $$,
  'President (members:view_all) can read a member profile in their organization'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.profiles WHERE id = '33333333-3333-4333-8333-333333333333' $$,
  'President cannot read a profile from another organization'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.list_pending_members() WHERE id = '33333333-3333-4333-8333-333333333333' $$,
  'other-organization applicants are not in the President''s queue'
);
SELECT throws_ok(
  $$ SELECT public.approve_member('33333333-3333-4333-8333-333333333333') $$,
  '42501', NULL,
  'President cannot approve a member of another organization'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
