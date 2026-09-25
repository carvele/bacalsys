-- Sprint 1 DoD #7, #8 — registration trigger and hashed single-use invitations.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(25);

-- Registration ----------------------------------------------------------------
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('11111111-1111-4111-8111-111111111111', 'juan@test.local', '{"full_name":"  Juan Dela Cruz  "}');

SELECT is(
  (SELECT status FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111'),
  'pending_approval'::public.member_status,
  'signup creates a pending_approval profile'
);
SELECT is(
  (SELECT full_name FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111'),
  'Juan Dela Cruz',
  'full_name is taken from signup metadata and trimmed'
);
SELECT is(
  (SELECT home_branch_id FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111'),
  (SELECT id FROM public.branches WHERE is_default),
  'new member is placed in the default branch'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.member_positions WHERE profile_id = '11111111-1111-4111-8111-111111111111' $$,
  'self-registration grants no position'
);

-- Authorization on create_invitation -------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.create_invitation('someone@test.local') $$,
  '42501', NULL,
  'a member without members:invite cannot create invitations'
);
SELECT throws_ok(
  $$ INSERT INTO public.invitations (token_hash, email, created_by, expires_at)
     VALUES (repeat('a', 64), 'x@test.local', '11111111-1111-4111-8111-111111111111', now() + interval '1 day') $$,
  '42501', NULL,
  'clients cannot insert invitations directly'
);
RESET ROLE;

-- President creates an invitation ---------------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT set_config('test.invite', public.create_invitation('  Maria@Test.Local ')::text, true);
SELECT throws_ok(
  $$ SELECT public.create_invitation('bad@test.local', NULL, 0) $$,
  '22023', NULL,
  'invitation lifetime is bounded'
);
SELECT throws_ok(
  $$ SELECT token_hash FROM public.invitations $$,
  '42501', NULL,
  'token_hash column is not readable by clients'
);
SELECT is(
  (SELECT count(*) FROM public.invitations WHERE created_by = '00000000-0000-4000-8000-00000000a001'),
  1::bigint,
  'inviter can see their invitation (without the hash)'
);
RESET ROLE;

SELECT ok(
  current_setting('test.invite')::jsonb ->> 'token' ~ '^[0-9a-f]{64}$',
  'raw token is 256-bit hex, returned once'
);
SELECT is(
  (SELECT token_hash FROM public.invitations WHERE id = (current_setting('test.invite')::jsonb ->> 'invitation_id')::uuid),
  encode(sha256(convert_to(current_setting('test.invite')::jsonb ->> 'token', 'UTF8')), 'hex'),
  'only the SHA-256 digest is stored'
);
SELECT is_empty(
  $$ SELECT 1 FROM public.invitations i
     WHERE to_jsonb(i)::text LIKE '%' || (current_setting('test.invite')::jsonb ->> 'token') || '%' $$,
  'raw token appears nowhere in the invitations row'
);
SELECT is(
  current_setting('test.invite')::jsonb ->> 'email',
  'maria@test.local',
  'invitation e-mail is normalized'
);

-- Claiming ----------------------------------------------------------------------
-- Wrong e-mail: token is bound to the invited address.
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('22222222-2222-4222-8222-222222222222', 'intruder@test.local',
        jsonb_build_object('full_name', 'Intruder', 'invite_token', current_setting('test.invite')::jsonb ->> 'token'));
SELECT is(
  (SELECT status FROM public.profiles WHERE id = '22222222-2222-4222-8222-222222222222'),
  'pending_approval'::public.member_status,
  'token presented with a different e-mail is not honoured'
);
SELECT ok(
  (SELECT claimed_at IS NULL FROM public.invitations WHERE email = 'maria@test.local'),
  'invitation stays unclaimed after a mismatched attempt'
);

-- Correct e-mail.
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('33333333-3333-4333-8333-333333333333', 'maria@test.local',
        jsonb_build_object('full_name', 'Maria', 'invite_token', current_setting('test.invite')::jsonb ->> 'token'));
SELECT is(
  (SELECT status FROM public.profiles WHERE id = '33333333-3333-4333-8333-333333333333'),
  'active'::public.member_status,
  'claiming a valid invitation activates the member'
);
SELECT is(
  (SELECT pos.name || '/' || mp.assigned_by::text
   FROM public.member_positions mp JOIN public.positions pos ON pos.id = mp.position_id
   WHERE mp.profile_id = '33333333-3333-4333-8333-333333333333' AND mp.ended_at IS NULL),
  'Athlete/00000000-0000-4000-8000-00000000a001',
  'invitee defaults to Athlete, assigned_by the inviter'
);
SELECT ok(
  (SELECT claimed_by = '33333333-3333-4333-8333-333333333333' AND claimed_at IS NOT NULL
   FROM public.invitations WHERE email = 'maria@test.local'),
  'invitation records claimed_at / claimed_by'
);
SELECT ok(
  (SELECT NOT (raw_user_meta_data ? 'invite_token') FROM auth.users WHERE id = '33333333-3333-4333-8333-333333333333'),
  'raw invite token is stripped from user metadata'
);

-- Regression (live E2E check 24): the Auth service re-saves the user row after
-- insert with its in-memory metadata, which still carries the token.
UPDATE auth.users
SET raw_user_meta_data = raw_user_meta_data
    || jsonb_build_object('invite_token', current_setting('test.invite')::jsonb ->> 'token')
WHERE id = '33333333-3333-4333-8333-333333333333';
SELECT ok(
  (SELECT NOT (raw_user_meta_data ? 'invite_token') FROM auth.users WHERE id = '33333333-3333-4333-8333-333333333333'),
  'invite token stays stripped when the Auth service re-saves the user row'
);

-- Single use: same address re-registers with the same token after account deletion.
DELETE FROM auth.users WHERE id = '33333333-3333-4333-8333-333333333333';
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('34343434-3434-4343-8343-343434343434', 'maria@test.local',
        jsonb_build_object('full_name', 'Maria Again', 'invite_token', current_setting('test.invite')::jsonb ->> 'token'));
SELECT is(
  (SELECT status FROM public.profiles WHERE id = '34343434-3434-4343-8343-343434343434'),
  'pending_approval'::public.member_status,
  'an invitation token cannot be used twice'
);

-- Expired invitation.
INSERT INTO public.invitations (token_hash, email, created_by, created_at, expires_at)
VALUES (encode(sha256(convert_to('expired-token', 'UTF8')), 'hex'), 'late@test.local',
        '00000000-0000-4000-8000-00000000a001', now() - interval '8 days', now() - interval '1 day');
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('35353535-3535-4353-8353-353535353535', 'late@test.local', '{"full_name":"Late","invite_token":"expired-token"}');
SELECT is(
  (SELECT status FROM public.profiles WHERE id = '35353535-3535-4353-8353-353535353535'),
  'pending_approval'::public.member_status,
  'an expired invitation is not honoured'
);

-- Pre-assignment requires members:preassign_position ---------------------------
-- Fixture: an active Leader who is (for this test only) allowed to invite.
INSERT INTO public.position_permissions (position_id, permission_id)
SELECT pos.id, perm.id FROM public.positions pos, public.permissions perm
WHERE pos.name = 'Leader' AND perm.name = 'members:invite';
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('77777777-7777-4777-8777-777777777777', 'leader@test.local', '{"full_name":"Leader"}');
UPDATE public.profiles SET status = 'active' WHERE id = '77777777-7777-4777-8777-777777777777';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT '77777777-7777-4777-8777-777777777777', id FROM public.positions WHERE name = 'Leader';

SELECT set_config('request.jwt.claims', '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT public.create_invitation('coach-to-be@test.local', (SELECT id FROM public.positions WHERE name = 'Coach')) $$,
  '42501', 'Not authorized to pre-assign positions',
  'inviter without members:preassign_position cannot pre-assign Coach'
);
SELECT lives_ok(
  $$ SELECT public.create_invitation('athlete-to-be@test.local', (SELECT id FROM public.positions WHERE name = 'Athlete')) $$,
  'inviter without members:preassign_position may still invite as Athlete'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT set_config('test.coach_invite',
  public.create_invitation('coach@test.local', (SELECT id FROM public.positions WHERE name = 'Coach'))::text, true);
RESET ROLE;
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('88888888-8888-4888-8888-888888888888', 'coach@test.local',
        jsonb_build_object('full_name', 'Coach', 'invite_token', current_setting('test.coach_invite')::jsonb ->> 'token'));
SELECT is(
  (SELECT pos.name FROM public.member_positions mp JOIN public.positions pos ON pos.id = mp.position_id
   WHERE mp.profile_id = '88888888-8888-4888-8888-888888888888'),
  'Coach',
  'President may pre-assign Coach; invitee receives it on claim'
);

SELECT * FROM finish();
ROLLBACK;
