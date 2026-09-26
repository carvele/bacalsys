#!/usr/bin/env node
/**
 * Sprint 2 · Tasks 2.5 / 2.12 — hosted verification of Acceptance Slices 1 and 2.
 *
 * Drives the real Supabase stack (Auth + PostgREST + Postgres/RLS) through
 * supabase-js, one client per person, exactly as the app does.
 *
 *   setup   Registers four tagged fixtures (Athlete A, Athlete B, Coach X, Coach Y),
 *           has the President approve them, and saves their credentials to a local
 *           state file (never printed). Prints the one operator SQL step: granting
 *           the Coach position to X and Y (there is no position-assignment RPC yet).
 *   slice1  Coaching relationship: assign, reassign, history, RLS, audit.
 *   slice2  Exercise catalog + custom submission state machine (both branches).
 *
 * Fixtures carry the tags from scripts/test/fixtures.mjs and are removed with
 * scripts/test/cleanup-fixtures.mjs. Env: as walking-skeleton.mjs, plus optional
 * E2E_STATE_FILE (default: <os tmpdir>/bacalsys-sprint2-e2e.json).
 *
 *   node --env-file=.env.hosted.local scripts/e2e/sprint2-slices.mjs setup|slice1|slice2
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createClient } from '@supabase/supabase-js';

import { fixtureEmail, fixtureMetadata, randomPassword } from '../test/fixtures.mjs';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL;
const key = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('Set EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_ANON_KEY.');
  process.exit(2);
}
const isLocal = /^https?:\/\/(127\.0\.0\.1|localhost|10\.0\.2\.2)(:\d+)?/.test(url);
if (!isLocal && process.env.E2E_ALLOW_REMOTE_URL !== url) {
  console.error(`Refusing to run against non-local Supabase URL: ${url} (set E2E_ALLOW_REMOTE_URL to opt in).`);
  process.exit(2);
}

const PRESIDENT = {
  email: process.env.E2E_PRESIDENT_EMAIL ?? 'president@bacalsys.local',
  password: process.env.E2E_PRESIDENT_PASSWORD ?? 'BaCalSys-Local-President-1',
};
const stateFile = process.env.E2E_STATE_FILE ?? join(tmpdir(), 'bacalsys-sprint2-e2e.json');
const newClient = (options = {}) =>
  createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false }, ...options });

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
function finish() {
  console.log(`\n# ${step - failures}/${step} checks passed`);
  process.exit(failures === 0 ? 0 : 1);
}

async function signIn(credentials) {
  const client = newClient();
  const { data, error } = await client.auth.signInWithPassword(credentials);
  if (error) throw new Error(`sign-in failed for ${credentials.email}: ${error.message}`);
  return { client, id: data.user.id };
}

const loadState = () => JSON.parse(readFileSync(stateFile, 'utf8'));
const people = async (state) => {
  const out = { president: await signIn(PRESIDENT) };
  for (const [role, f] of Object.entries(state.fixtures)) out[role] = await signIn(f);
  return out;
};

// ---------------------------------------------------------------------------------
async function setup() {
  const runId = `s2r${Date.now()}`;
  const roles = { athleteA: 'Athlete A', athleteB: 'Athlete B', coachX: 'Coach X', coachY: 'Coach Y' };
  const fixtures = {};
  for (const [role, label] of Object.entries(roles)) {
    const email = fixtureEmail(role.toLowerCase(), runId);
    const password = randomPassword();
    const { data, error } = await newClient().auth.signUp({
      email,
      password,
      options: { data: fixtureMetadata(`${label} ${runId}`) },
    });
    check(!error && data.user, `register tagged fixture ${label}`, error);
    fixtures[role] = { email, password, id: data.user?.id, name: `${label} ${runId}` };
  }

  const { client: president } = await signIn(PRESIDENT);
  for (const [role, f] of Object.entries(fixtures)) {
    const { error } = await president.rpc('approve_member', { p_profile_id: f.id });
    check(!error, `President approves ${role}`, error);
  }
  writeFileSync(stateFile, JSON.stringify({ runId, fixtures }, null, 2), { mode: 0o600 });
  console.log(`\n# State (credentials) written to ${stateFile}`);
  console.log('# Operator step: grant the Coach position to the two coach fixtures (audited, actor = migration):');
  console.log(`BEGIN;
SELECT set_config('bacalsys.actor_type', 'migration', true);
INSERT INTO public.member_positions (profile_id, position_id)
SELECT p.id, pos.id FROM public.profiles p, public.positions pos
WHERE pos.name = 'Coach' AND p.id IN ('${fixtures.coachX.id}', '${fixtures.coachY.id}');
COMMIT;`);
  finish();
}

// ---------------------------------------------------------------------------------
async function slice1() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const B = state.fixtures.athleteB.id;
  const X = state.fixtures.coachX.id;
  const Y = state.fixtures.coachY.id;

  const ctx = await p.president.client.rpc('get_my_access_context');
  check(ctx.data?.permissions?.includes('coaches:assign'), 'President holds coaches:assign (D3)', ctx.error);
  const xCtx = await p.coachX.client.rpc('get_my_access_context');
  check(
    xCtx.data?.positions?.includes('Coach') && !xCtx.data?.permissions?.includes('coaches:assign'),
    'Coach X holds the Coach position but not coaches:assign',
    xCtx.data,
  );

  // Negative paths before anything exists.
  const byCoach = await p.coachX.client.rpc('assign_primary_coach', { p_athlete_id: A, p_coach_id: X });
  check(byCoach.error?.code === '42501', 'Coach cannot assign primary coaches (42501)', byCoach.error);
  const byAthlete = await p.athleteA.client.rpc('assign_primary_coach', { p_athlete_id: B, p_coach_id: X });
  check(byAthlete.error?.code === '42501', 'Athlete cannot assign primary coaches (42501)', byAthlete.error);
  const byAnon = await newClient().rpc('assign_primary_coach', { p_athlete_id: A, p_coach_id: X });
  check(byAnon.error?.code === '42501', 'anonymous caller cannot call assign_primary_coach (42501)', byAnon.error);
  const internal = await p.president.client.rpc('assign_primary_coach_internal', {
    p_athlete_id: A,
    p_coach_id: X,
    p_notes: null,
  });
  check(internal.error?.code === 'PGRST202', 'private implementation is not reachable through the Data API (public)', internal.error);
  const privateSchema = await newClient({ db: { schema: 'app_private' } }).rpc('assign_primary_coach_internal', {
    p_athlete_id: A,
    p_coach_id: X,
    p_notes: null,
  });
  check(privateSchema.error?.code === 'PGRST106', 'app_private schema is not exposed by the Data API', privateSchema.error);

  // Assign Athlete A → Coach X.
  const first = await p.president.client.rpc('assign_primary_coach', {
    p_athlete_id: A,
    p_coach_id: X,
    p_notes: `Slice 1 ${state.runId}`,
  });
  check(!first.error && /^[0-9a-f-]{36}$/.test(first.data ?? ''), 'President assigns Athlete A → Coach X', first.error);
  const firstId = first.data;

  const active1 = await p.president.client
    .from('coach_assignments')
    .select('id, coach_id, assigned_by')
    .eq('athlete_id', A)
    .is('ended_at', null);
  check(
    active1.data?.length === 1 && active1.data[0].coach_id === X && active1.data[0].assigned_by === p.president.id,
    'exactly one active coach row for Athlete A (Coach X, assigned_by President)',
    active1,
  );

  const myAthletesX = await p.coachX.client
    .from('coach_assignments')
    .select('athlete_id, athlete:profiles!coach_assignments_athlete_id_fkey(full_name)')
    .eq('coach_id', X)
    .is('ended_at', null);
  check(
    myAthletesX.data?.length === 1 && myAthletesX.data[0].athlete_id === A && myAthletesX.data[0].athlete?.full_name === state.fixtures.athleteA.name,
    'Coach X "My Athletes": Athlete A returned (1 row, with name)',
    myAthletesX,
  );
  const bForX = await p.coachX.client.from('coach_assignments').select('id').eq('athlete_id', B);
  check(!bForX.error && bForX.data.length === 0, 'Coach X "My Athletes": Athlete B absent (0 rows)', bForX);

  const noop = await p.president.client.rpc('assign_primary_coach', { p_athlete_id: A, p_coach_id: X });
  check(noop.error?.code === '55000', 'same-coach reassignment rejected as a no-op (55000)', noop.error);
  const self = await p.president.client.rpc('assign_primary_coach', { p_athlete_id: X, p_coach_id: X });
  check(self.error?.code === '22023', 'self-coaching rejected (22023)', self.error);
  const notCoach = await p.president.client.rpc('assign_primary_coach', { p_athlete_id: B, p_coach_id: A });
  check(notCoach.error?.code === '22023', 'a member without the Coach position cannot be assigned as coach (22023)', notCoach.error);

  // Reassign Athlete A → Coach Y. Hold the X assignment for a few seconds first so the
  // real window is wide enough for the spec's "ended_at - 1 second" boundary check.
  await new Promise((resolve) => setTimeout(resolve, 3000));
  const second = await p.president.client.rpc('assign_primary_coach', { p_athlete_id: A, p_coach_id: Y });
  check(!second.error && second.data && second.data !== firstId, 'President reassigns Athlete A → Coach Y', second.error);

  const history = await p.president.client
    .from('coach_assignments')
    .select('id, coach_id, started_at, ended_at, ended_by')
    .eq('athlete_id', A)
    .order('started_at');
  const xRow = history.data?.find((r) => r.id === firstId);
  const yRow = history.data?.find((r) => r.id === second.data);
  check(history.data?.length === 2, 'historical Coach X row preserved (2 rows for Athlete A)', history);
  check(
    !!xRow?.ended_at && xRow.ended_by === p.president.id,
    'prior Coach X assignment closed: ended_at set, ended_by = President',
    xRow,
  );
  check(yRow?.coach_id === Y && yRow.ended_at === null, 'Coach Y is the sole active coach', yRow);
  check(
    !!xRow && !!yRow && new Date(yRow.started_at).getTime() === new Date(xRow.ended_at).getTime(),
    'handover is continuous (Y.started_at = X.ended_at)',
    { x: xRow?.ended_at, y: yRow?.started_at },
  );

  const xNow = await p.coachX.client.from('coach_assignments').select('id').eq('coach_id', X).is('ended_at', null);
  check(!xNow.error && xNow.data.length === 0, 'former Coach X "My Athletes" is now empty', xNow);
  const xHistory = await p.coachX.client.from('coach_assignments').select('id, ended_at').eq('id', firstId);
  check(xHistory.data?.length === 1 && !!xHistory.data[0].ended_at, 'former Coach X still sees their own closed assignment', xHistory);
  const yNow = await p.coachY.client.from('coach_assignments').select('athlete_id').eq('coach_id', Y).is('ended_at', null);
  check(yNow.data?.length === 1 && yNow.data[0].athlete_id === A, 'Coach Y "My Athletes": Athlete A', yNow);

  const aOwn = await p.athleteA.client.from('coach_assignments').select('id').eq('athlete_id', A);
  check(aOwn.data?.length === 2, 'Athlete A reads their own coaching history (2 rows)', aOwn);
  const bAll = await p.athleteB.client.from('coach_assignments').select('id');
  check(!bAll.error && bAll.data.length === 0, "Athlete B cannot read anyone's coach assignments", bAll);

  // Audit trail (President holds audit:view).
  const audit = await p.president.client
    .from('audit_logs')
    .select('action, entity_id, actor_user_id, actor_type, old_values, new_values')
    .eq('entity_type', 'coach_assignments')
    .in('entity_id', [firstId, second.data]);
  const has = (fn) => audit.data?.some(fn);
  check(
    has((r) => r.action === 'coach_assignments.insert' && r.entity_id === firstId && r.actor_user_id === p.president.id),
    'audit: assignment to Coach X recorded (actor President)',
    audit.error ?? audit.data,
  );
  check(
    has(
      (r) =>
        r.action === 'coach_assignments.update' &&
        r.entity_id === firstId &&
        r.actor_type === 'user' &&
        r.old_values?.ended_at === null &&
        r.new_values?.ended_by === p.president.id,
    ),
    'audit: reassignment closing the Coach X row recorded (actor President)',
    audit.data,
  );
  check(
    has((r) => r.action === 'coach_assignments.insert' && r.entity_id === second.data && r.new_values?.coach_id === Y),
    'audit: new Coach Y assignment recorded',
    audit.data,
  );

  // Direct writes are impossible even for the President.
  const ins = await p.president.client.from('coach_assignments').insert({ athlete_id: B, coach_id: X, assigned_by: p.president.id });
  check(ins.error?.code === '42501', 'direct INSERT into coach_assignments denied (42501)', ins.error);
  const upd = await p.president.client.from('coach_assignments').update({ notes: 'tamper' }).eq('id', second.data);
  check(upd.error?.code === '42501', 'direct UPDATE of coach_assignments denied (42501)', upd.error);
  const del = await p.president.client.from('coach_assignments').delete().eq('id', firstId);
  check(del.error?.code === '42501', 'direct DELETE of coaching history denied (42501)', del.error);
  const anonRead = await newClient().from('coach_assignments').select('id');
  check(anonRead.error?.code === '42501', 'anonymous client cannot read coach_assignments (42501)', anonRead.error);

  console.log('\n# Helper verification (run as SQL; app_private is not reachable over the API):');
  console.log(`#   firstId=${firstId} secondId=${second.data} A=${A} B=${B} X=${X} Y=${Y}`);
  finish();
}

// ---------------------------------------------------------------------------------
async function slice2() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const X = state.fixtures.coachX.id;
  const suffix = state.runId;

  const official = await p.athleteB.client.from('exercises').select('id').eq('status', 'approved').eq('is_official', true);
  check(!official.error && official.data.length >= 32, 'active members see the official seeded catalog', official.error ?? official.data?.length);
  const anonCatalog = await newClient().from('exercises').select('id');
  check(anonCatalog.error?.code === '42501', 'anonymous client cannot read the catalog (42501)', anonCatalog.error);

  // Athlete A creates "Weighted Ring Dips" (run-suffixed so reruns never clash with an approved slug).
  const created = await p.athleteA.client
    .from('exercises')
    .insert({
      name: `Weighted Ring Dips ${suffix}`,
      category: 'push',
      description: 'Ring dips with a weight vest.',
      measurement_types: ['reps', 'added_weight'],
      equipment_needed: ['rings', 'weight_vest'],
      created_by: A,
    })
    .select()
    .single();
  const ex = created.data;
  check(
    !created.error && ex?.status === 'private' && ex.is_official === false && ex.slug === `weighted-ring-dips-${suffix}`,
    'Athlete creates a custom exercise: status private, is_official false, slug derived',
    created.error ?? ex,
  );

  const visible = async (who) => (await p[who].client.from('exercises').select('id, status, rejection_reason').eq('id', ex.id)).data ?? [];
  check((await visible('athleteA')).length === 1, 'creator sees the private exercise (1 row)');
  check((await visible('athleteB')).length === 0, 'another athlete sees 0 rows');
  check((await visible('coachX')).length === 0, 'a coach (even with exercises:approve) sees 0 rows while private');

  const forgeStatus = await p.athleteA.client.from('exercises').update({ status: 'approved' }).eq('id', ex.id);
  check(forgeStatus.error?.code === '42501', 'creator cannot UPDATE status directly (42501)', forgeStatus.error);
  const forgeOfficial = await p.athleteA.client.from('exercises').update({ is_official: true }).eq('id', ex.id);
  check(forgeOfficial.error?.code === '42501', 'creator cannot UPDATE is_official directly (42501)', forgeOfficial.error);
  const forgeInsert = await p.athleteA.client
    .from('exercises')
    .insert({ name: `Forged ${suffix}`, category: 'core', measurement_types: ['reps'], equipment_needed: ['none'], created_by: A, status: 'approved' });
  check(forgeInsert.error?.code === '42501', 'creator cannot INSERT an approved exercise (42501)', forgeInsert.error);
  const forgeOwner = await p.athleteB.client
    .from('exercises')
    .insert({ name: `Impersonated ${suffix}`, category: 'core', measurement_types: ['reps'], equipment_needed: ['none'], created_by: A });
  check(forgeOwner.error?.code === '42501', 'nobody can create an exercise in another member’s name (42501)', forgeOwner.error);

  const edit = await p.athleteA.client.from('exercises').update({ description: 'Ring dips, weight vest, full ROM.' }).eq('id', ex.id).select();
  check(!edit.error && edit.data.length === 1, 'creator can edit content of their private draft', edit.error ?? edit.data);
  const foreignEdit = await p.athleteB.client.from('exercises').update({ description: 'hacked' }).eq('id', ex.id).select();
  check(!foreignEdit.error && foreignEdit.data.length === 0, "another member's edit affects 0 rows", foreignEdit);

  const earlyReview = await p.coachX.client.rpc('review_custom_exercise', { p_exercise_id: ex.id, p_action: 'approve' });
  check(earlyReview.error?.code === '55000', 'illegal transition private → approve rejected (55000)', earlyReview.error);
  const foreignSubmit = await p.athleteB.client.rpc('submit_custom_exercise', { p_exercise_id: ex.id });
  check(foreignSubmit.error?.code === '42501', 'only the creator can submit (42501)', foreignSubmit.error);

  // Submit.
  const submitted = await p.athleteA.client.rpc('submit_custom_exercise', { p_exercise_id: ex.id });
  check(!submitted.error && submitted.data?.status === 'pending_approval', 'creator submits: status pending_approval', submitted.error ?? submitted.data);
  const lateEdit = await p.athleteA.client.from('exercises').update({ description: 'late' }).eq('id', ex.id).select();
  check(!lateEdit.error && lateEdit.data.length === 0, 'a submitted exercise can no longer be edited (0 rows)', lateEdit);

  const queue = await p.coachX.client.from('exercises').select('id').eq('status', 'pending_approval').eq('id', ex.id);
  check(queue.data?.length === 1, 'user with exercises:approve sees it in the review queue (1 row)', queue);
  check((await visible('athleteB')).length === 0, 'ordinary member still sees 0 rows while pending');
  const byAthlete = await p.athleteB.client.rpc('review_custom_exercise', { p_exercise_id: ex.id, p_action: 'approve' });
  check(byAthlete.error?.code === '42501', 'an Athlete cannot review exercises (42501)', byAthlete.error);
  const noReason = await p.coachX.client.rpc('review_custom_exercise', { p_exercise_id: ex.id, p_action: 'reject' });
  check(noReason.error?.code === '22023', 'reject without a reason is rejected (22023)', noReason.error);
  const badAction = await p.coachX.client.rpc('review_custom_exercise', { p_exercise_id: ex.id, p_action: 'publish' });
  check(badAction.error?.code === '22023', 'unknown review action is rejected (22023)', badAction.error);

  // Approve.
  const approved = await p.coachX.client.rpc('review_custom_exercise', { p_exercise_id: ex.id, p_action: 'approve' });
  check(
    !approved.error &&
      approved.data?.status === 'approved' &&
      approved.data.is_official === true &&
      approved.data.reviewed_by === X &&
      !!approved.data.reviewed_at,
    'Coach X (exercises:approve) approves: approved, official, reviewed_by/reviewed_at set',
    approved.error ?? approved.data,
  );
  for (const who of ['athleteA', 'athleteB', 'coachY', 'president']) {
    check((await visible(who)).length === 1, `${who} sees the approved exercise (globally discoverable)`);
  }
  const resubmit = await p.athleteA.client.rpc('submit_custom_exercise', { p_exercise_id: ex.id });
  check(resubmit.error?.code === '55000', 'illegal transition approved → submit rejected (55000)', resubmit.error);
  const rereview = await p.coachX.client.rpc('review_custom_exercise', { p_exercise_id: ex.id, p_action: 'reject', p_rejection_reason: 'x' });
  check(rereview.error?.code === '55000', 'an approved exercise cannot be reviewed again (55000)', rereview.error);

  // Rejection branch.
  const second = await p.athleteA.client
    .from('exercises')
    .insert({
      name: `Weighted Ring Dips Variant ${suffix}`,
      category: 'push',
      measurement_types: ['reps'],
      equipment_needed: ['rings'],
      created_by: A,
    })
    .select()
    .single();
  await p.athleteA.client.rpc('submit_custom_exercise', { p_exercise_id: second.data?.id });
  const rejected = await p.president.client.rpc('review_custom_exercise', {
    p_exercise_id: second.data?.id,
    p_action: 'reject',
    p_rejection_reason: 'Form cues unclear',
  });
  check(
    !rejected.error && rejected.data?.status === 'rejected' && rejected.data.rejection_reason === 'Form cues unclear',
    "President rejects with 'Form cues unclear'",
    rejected.error ?? rejected.data,
  );
  const creatorView = await p.athleteA.client.from('exercises').select('status, rejection_reason').eq('id', second.data?.id);
  check(creatorView.data?.[0]?.rejection_reason === 'Form cues unclear', 'creator sees the rejection reason', creatorView);
  const otherView = await p.athleteB.client.from('exercises').select('id').eq('id', second.data?.id);
  check(!otherView.error && otherView.data.length === 0, 'ordinary member sees 0 rows for the rejected exercise', otherView);
  const approverView = await p.coachX.client.from('exercises').select('id').eq('id', second.data?.id);
  check(!approverView.error && approverView.data.length === 0, 'rejected exercise leaves the review queue', approverView);

  // Audit trail.
  const audit = await p.president.client
    .from('audit_logs')
    .select('action, actor_user_id, new_values')
    .eq('entity_type', 'exercises')
    .eq('entity_id', ex.id);
  const statuses = (audit.data ?? []).map((r) => r.new_values?.status);
  check(
    statuses.includes('private') && statuses.includes('pending_approval') &&
      audit.data.some((r) => r.new_values?.status === 'approved' && r.actor_user_id === X),
    'audit: create, submit and approval (actor Coach X) recorded',
    audit.error ?? audit.data,
  );

  console.log(`\n# exercise ids: approved=${ex.id} rejected=${second.data?.id}`);
  finish();
}

const command = process.argv[2];
const commands = { setup, slice1, slice2 };
if (!commands[command]) {
  console.error('Usage: sprint2-slices.mjs setup|slice1|slice2');
  process.exit(2);
}
await commands[command]();
