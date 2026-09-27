#!/usr/bin/env node
/**
 * Sprint 4 · Tasks 4.8 / 4.15 — hosted verification of Acceptance Slices 1
 * and 2, plus the concurrency probes.
 *
 * Drives the real Supabase stack (Auth + PostgREST + Postgres/RLS) through
 * supabase-js, one client per person, exactly as the app does.
 *
 *   setup        Registers tagged fixtures (Coach, Athlete, Former Coach,
 *                Leader, Vice President, Leader in a second organization),
 *                has the President approve them, and saves their credentials
 *                to a local state file (never printed). Prints the operator
 *                SQL step: positions, a second organization, and the coaching
 *                relationships (current + a closed former-coach window) —
 *                there is no position-assignment RPC yet.
 *   slice1       Live workout player, substitution & split feedback (Section 11).
 *   slice2       Offline bundle: online start -> full offline completion via
 *                sync_offline_session_bundle -> exact replay idempotency.
 *   concurrency  Race-safe idempotency + row-locking probes.
 *
 * Fixtures carry the tags from scripts/test/fixtures.mjs and are removed with
 * scripts/test/cleanup-fixtures.mjs. Env: as sprint3-slices.mjs, plus optional
 * E2E_STATE_FILE (default: <os tmpdir>/bacalsys-sprint4-e2e.json).
 *
 *   node --env-file=.env.hosted.local scripts/e2e/sprint4-slices.mjs setup|slice1|slice2|concurrency
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
const stateFile = process.env.E2E_STATE_FILE ?? join(tmpdir(), 'bacalsys-sprint4-e2e.json');
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
const uuid = () => crypto.randomUUID();

async function byBySlug(client, slugs) {
  const { data, error } = await client.from('exercises').select('id, slug').in('slug', slugs);
  if (error) throw error;
  return Object.fromEntries(data.map((e) => [e.slug, e.id]));
}

/** Coach authors an organization routine (pull-up + push-up), returns {templateId, versionId, pullUpItemId, pushUpItemId}. */
async function seedRoutine(coachClient, runId) {
  const ids = await byBySlug(coachClient, ['pull-up', 'push-up']);
  const created = await coachClient.rpc('create_workout_template', {
    p_name: `Sprint4 Fixture Routine ${runId}`,
    p_description: null,
    p_visibility: 'organization',
    p_blocks: [
      {
        title: 'Main',
        block_type: 'standard_set',
        items: [
          { exercise_id: ids['pull-up'], measurement_mode: 'reps', sets: [{ target_reps: 6 }] },
          { exercise_id: ids['push-up'], measurement_mode: 'reps', sets: [{ target_reps: 15 }] },
        ],
      },
    ],
  });
  if (created.error) throw created.error;
  const templateId = created.data.template_id;
  const versionId = created.data.version_id;
  const blocks = await coachClient.from('workout_blocks').select('id').eq('workout_version_id', versionId);
  const items = await coachClient.from('workout_items').select('id, exercise_id').in('block_id', blocks.data.map((b) => b.id));
  const pullUpItemId = items.data.find((i) => i.exercise_id === ids['pull-up']).id;
  const pushUpItemId = items.data.find((i) => i.exercise_id === ids['push-up']).id;
  return { templateId, versionId, pullUpItemId, pushUpItemId };
}

// ---------------------------------------------------------------------------
async function setup() {
  const runId = `s4r${Date.now()}`;
  const roles = {
    coachA: 'Coach A',
    athleteA: 'Athlete A',
    formerCoach: 'Former Coach',
    leader: 'Leader',
    vp: 'Vice President Fixture',
    leaderB: 'Leader B (Org B)',
  };
  const fixtures = {};
  for (const [role, label] of Object.entries(roles)) {
    const email = fixtureEmail(role.toLowerCase(), runId);
    const password = randomPassword();
    const { data, error } = await newClient().auth.signUp({ email, password, options: { data: fixtureMetadata(`${label} ${runId}`) } });
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
  console.log('# Fixture ids (for the operator SQL step below):');
  for (const [role, f] of Object.entries(fixtures)) console.log(`#   ${role}: ${f.id}`);
  console.log(`
# ---------------------------------------------------------------------------
# Operator SQL step (run once via the Supabase MCP / SQL editor):
#   - positions: coachA + formerCoach -> Coach, athleteA -> Athlete,
#     leader -> Leader, vp -> Vice President, leaderB -> Leader (in Org B)
#   - a second organization + branch for leaderB (cross-org isolation probe)
#   - coach_assignments: coachA is athleteA's CURRENT coach; formerCoach was
#     athleteA's coach in a CLOSED window ending before slice1 runs
# ---------------------------------------------------------------------------
INSERT INTO public.organizations (id, name, slug) VALUES ('${uuid()}', 'Sprint4 Club B', 'sprint4-club-b-${runId}') RETURNING id \\gset orgb_
-- (replace <ORG_B_ID> below with the id printed above, or run the equivalent through execute_sql in one batch)
`);
  finish();
}

// ---------------------------------------------------------------------------
async function slice1() {
  const state = loadState();
  const p = await people(state);
  const { versionId, pullUpItemId } = await seedRoutine(p.coachA.client, state.runId);

  const startKey = uuid();
  const started = await p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: startKey });
  check(!started.error, 'the athlete starts a session from the fixture routine', started.error);
  const sessionId = started.data?.session_id;
  check(!!started.data?.exercise_mapping?.[pullUpItemId], 'start returns an exercise_mapping keyed by workout_item_id', started.data);
  const pullUpSessionExerciseId = started.data.exercise_mapping[pullUpItemId];

  const dipId = (await byBySlug(p.athleteA.client, ['parallel-bar-dip']))['parallel-bar-dip'];
  const sub = await p.athleteA.client.rpc('record_exercise_substitution', {
    p_session_id: sessionId,
    p_original_workout_item_id: pullUpItemId,
    p_replacement_exercise_id: dipId,
    p_performed_measurement_mode: 'reps',
    p_reason_code: 'pain_discomfort',
    p_idempotency_key: uuid(),
  });
  check(!sub.error, 'the athlete substitutes pull-up for parallel-bar-dip (pain_discomfort) before any set', sub.error);

  const setResult = await p.athleteA.client.rpc('record_session_set', {
    p_session_id: sessionId,
    p_session_exercise_id: pullUpSessionExerciseId,
    p_set_data: { set_number: 1, actual_reps: 8, is_completed: true },
    p_idempotency_key: uuid(),
  });
  check(!setResult.error, 'a set is recorded against the substituted exercise', setResult.error);

  const completed = await p.athleteA.client.rpc('complete_workout_session', {
    p_session_id: sessionId,
    p_status: 'completed',
    p_abandonment_reason_code: null,
    p_feedback: { difficulty_rating: 8, energy_level: 4 },
    p_private_feedback: { has_discomfort: true, discomfort_area: 'Left Shoulder', note_to_coach: 'Felt pinching at the top of pull-up' },
    p_idempotency_key: uuid(),
  });
  check(!completed.error && completed.data?.status === 'completed', 'the session completes with split ordinary + private feedback', completed.error ?? completed.data);

  const asOwner = await p.athleteA.client.from('workout_sessions').select('status, started_at, completed_at').eq('id', sessionId).single();
  check(asOwner.data?.status === 'completed' && asOwner.data.completed_at >= asOwner.data.started_at, 'the session row is completed with completed_at >= started_at', asOwner.data);
  const mods = await p.athleteA.client.from('session_modifications').select('reason_code').eq('session_id', sessionId);
  check(mods.data?.length === 1 && mods.data[0].reason_code === 'pain_discomfort', 'exactly 1 substitution, reason pain_discomfort', mods.data);
  const priv = await p.athleteA.client.from('session_private_feedback').select('*').eq('session_id', sessionId);
  check(priv.data?.length === 1, 'exactly 1 private feedback row', priv.data);

  // Current primary coach: sees everything, including the sensitive substitution and private feedback.
  const coachSession = await p.coachA.client.from('workout_sessions').select('id').eq('id', sessionId);
  const coachPriv = await p.coachA.client.from('session_private_feedback').select('*').eq('session_id', sessionId);
  const coachMods = await p.coachA.client.from('session_modifications').select('*').eq('session_id', sessionId);
  check(coachSession.data?.length === 1, 'the current primary coach sees the session', coachSession.data);
  check(coachPriv.data?.length === 1, 'the current primary coach sees the private discomfort feedback', coachPriv.data);
  check(coachMods.data?.length === 1, 'the current primary coach sees the sensitive substitution', coachMods.data);

  // Leader: sees session + ordinary feedback, but 0 rows of private feedback and the sensitive modification.
  const leaderSession = await p.leader.client.from('workout_sessions').select('id').eq('id', sessionId);
  const leaderFeedback = await p.leader.client.from('session_feedback').select('*').eq('session_id', sessionId);
  const leaderPriv = await p.leader.client.from('session_private_feedback').select('*').eq('session_id', sessionId);
  const leaderMods = await p.leader.client.from('session_modifications').select('*').eq('session_id', sessionId);
  check(leaderSession.data?.length === 1, 'the Leader sees the session (training:view_org)', leaderSession.data);
  check(leaderFeedback.data?.length === 1, 'the Leader sees the ordinary feedback', leaderFeedback.data);
  check(leaderPriv.data?.length === 0, 'the Leader sees 0 rows of private feedback', leaderPriv.data);
  check(leaderMods.data?.length === 0, 'the Leader sees 0 rows of the sensitive (pain_discomfort) substitution', leaderMods.data);

  // Former coach (tenure ended before this session): 0 rows everywhere.
  const formerSession = await p.formerCoach.client.from('workout_sessions').select('id').eq('id', sessionId);
  check(formerSession.data?.length === 0, 'the FORMER coach (tenure ended before this session) sees 0 rows', formerSession.data);

  // A holder of audit:view (Vice President) sees the events happened, but every sensitive field is redacted.
  const auditPriv = await p.vp.client
    .from('audit_logs')
    .select('new_values')
    .eq('entity_type', 'session_private_feedback')
    .eq('entity_id', sessionId);
  check(
    auditPriv.data?.[0]?.new_values?.has_discomfort === '[REDACTED]' && auditPriv.data[0].new_values.note_to_coach === '[REDACTED]',
    'audit:view sees the private-feedback event but every sensitive field is [REDACTED]',
    auditPriv.data,
  );
  const auditMod = await p.vp.client.from('audit_logs').select('new_values').eq('entity_type', 'session_modification').contains('new_values', { session_id: sessionId });
  check(
    (auditMod.data ?? []).every((r) => r.new_values.reason_code === '[REDACTED]'),
    'F-S4-P13: the substitution audit event redacts reason_code uniformly',
    auditMod.data,
  );

  console.log(`\n# Slice 1 ids: session=${sessionId}`);
  finish();
}

// ---------------------------------------------------------------------------
async function slice2() {
  const state = loadState();
  const p = await people(state);
  const { versionId, pullUpItemId, pushUpItemId } = await seedRoutine(p.coachA.client, `${state.runId}-s2`);

  // 1. Online start.
  const started = await p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: uuid() });
  check(!started.error, 'a session is started ONLINE', started.error);
  const sessionId = started.data.session_id;

  // 2-4. Connectivity lost: substitute + 3 sets + split feedback, all coalesced into one offline bundle.
  const startedAt = new Date().toISOString();
  const bundleKey = uuid();
  const bundle = {
    session_correlation_id: uuid(),
    existing_session_id: sessionId,
    workout_version_id: versionId,
    status: 'completed',
    started_at: startedAt,
    completed_at: new Date(Date.now() + 20 * 60 * 1000).toISOString(),
    substitutions: [
      {
        original_workout_item_id: pullUpItemId,
        replacement_exercise_id: (await byBySlug(p.athleteA.client, ['diamond-push-up']))['diamond-push-up'],
        performed_measurement_mode: 'reps',
        reason_code: 'equipment_unavailable',
      },
    ],
    sets: [
      { workout_item_id: pullUpItemId, set_number: 1, actual_reps: 10, is_completed: true },
      { workout_item_id: pushUpItemId, set_number: 1, actual_reps: 15, is_completed: true },
      { workout_item_id: pushUpItemId, set_number: 2, actual_reps: 12, is_completed: true },
    ],
    feedback: { difficulty_rating: 7, energy_level: 3 },
    private_feedback: { has_discomfort: false },
  };
  const synced = await p.athleteA.client.rpc('sync_offline_session_bundle', { p_bundle: bundle, p_idempotency_key: bundleKey });
  check(!synced.error && synced.data?.status === 'synced', 'the offline bundle syncs into the existing online-started session', synced.error ?? synced.data);

  const finalSession = await p.athleteA.client.from('workout_sessions').select('status').eq('id', sessionId).single();
  check(finalSession.data?.status === 'completed', 'the session transitioned to completed', finalSession.data);
  const setsCount = await p.athleteA.client
    .from('session_sets')
    .select('id, session_exercises!inner(session_id)', { count: 'exact', head: true })
    .eq('session_exercises.session_id', sessionId);
  check(setsCount.count === 3, 'exactly 3 sets exist — zero data loss from the interrupted connectivity', setsCount);

  // 5. Replay: resend the IDENTICAL bundle + key -> cached success, no duplicates.
  const replay = await p.athleteA.client.rpc('sync_offline_session_bundle', { p_bundle: bundle, p_idempotency_key: bundleKey });
  check(!replay.error, 'resending the exact same bundle with the same idempotency key succeeds (cached), not an error', replay.error);
  const setsAfterReplay = await p.athleteA.client
    .from('session_sets')
    .select('id, session_exercises!inner(session_id)', { count: 'exact', head: true })
    .eq('session_exercises.session_id', sessionId);
  check(setsAfterReplay.count === 3, 'the replay created ZERO additional sets', setsAfterReplay);

  console.log(`\n# Slice 2 ids: session=${sessionId}`);
  finish();
}

// ---------------------------------------------------------------------------
async function concurrency() {
  const state = loadState();
  const p = await people(state);
  const { versionId, pullUpItemId } = await seedRoutine(p.coachA.client, `${state.runId}-cc`);

  // Probe 1: simultaneous START_SESSION, same key -> exactly one session, both callers see the same response.
  const startKey = uuid();
  const [s1, s2] = await Promise.all([
    p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: startKey }),
    p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: startKey }),
  ]);
  check(!s1.error && !s2.error, 'two concurrent START_SESSION calls with the SAME key both succeed', [s1.error, s2.error]);
  check(s1.data?.session_id === s2.data?.session_id, 'both calls resolved to the identical session_id (no duplicate)', [s1.data, s2.data]);
  const sessionId = s1.data.session_id;
  const sessionExerciseId = s1.data.exercise_mapping[pullUpItemId];

  // Probe 2: simultaneous RECORD_SET, same key -> exactly one set row.
  const setKey = uuid();
  const [r1, r2] = await Promise.all([
    p.athleteA.client.rpc('record_session_set', {
      p_session_id: sessionId,
      p_session_exercise_id: sessionExerciseId,
      p_set_data: { set_number: 1, actual_reps: 6, is_completed: true },
      p_idempotency_key: setKey,
    }),
    p.athleteA.client.rpc('record_session_set', {
      p_session_id: sessionId,
      p_session_exercise_id: sessionExerciseId,
      p_set_data: { set_number: 1, actual_reps: 6, is_completed: true },
      p_idempotency_key: setKey,
    }),
  ]);
  check(!r1.error && !r2.error && r1.data?.set_id === r2.data?.set_id, 'two concurrent RECORD_SET calls with the SAME key produce exactly one set', [r1.data, r2.data, r1.error, r2.error]);

  // Probe 3: a DIFFERENT athlete starting with a different key never collides with probe 1's session.
  const startKey2 = uuid();
  const otherStart = await p.formerCoach.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: startKey2 });
  check(!otherStart.error && otherStart.data?.session_id !== sessionId, 'a different athlete/key starts an independent session', otherStart.error ?? otherStart.data);

  // Probe 4: the SAME athlete cannot hold two concurrent in-progress sessions (different keys).
  const secondSessionAttempt = await p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: uuid() });
  check(secondSessionAttempt.error?.code === '23505', 'the same athlete starting a SECOND session (different key) is rejected with 23505', secondSessionAttempt.error);

  // Probe 5: set recording racing completion — row-lock serializes; whichever wins, no corruption either way.
  const raceSetKey = uuid();
  const [setRace, completeRace] = await Promise.all([
    p.athleteA.client.rpc('record_session_set', {
      p_session_id: sessionId,
      p_session_exercise_id: sessionExerciseId,
      p_set_data: { set_number: 2, actual_reps: 5, is_completed: true },
      p_idempotency_key: raceSetKey,
    }),
    p.athleteA.client.rpc('complete_workout_session', {
      p_session_id: sessionId,
      p_status: 'completed',
      p_abandonment_reason_code: null,
      p_feedback: null,
      p_private_feedback: null,
      p_idempotency_key: uuid(),
    }),
  ]);
  const oneWon = (!setRace.error && !completeRace.error) || (setRace.error?.code === '22000') !== (completeRace.error?.code === '22000');
  check(
    !completeRace.error && (!setRace.error || setRace.error.code === '22000'),
    'set-recording racing completion: completion always succeeds; the set either wins cleanly or fails closed with 22000 (never corrupts the terminal session)',
    { setRace: setRace.error, completeRace: completeRace.error },
  );

  console.log(`\n# Concurrency ids: session=${sessionId} otherSession=${otherStart.data?.session_id}`);
  finish();
}

const command = process.argv[2];
const commands = { setup, slice1, slice2, concurrency };
if (!commands[command]) {
  console.error('Usage: sprint4-slices.mjs setup|slice1|slice2|concurrency');
  process.exit(2);
}
await commands[command]();
