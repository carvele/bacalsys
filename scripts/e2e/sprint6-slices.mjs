#!/usr/bin/env node
/**
 * Sprint 6 · Task 6.16 — hosted verification of Slices 1/2 and the concurrency
 * probes for Training History, Statistics & Calisthenics Skills.
 *
 * Drives the real Supabase stack (Auth + PostgREST + Postgres/RLS) through
 * supabase-js, one client per person, exactly as the app does.
 *
 *   setup        Registers tagged disposable fixtures (Coach, Athlete, Leader,
 *                Vice President), prints the activation SQL for the operator step.
 *   slices       Slice 1 (session replay + private-feedback redaction) and
 *                Slice 2 (skill tree progression, attempt review, criteria edit,
 *                verified revocation).
 *   concurrency  The five race probes from Section 13.
 *
 * Fixtures carry the tags from scripts/test/fixtures.mjs and are removed with
 * scripts/test/cleanup-fixtures.mjs.
 *
 *   node --env-file=.env.hosted.local scripts/e2e/sprint6-slices.mjs setup|slices|concurrency
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

const stateFile = process.env.E2E_STATE_FILE ?? join(tmpdir(), 'bacalsys-sprint6-e2e.json');
const newClient = () => createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

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
const saveState = (state) => writeFileSync(stateFile, JSON.stringify(state, null, 2), { mode: 0o600 });
const people = async (state) => {
  const out = {};
  for (const [role, f] of Object.entries(state.fixtures)) out[role] = await signIn(f);
  return out;
};
const uuid = () => crypto.randomUUID();

// ---------------------------------------------------------------------------
async function setup() {
  const runId = `s6r${Date.now()}`;
  const roles = { coach: 'Coach', athlete: 'Athlete', leader: 'Leader', vp: 'Vice President Fixture' };
  const fixtures = {};
  for (const [role, label] of Object.entries(roles)) {
    const email = fixtureEmail(role.toLowerCase(), runId);
    const password = randomPassword();
    const { data, error } = await newClient().auth.signUp({ email, password, options: { data: fixtureMetadata(`${label} ${runId}`) } });
    check(!error && data.user, `register tagged fixture ${label}`, error);
    fixtures[role] = { email, password, id: data.user?.id, name: `${label} ${runId}` };
  }
  saveState({ runId, fixtures });
  const f = (r) => fixtures[r].id;
  console.log(`\n# State (credentials) written to ${stateFile}`);
  console.log(`
-- ---------------------------------------------------------------------------
-- Activation SQL (run once via the Supabase MCP as the Executor, impersonating
-- the hosted project's disposable "Seed President" fixture — never the product
-- owner's personal account):
-- ---------------------------------------------------------------------------
UPDATE public.profiles SET status = 'active' WHERE id IN ('${f('coach')}', '${f('athlete')}', '${f('leader')}', '${f('vp')}');
INSERT INTO public.member_positions (profile_id, position_id)
SELECT v.pid::uuid, pos.id FROM (VALUES
  ('${f('coach')}', 'Coach'), ('${f('athlete')}', 'Athlete'), ('${f('leader')}', 'Leader'), ('${f('vp')}', 'Vice President')
) AS v(pid, pname) JOIN public.positions pos ON pos.name = v.pname
ON CONFLICT DO NOTHING;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES ('${f('athlete')}', '${f('coach')}', '${f('vp')}');
`);
  finish();
}

// ---------------------------------------------------------------------------
async function seedRoutineAndSession(coach, athlete) {
  const push = await coach.client.from('exercises').select('id').eq('slug', 'push-up').single();
  const plank = await coach.client.from('exercises').select('id').eq('slug', 'plank').single();
  const created = await coach.client.rpc('create_workout_template', {
    p_name: `Sprint6 Fixture Routine`,
    p_description: null,
    p_visibility: 'organization',
    p_blocks: [
      {
        title: 'Main',
        block_type: 'standard_set',
        items: [
          { exercise_id: push.data.id, measurement_mode: 'reps', sets: [{ target_reps: 10 }] },
          { exercise_id: plank.data.id, measurement_mode: 'duration', sets: [{ target_duration_seconds: 30 }] },
        ],
      },
    ],
  });
  if (created.error) throw created.error;
  const versionId = created.data.version_id;

  const started = await athlete.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: uuid() });
  if (started.error) throw started.error;
  const sessionId = started.data.session_id;

  const se = await athlete.client.from('session_exercises').select('id, exercise_id').eq('session_id', sessionId);
  const pushSe = se.data.find((x) => x.exercise_id === push.data.id).id;
  await athlete.client.rpc('record_session_set', {
    p_session_id: sessionId,
    p_session_exercise_id: pushSe,
    p_set_data: { set_number: 1, actual_reps: 10, is_completed: true },
    p_idempotency_key: uuid(),
  });

  const completed = await athlete.client.rpc('complete_workout_session', {
    p_session_id: sessionId,
    p_status: 'completed',
    p_abandonment_reason_code: null,
    p_feedback: { difficulty_rating: 7, energy_level: 4 },
    p_private_feedback: { has_discomfort: true, discomfort_area: 'Left Shoulder', note_to_coach: 'pinch at the top' },
    p_idempotency_key: uuid(),
  });
  if (completed.error) throw completed.error;
  return { sessionId, versionId };
}

async function slices() {
  const state = loadState();
  const p = await people(state);

  // -- Slice 1: session replay + Rule E redaction ----------------------------------------------
  const { sessionId } = await seedRoutineAndSession(p.coach, p.athlete);

  const athleteReplay = await p.athlete.client.rpc('get_session_replay', { p_session_id: sessionId });
  check(!athleteReplay.error, 'Slice 1: athlete reads their own replay', athleteReplay.error);
  check(athleteReplay.data?.private_feedback?.discomfort_area === 'Left Shoulder', 'Slice 1: athlete sees their private feedback');

  const coachReplay = await p.coach.client.rpc('get_session_replay', { p_session_id: sessionId });
  check(!coachReplay.error, 'Slice 1: current coach reads the replay', coachReplay.error);
  check(coachReplay.data?.private_feedback?.discomfort_area === 'Left Shoulder', 'Slice 1: current coach sees private feedback');

  const leaderReplay = await p.leader.client.rpc('get_session_replay', { p_session_id: sessionId });
  check(!leaderReplay.error, 'Slice 1: Leader reads the replay (organization-wide training visibility)', leaderReplay.error);
  check(leaderReplay.data?.private_feedback === null, 'Slice 1 Rule E: Leader sees NO private feedback (null)');
  check((leaderReplay.data?.items?.length ?? 0) > 0, 'Slice 1: Leader still sees the workout sets themselves');

  const summary = await p.athlete.client.rpc('get_my_athlete_summary', {});
  check(!summary.error && summary.data?.completed_workouts >= 0, "Slice 1: athlete's own summary is reachable", summary.error ?? summary.data);

  const anonReplay = await newClient().rpc('get_session_replay', { p_session_id: sessionId });
  check(anonReplay.error?.code === '42501' || anonReplay.error?.message?.includes('JWT'), 'F-S6-P15: anon is denied on get_session_replay', anonReplay.error);

  // -- Slice 2: skill tree progression, attempt review, criteria edit, revocation ---------------
  const skill = await p.athlete.client.from('skills').select('id').eq('slug', 'planche').single();
  const rung1 = await p.athlete.client.from('skill_progressions').select('id, name').eq('skill_id', skill.data.id).eq('rank_order', 1).single();
  const rung2 = await p.athlete.client.from('skill_progressions').select('id, name').eq('skill_id', skill.data.id).eq('rank_order', 2).single();

  const setStatus = await p.athlete.client.rpc('set_athlete_skill_status', {
    p_athlete_id: p.athlete.id,
    p_skill_id: skill.data.id,
    p_progression_id: rung1.data.id,
    p_idempotency_key: uuid(),
  });
  check(!setStatus.error, 'Slice 2: athlete sets their trained rung (Tuck Planche)', setStatus.error);

  const attempt = await p.athlete.client.rpc('log_skill_attempt', {
    p_progression_id: rung1.data.id,
    p_attempt_date: null,
    p_actual_hold_seconds: 18,
    p_actual_reps: null,
    p_video_url: 'https://youtube.com/watch?v=sample',
    p_idempotency_key: uuid(),
  });
  check(!attempt.error, 'Slice 2: athlete logs an attempt (18s hold, video link)', attempt.error);
  const attemptId = attempt.data?.id;
  check(attempt.data?.status === 'pending_review', 'Slice 2: the attempt enters the queue pending_review');

  const review = await p.coach.client.rpc('review_skill_attempt', {
    p_attempt_id: attemptId,
    p_approved: true,
    p_feedback: 'Flawless protraction and straight arms. Approved!',
    p_idempotency_key: uuid(),
  });
  check(!review.error && review.data?.status === 'approved', 'Slice 2: coach approves the attempt', review.error ?? review.data);
  const achievementId = review.data?.achievement_id;

  const badge = await p.athlete.client.from('skill_achievements').select('status').eq('id', achievementId).single();
  check(badge.data?.status === 'active', 'Slice 2: the achievement is verified (Tier 3 badge)', badge.error ?? badge.data);

  const edit = await p.coach.client.rpc('update_skill_progression', {
    p_progression_id: rung2.data.id,
    p_name: rung2.data.name,
    p_description: 'Hips extended, flat back, straight arms.',
    p_target_hold_seconds: 15,
    p_target_reps: null,
    p_idempotency_key: uuid(),
  });
  check(!edit.error && edit.data?.target_hold_seconds === 15, 'Slice 2: coach edits criteria (12s -> 15s)', edit.error ?? edit.data);

  // audit:view is executive-only (Coach does not hold it) — read as the Vice President.
  const audited = await p.vp.client
    .from('audit_logs')
    .select('action')
    .eq('entity_type', 'skill_progression')
    .eq('entity_id', rung2.data.id)
    .eq('action', 'updated');
  check((audited.data ?? []).length >= 1, 'Slice 2: the criteria edit is audited', audited.error ?? audited.data);

  const badReason = await p.coach.client.rpc('revoke_skill_achievement', { p_achievement_id: achievementId, p_reason: '', p_idempotency_key: uuid() });
  check(badReason.error !== null, 'Slice 2: revoking WITHOUT a reason fails closed', badReason.data);

  const revoke = await p.coach.client.rpc('revoke_skill_achievement', {
    p_achievement_id: achievementId,
    p_reason: 'Video clip was from prior year; form check re-evaluation required',
    p_idempotency_key: uuid(),
  });
  check(!revoke.error && revoke.data?.status === 'revoked', 'Slice 2: coach revokes with a mandatory reason', revoke.error ?? revoke.data);

  finish();
}

// ---------------------------------------------------------------------------
async function concurrency() {
  const state = loadState();
  const p = await people(state);

  const skill = await p.athlete.client.from('skills').select('id').eq('slug', 'front-lever').single();
  const rung = await p.athlete.client.from('skill_progressions').select('id').eq('skill_id', skill.data.id).eq('rank_order', 1).single();
  const rung2 = await p.athlete.client.from('skill_progressions').select('id').eq('skill_id', skill.data.id).eq('rank_order', 2).single();

  const a1 = await p.athlete.client.rpc('log_skill_attempt', {
    p_progression_id: rung.data.id,
    p_attempt_date: null,
    p_actual_hold_seconds: 20,
    p_actual_reps: null,
    p_video_url: null,
    p_idempotency_key: uuid(),
  });
  const attemptId = a1.data?.id;

  // 1. Concurrent review of the SAME attempt with the SAME idempotency key: exactly 1 approval.
  const sameKey = uuid();
  const [r1, r2] = await Promise.all([
    p.coach.client.rpc('review_skill_attempt', { p_attempt_id: attemptId, p_approved: true, p_feedback: 'ok', p_idempotency_key: sameKey }),
    p.coach.client.rpc('review_skill_attempt', { p_attempt_id: attemptId, p_approved: true, p_feedback: 'ok', p_idempotency_key: sameKey }),
  ]);
  check(!r1.error && !r2.error, 'Probe 1: both concurrent calls with the SAME key succeed', [r1.error, r2.error]);
  check(r1.data?.achievement_id === r2.data?.achievement_id, 'Probe 1: both received the identical achievement id (one reservation, exactly one approval)');

  // 2. Concurrent review of a DIFFERENT attempt with DIFFERENT keys: one wins, one loses closed (22000).
  const a2 = await p.athlete.client.rpc('log_skill_attempt', {
    p_progression_id: rung2.data.id,
    p_attempt_date: null,
    p_actual_hold_seconds: 15,
    p_actual_reps: null,
    p_video_url: null,
    p_idempotency_key: uuid(),
  });
  const attempt2Id = a2.data?.id;
  const [c1, c2] = await Promise.all([
    p.coach.client.rpc('review_skill_attempt', { p_attempt_id: attempt2Id, p_approved: true, p_feedback: null, p_idempotency_key: uuid() }),
    p.coach.client.rpc('review_skill_attempt', { p_attempt_id: attempt2Id, p_approved: true, p_feedback: null, p_idempotency_key: uuid() }),
  ]);
  const outcomes = [c1, c2];
  const wins = outcomes.filter((o) => !o.error).length;
  const losses = outcomes.filter((o) => o.error?.code === '22000' || o.error?.message?.includes('already been reviewed')).length;
  check(wins === 1 && losses === 1, 'Probe 2: different-key race on the SAME attempt — exactly one winner, one closed loss (22000)', outcomes.map((o) => o.error?.message ?? 'ok'));

  // 3. Idempotency key reuse with a DIFFERENT payload fails closed (42501).
  const key3 = uuid();
  const first = await p.athlete.client.rpc('log_skill_attempt', {
    p_progression_id: rung.data.id,
    p_attempt_date: null,
    p_actual_hold_seconds: 12,
    p_actual_reps: null,
    p_video_url: null,
    p_idempotency_key: key3,
  });
  const replay = await p.athlete.client.rpc('log_skill_attempt', {
    p_progression_id: rung.data.id,
    p_attempt_date: null,
    p_actual_hold_seconds: 99,
    p_actual_reps: null,
    p_video_url: null,
    p_idempotency_key: key3,
  });
  check(!first.error, 'Probe 3: the first call with key3 succeeds', first.error);
  check(replay.error?.code === '42501', 'Probe 3: the SAME key with a DIFFERENT payload fails closed (42501)', replay.error);

  // 4. Concurrent skill status updates on the SAME (athlete, skill) serialize cleanly.
  const [s1, s2] = await Promise.all([
    p.athlete.client.rpc('set_athlete_skill_status', { p_athlete_id: p.athlete.id, p_skill_id: skill.data.id, p_progression_id: rung.data.id, p_idempotency_key: uuid() }),
    p.athlete.client.rpc('set_athlete_skill_status', { p_athlete_id: p.athlete.id, p_skill_id: skill.data.id, p_progression_id: rung2.data.id, p_idempotency_key: uuid() }),
  ]);
  check(!s1.error && !s2.error, 'Probe 4: two concurrent status updates on the same (athlete, skill) both succeed (no constraint violation)', [s1.error, s2.error]);
  const finalStatus = await p.athlete.client.from('athlete_skill_status').select('current_progression_id').eq('athlete_id', p.athlete.id).eq('skill_id', skill.data.id).single();
  check([rung.data.id, rung2.data.id].includes(finalStatus.data?.current_progression_id), 'Probe 4: exactly one row survives, on one of the two rungs (ON CONFLICT DO UPDATE)', finalStatus.data);

  // 5. Concurrent verify + revoke on the SAME achievement serialize via row locks.
  const ach = await p.coach.client.rpc('verify_skill_achievement', { p_athlete_id: p.athlete.id, p_progression_id: rung.data.id, p_idempotency_key: uuid() });
  const achievementId = ach.data?.id;
  const [v1, v2] = await Promise.all([
    p.vp.client.rpc('verify_skill_achievement', { p_athlete_id: p.athlete.id, p_progression_id: rung.data.id, p_idempotency_key: uuid() }),
    p.coach.client.rpc('revoke_skill_achievement', { p_achievement_id: achievementId, p_reason: 'Race probe', p_idempotency_key: uuid() }),
  ]);
  check(!v1.error && !v2.error, 'Probe 5: concurrent verify (VP) and revoke (Coach) both complete without deadlock', [v1.error, v2.error]);
  const finalAch = await p.coach.client.from('skill_achievements').select('status').eq('id', achievementId).single();
  check(['active', 'revoked'].includes(finalAch.data?.status), 'Probe 5: the achievement lands in ONE deterministic final state (row-locked, never corrupted)', finalAch.data);

  finish();
}

const cmd = process.argv[2];
if (cmd === 'setup') await setup();
else if (cmd === 'slices') await slices();
else if (cmd === 'concurrency') await concurrency();
else {
  console.error('Usage: sprint6-slices.mjs setup|slices|concurrency');
  process.exit(2);
}
