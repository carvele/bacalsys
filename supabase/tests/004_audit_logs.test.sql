-- Sprint 1 security baseline — application-immutable audit logging (Feature 11.1).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated, service_role;

SELECT plan(15);

-- Seeded rows are attributed to the migration actor ---------------------------
SELECT isnt_empty(
  $$ SELECT 1 FROM public.audit_logs
     WHERE actor_type = 'migration' AND action = 'member_positions.insert' $$,
  'seed position assignment was audited as a migration action'
);

-- Immutability for the table owner itself (trigger) ----------------------------
SELECT throws_ok(
  $$ UPDATE public.audit_logs SET action = 'tampered' $$,
  'P0001', 'Audit logs are immutable. Updates and deletions are strictly prohibited.',
  'UPDATE is blocked by trigger even for the owner'
);
SELECT throws_ok(
  $$ DELETE FROM public.audit_logs $$,
  'P0001', 'Audit logs are immutable. Updates and deletions are strictly prohibited.',
  'DELETE is blocked by trigger even for the owner'
);
SELECT throws_ok(
  $$ TRUNCATE public.audit_logs $$,
  'P0001', 'Audit logs are immutable. Updates and deletions are strictly prohibited.',
  'TRUNCATE is blocked by trigger even for the owner'
);

-- No mutating grants for runtime roles -----------------------------------------
SET LOCAL ROLE service_role;
SELECT throws_ok(
  $$ INSERT INTO public.audit_logs (actor_type, action, entity_type) VALUES ('system', 'forged', 'x') $$,
  '42501', NULL,
  'service_role cannot INSERT audit rows'
);
SELECT throws_ok(
  $$ DELETE FROM public.audit_logs $$,
  '42501', NULL,
  'service_role cannot DELETE audit rows'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ INSERT INTO public.audit_logs (actor_type, action, entity_type) VALUES ('system', 'forged', 'x') $$,
  '42501', NULL,
  'authenticated (even President) cannot INSERT audit rows'
);
SELECT throws_ok(
  $$ UPDATE public.audit_logs SET action = 'tampered' $$,
  '42501', NULL,
  'authenticated cannot UPDATE audit rows'
);
RESET ROLE;

-- Privileged action is audited with the user actor ------------------------------
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('11111111-1111-4111-8111-111111111111', 'juan@test.local', '{"full_name":"Juan"}');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT lives_ok($$ SELECT public.approve_member('11111111-1111-4111-8111-111111111111') $$, 'President approves Juan');
SELECT set_config('test.invite', public.create_invitation('audit@test.local')::text, true);
SELECT isnt_empty(
  $$ SELECT 1 FROM public.audit_logs $$,
  'President (audit:view) can read the audit log'
);
RESET ROLE;

SELECT is(
  (SELECT actor_type::text || ':' || actor_user_id::text || ':' || (new_values ->> 'status')
   FROM public.audit_logs
   WHERE action = 'profiles.update' AND entity_id = '11111111-1111-4111-8111-111111111111'),
  'user:00000000-0000-4000-8000-00000000a001:active',
  'approval status change is audited with the approving user as actor'
);
SELECT is(
  (SELECT old_values ->> 'status' FROM public.audit_logs
   WHERE action = 'profiles.update' AND entity_id = '11111111-1111-4111-8111-111111111111'),
  'pending_approval',
  'audit row captures the previous value'
);
SELECT isnt_empty(
  $$ SELECT 1 FROM public.audit_logs
     WHERE action = 'member_positions.insert' AND actor_user_id = '00000000-0000-4000-8000-00000000a001'
       AND new_values ->> 'profile_id' = '11111111-1111-4111-8111-111111111111' $$,
  'Athlete position assignment is audited'
);
SELECT ok(
  (SELECT NOT (new_values ? 'token_hash') FROM public.audit_logs
   WHERE action = 'invitations.insert' AND new_values ->> 'email' = 'audit@test.local'),
  'invitation audit rows redact token_hash'
);

-- Members without audit:view see nothing ---------------------------------------
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT is_empty(
  $$ SELECT 1 FROM public.audit_logs $$,
  'Athlete cannot read any audit rows'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
