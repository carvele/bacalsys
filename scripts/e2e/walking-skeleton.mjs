#!/usr/bin/env node
/**
 * Task 1.15 — Live Walking Skeleton end-to-end verification.
 *
 * Drives the real Supabase stack (Auth + PostgREST + Postgres/RLS) through
 * supabase-js exactly as the app does, with two independent clients standing
 * in for "two devices":
 *
 *   Register → PendingApproval gate → President sees queue → President approves
 *   (Athlete, assigned_at/assigned_by) → user refreshes → get_my_access_context()
 *   → Athlete home eligibility → RLS rejects access to another member's record.
 *
 * Local:  `supabase start` + `supabase db reset`, then `npm run e2e:skeleton`
 *         (EXPO_PUBLIC_SUPABASE_URL / EXPO_PUBLIC_SUPABASE_ANON_KEY in .env.local).
 *
 * Hosted dev project (no Docker): migrations + reference seed applied remotely,
 * env in a git-ignored file that also sets E2E_ALLOW_REMOTE_URL to the exact
 * project URL (explicit opt-in). The hosted President is bootstrapped once with
 *   node --env-file=.env.hosted.local scripts/e2e/walking-skeleton.mjs --bootstrap-president
 * which generates a random password and writes it ONLY to that env file; an
 * operator then promotes the account (see docs/sprint-1/README.md).
 *
 * Each run creates uniquely named throwaway members with random passwords.
 */
import { randomBytes } from 'node:crypto';
import { appendFileSync } from 'node:fs';

import { createClient } from '@supabase/supabase-js';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL;
const key = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('Set EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_ANON_KEY (see .env.example).');
  process.exit(2);
}
const isLocal = /^https?:\/\/(127\.0\.0\.1|localhost|10\.0\.2\.2)(:\d+)?/.test(url);
if (!isLocal && process.env.E2E_ALLOW_REMOTE_URL !== url) {
  console.error(`Refusing to run against non-local Supabase URL: ${url}`);
  console.error('Set E2E_ALLOW_REMOTE_URL to exactly this URL to opt in (dev projects only).');
  process.exit(2);
}

const randomPassword = () => `Bx-${randomBytes(18).toString('base64url')}`;

const PRESIDENT = {
  email: process.env.E2E_PRESIDENT_EMAIL ?? 'president@bacalsys.local',
  password: process.env.E2E_PRESIDENT_PASSWORD ?? 'BaCalSys-Local-President-1',
};

// Preflight: fail fast with a clear message instead of 20 confusing failures.
try {
  const health = await fetch(`${url}/auth/v1/health`, { headers: { apikey: key } });
  if (!health.ok) throw new Error(`HTTP ${health.status}`);
} catch (err) {
  console.error(`Supabase is not reachable at ${url} (${err.cause?.code ?? err.message}).`);
  console.error('Start it with `npm run db:start` and apply migrations + seed with `npm run db:reset`.');
  process.exit(2);
}

const newClient = () =>
  createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

// One-time hosted bootstrap: register the President with a generated password
// that is written only to the env file named by E2E_ENV_FILE and never printed.
if (process.argv.includes('--bootstrap-president')) {
  const envFile = process.env.E2E_ENV_FILE;
  if (!envFile || process.env.E2E_PRESIDENT_PASSWORD) {
    console.error('Bootstrap needs E2E_ENV_FILE and must not already have E2E_PRESIDENT_PASSWORD set.');
    process.exit(2);
  }
  const password = randomPassword();
  const { data, error } = await newClient().auth.signUp({
    email: PRESIDENT.email,
    password,
    options: { data: { full_name: 'Seed President' } },
  });
  if (error || !data.user) {
    console.error('President signup failed:', error?.message);
    process.exit(1);
  }
  appendFileSync(envFile, `
E2E_PRESIDENT_EMAIL=${PRESIDENT.email}
E2E_PRESIDENT_PASSWORD=${password}
`);
  console.log(`President registered as ${data.user.id} (pending). Password written to ${envFile}.`);
  process.exit(0);
}

let step = 0;
let failures = 0;
function check(condition, description, detail) {
  step++;
  if (condition) {
    console.log(`ok ${step} - ${description}`);
  } else {
    failures++;
    console.log(`not ok ${step} - ${description}`);
    if (detail !== undefined) console.log(`#   ${JSON.stringify(detail)}`);
  }
}

const stamp = Date.now();
const juan = { email: `juan.${stamp}@bacalsys.local`, password: randomPassword(), fullName: `Juan ${stamp}` };

// Device A: the applicant ------------------------------------------------------
const deviceA = newClient();

const signUp = await deviceA.auth.signUp({
  email: juan.email,
  password: juan.password,
  options: { data: { full_name: juan.fullName } },
});
check(!signUp.error && signUp.data.session, 'user registers via Auth and receives a session', signUp.error);
const juanId = signUp.data.user?.id;

const pendingProfile = await deviceA.from('profiles').select('status, full_name').eq('id', juanId).single();
check(
  pendingProfile.data?.status === 'pending_approval',
  'profile created by trigger with status pending_approval → app shows PendingApprovalScreen',
  pendingProfile,
);

const pendingQueueAttempt = await deviceA.rpc('list_pending_members');
check(pendingQueueAttempt.error?.code === '42501', 'pending user cannot read the approval queue', pendingQueueAttempt.error);

// Device B: the President --------------------------------------------------------
const deviceB = newClient();
const presSignIn = await deviceB.auth.signInWithPassword(PRESIDENT);
check(!presSignIn.error, 'President logs in on another device', presSignIn.error);
const PRESIDENT_ID = presSignIn.data.user?.id;

const presContext = await deviceB.rpc('get_my_access_context');
check(
  presContext.data?.positions?.includes('President') && presContext.data?.permissions?.includes('members:approve'),
  'President access context includes members:approve',
  presContext,
);

const queue = await deviceB.rpc('list_pending_members');
const listed = queue.data?.find((m) => m.id === juanId);
check(listed?.email === juan.email, 'President sees the new user in the Member Approval queue', queue.error ?? queue.data);

const approval = await deviceB.rpc('approve_member', { p_profile_id: juanId });
check(!approval.error && approval.data?.position === 'Athlete', 'President approves user and assigns Athlete', approval);

const assignment = await deviceB
  .from('member_positions')
  .select('assigned_at, assigned_by, ended_at, positions(name)')
  .eq('profile_id', juanId)
  .single();
check(
  assignment.data?.positions?.name === 'Athlete' &&
    assignment.data?.assigned_by === PRESIDENT_ID &&
    !!assignment.data?.assigned_at &&
    assignment.data?.ended_at === null,
  'member_positions row has Athlete with assigned_at and assigned_by = President',
  assignment,
);

// Device A again: approved user ------------------------------------------------
await deviceA.auth.signOut();
const juanSignIn = await deviceA.auth.signInWithPassword({ email: juan.email, password: juan.password });
check(!juanSignIn.error, 'approved user logs in successfully', juanSignIn.error);

const activeProfile = await deviceA.from('profiles').select('status').eq('id', juanId).single();
check(activeProfile.data?.status === 'active', 'profile status is active', activeProfile);

const juanContext = await deviceA.rpc('get_my_access_context');
check(
  JSON.stringify(juanContext.data) === JSON.stringify({ positions: ['Athlete'], permissions: [], is_system_admin: false }),
  'get_my_access_context() returns Athlete / no permissions / not system admin → Athlete Home',
  juanContext,
);

// Unauthorized API tests ------------------------------------------------------
const otherProfile = await deviceA.from('profiles').select('*').eq('id', PRESIDENT_ID);
check(
  !otherProfile.error && otherProfile.data.length === 0,
  "RLS: reading another member's profile returns no rows",
  otherProfile,
);

const otherPositions = await deviceA.from('member_positions').select('*').eq('profile_id', PRESIDENT_ID);
check(
  !otherPositions.error && otherPositions.data.length === 0,
  "RLS: reading another member's positions returns no rows",
  otherPositions,
);

const tamper = await deviceA.from('profiles').update({ full_name: 'Hacked' }).eq('id', PRESIDENT_ID).select();
check(!tamper.error && tamper.data.length === 0, "RLS: updating another member's profile affects 0 rows", tamper);

const selfPromote = await deviceA.from('profiles').update({ status: 'active' }).eq('id', juanId);
check(selfPromote.error?.code === '42501', 'permission denied: member cannot change their own status', selfPromote.error);

const grantPosition = await deviceA
  .from('member_positions')
  .insert({ profile_id: juanId, position_id: '00000000-0000-4000-8000-000000000205' });
check(grantPosition.error?.code === '42501', 'permission denied: member cannot grant themselves President', grantPosition.error);

const approveAttempt = await deviceA.rpc('approve_member', { p_profile_id: juanId });
check(approveAttempt.error?.code === '42501', 'permission denied: Athlete cannot call approve_member', approveAttempt.error);

const anon = newClient();
const anonRead = await anon.from('profiles').select('id');
check(anonRead.error?.code === '42501', 'permission denied: anonymous client cannot read profiles', anonRead.error);

const anonRpc = await anon.rpc('get_my_access_context');
check(anonRpc.error?.code === '42501', 'permission denied: anonymous client cannot call get_my_access_context()', anonRpc.error);

const presidentStillIntact = await deviceB.from('profiles').select('full_name').eq('id', PRESIDENT_ID).single();
check(presidentStillIntact.data?.full_name === 'Seed President', 'President profile unchanged', presidentStillIntact);

// Invitation claim on the real Auth stack --------------------------------------
// Exercises app_private.handle_new_user() against GoTrue, including the UPDATE
// of auth.users that strips the raw token (not coverable by the offline harness).
const maria = { email: `maria.${stamp}@bacalsys.local`, password: randomPassword() };
const invite = await deviceB.rpc('create_invitation', { p_email: maria.email });
check(/^[0-9a-f]{64}$/.test(invite.data?.token ?? ''), 'President creates a single-use invitation', invite.error ?? invite.data);

const deviceC = newClient();
const invitedSignUp = await deviceC.auth.signUp({
  email: maria.email,
  password: maria.password,
  options: { data: { full_name: 'Maria Invited', invite_token: invite.data?.token } },
});
check(!invitedSignUp.error && invitedSignUp.data.session, 'invitee signs up with the invitation token', invitedSignUp.error);

const invitedProfile = await deviceC.from('profiles').select('status').eq('id', invitedSignUp.data.user?.id).single();
check(invitedProfile.data?.status === 'active', 'claimed invitation activates the invitee without the approval queue', invitedProfile);

const invitedUser = await deviceC.auth.getUser();
check(
  invitedUser.data.user && !('invite_token' in (invitedUser.data.user.user_metadata ?? {})),
  'raw invite token was stripped from user metadata',
  invitedUser.data.user?.user_metadata,
);

console.log(`\n# ${step - failures}/${step} checks passed`);
process.exit(failures === 0 ? 0 : 1);
