#!/usr/bin/env node
/**
 * Sprint 5 · Tasks 5.9 / 5.15 — hosted verification of Acceptance Slices 1-3
 * and the concurrency probes for Assignments & Database-Level Scheduling.
 *
 * Drives the real Supabase stack (Auth + PostgREST + Postgres/RLS) through
 * supabase-js, one client per person, exactly as the app does.
 *
 *   setup        Registers tagged fixtures (two Coaches, three Athletes, a Former
 *                Coach, Leader, Vice President, Leader in a second organization),
 *                has the President approve them, saves credentials to a local
 *                state file (never printed) and prints the operator SQL step
 *                (positions, second organization, coaching relationships).
 *   slice1       Assignment creation, multi-targeting, recurrence, RLS reach.
 *   slice2       Live occurrence execution, then an overdue occurrence for the
 *                operator's cron step.
 *   slice2b      After the operator ran the overdue job: missed + cron audit,
 *                cancellation, preserved history.
 *   slice3       Rule C version migration (selected / future-only / boundaries).
 *   concurrency  Race probes that two client sessions can drive (same-key
 *                duplicates, different-key start race, start vs cancellation,
 *                duplicate cancel / migrate). The probes that need a service-side
 *                actor (overdue job, generator) are driven by
 *                scripts/e2e/sprint5-cron-races.sql through two parallel SQL sessions.
 *
 * Fixtures carry the tags from scripts/test/fixtures.mjs and are removed with
 * scripts/test/cleanup-fixtures.mjs. Env: as sprint4-slices.mjs, plus optional
 * E2E_STATE_FILE (default: <os tmpdir>/bacalsys-sprint5-e2e.json).
 *
 *   node --env-file=.env.hosted.local scripts/e2e/sprint5-slices.mjs setup|slice1|slice2|slice2b|slice3|concurrency
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
const stateFile = process.env.E2E_STATE_FILE ?? join(tmpdir(), 'bacalsys-sprint5-e2e.json');
const TZ = 'Asia/Manila'; // the seeded organization's timezone
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
const saveState = (state) => writeFileSync(stateFile, JSON.stringify(state, null, 2), { mode: 0o600 });
const people = async (state) => {
  const out = { president: await signIn(PRESIDENT) };
  for (const [role, f] of Object.entries(state.fixtures)) out[role] = await signIn(f);
  return out;
};
const uuid = () => crypto.randomUUID();

// Organization-local calendar dates (the seeded organization runs on Asia/Manila).
const isoDate = (d) => d.toLocaleDateString('en-CA', { timeZone: TZ });
const today = () => isoDate(new Date());
const addDays = (iso, n) => {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const isoDow = (iso) => ((new Date(`${iso}T12:00:00Z`).getUTCDay() + 6) % 7) + 1;
const horizon = () => Array.from({ length: 14 }, (_, i) => addDays(today(), i));

async function byBySlug(client, slugs) {
  const { data, error } = await client.from('exercises').select('id, slug').in('slug', slugs);
  if (error) throw error;
  return Object.fromEntries(data.map((e) => [e.slug, e.id]));
}

/** Coach authors an organization routine (push-up + plank); returns {templateId, versionId, pushUpItemId}. */
async function seedRoutine(coachClient, label) {
  const ids = await byBySlug(coachClient, ['push-up', 'plank']);
  const created = await coachClient.rpc('create_workout_template', {
    p_name: `Sprint5 Fixture Routine ${label}`,
    p_description: null,
    p_visibility: 'organization',
    p_blocks: [
      {
        title: 'Main',
        block_type: 'standard_set',
        items: [
          { exercise_id: ids['push-up'], measurement_mode: 'reps', sets: [{ target_reps: 10 }] },
          { exercise_id: ids['plank'], measurement_mode: 'duration', sets: [{ target_duration_seconds: 30 }] },
        ],
      },
    ],
  });
  if (created.error) throw created.error;
  const versionId = created.data.version_id;
  const blocks = await coachClient.from('workout_blocks').select('id').eq('workout_version_id', versionId);
  const items = await coachClient.from('workout_items').select('id, exercise_id').in('block_id', blocks.data.map((b) => b.id));
  return { templateId: created.data.template_id, versionId, pushUpItemId: items.data.find((i) => i.exercise_id === ids['push-up']).id };
}

async function publishVersion(coachClient, templateId, reps) {
  const ids = await byBySlug(coachClient, ['push-up']);
  const r = await coachClient.rpc('publish_new_workout_version', {
    p_template_id: templateId,
    p_version_notes: `reps ${reps}`,
    p_blocks: [{ title: 'Main', block_type: 'standard_set', items: [{ exercise_id: ids['push-up'], measurement_mode: 'reps', sets: [{ target_reps: reps }] }] }],
  });
  if (r.error) throw r.error;
  return r.data.version_id;
}

const createAssignment = (client, { templateId, versionId = null, targets, date = null, rule = null, notes = null, key: k = uuid() }) =>
  client.rpc('create_workout_assignment', {
    p_workout_template_id: templateId,
    p_workout_version_id: versionId,
    p_target_athlete_ids: targets,
    p_target_date: date,
    p_is_recurring: !!rule,
    p_recurrence_rule: rule,
    p_notes: notes,
    p_idempotency_key: k,
  });

const occurrencesOf = async (client, assignmentId, athleteId) => {
  let q = client.from('assignment_occurrences').select('*').eq('assignment_id', assignmentId).order('scheduled_date');
  if (athleteId) q = q.eq('athlete_id', athleteId);
  const { data, error } = await q;
  if (error) throw error;
  return data;
};

// ---------------------------------------------------------------------------
async function setup() {
  const runId = `s5r${Date.now()}`;
  const roles = {
    coachA: 'Coach A',
    coachB: 'Coach B',
    athleteA: 'Athlete A',
    athleteB: 'Athlete B',
    athleteC: 'Athlete C',
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
  const orgB = uuid();
  const branchB = uuid();
  saveState({ runId, fixtures, orgB, branchB });
  const f = (r) => fixtures[r].id;
  console.log(`\n# State (credentials) written to ${stateFile}`);
  console.log(`
# ---------------------------------------------------------------------------
# Operator SQL step (run once via the Supabase MCP / SQL editor):
# ---------------------------------------------------------------------------
INSERT INTO public.organizations (id, name, slug) VALUES ('${orgB}', 'Sprint5 Club B', 'sprint5-club-b-${runId}');
INSERT INTO public.branches (id, organization_id, name) VALUES ('${branchB}', '${orgB}', 'Sprint5 Club B Branch');
UPDATE public.profiles SET home_branch_id = '${branchB}' WHERE id = '${f('leaderB')}';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT v.pid::uuid, pos.id FROM (VALUES
  ('${f('coachA')}', 'Coach'), ('${f('coachB')}', 'Coach'), ('${f('formerCoach')}', 'Coach'),
  ('${f('leader')}', 'Leader'), ('${f('vp')}', 'Vice President'), ('${f('leaderB')}', 'Leader')
) AS v(pid, pname) JOIN public.positions pos ON pos.name = v.pname
ON CONFLICT DO NOTHING;
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by) VALUES
  ('${f('athleteA')}', '${f('coachA')}', '${f('vp')}'),
  ('${f('athleteC')}', '${f('coachA')}', '${f('vp')}'),
  ('${f('athleteB')}', '${f('coachB')}', '${f('vp')}');
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at) VALUES
  ('${f('athleteA')}', '${f('formerCoach')}', '${f('vp')}', now() - interval '40 days', now() - interval '10 days');
`);
  finish();
}

// ---------------------------------------------------------------------------
async function slice1() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const B = state.fixtures.athleteB.id;
  const C = state.fixtures.athleteC.id;
  const { templateId, versionId } = await seedRoutine(p.coachA.client, state.runId);
  state.template = { templateId, versionId };

  // 1. Leader programs Athletes A + B on a recurring Mon/Wed/Fri schedule with a coach note.
  const rule = { days_of_week: [5, 1, 3, 1], start_date: today(), end_date: null, timezone: TZ };
  const recurring = await createAssignment(p.leader.client, {
    templateId, targets: [A, B], rule, notes: 'Focus on strict form and controlled eccentric.',
  });
  check(!recurring.error && recurring.data?.status === 'active', 'the Leader creates a recurring Mon/Wed/Fri assignment for Athletes A and B', recurring.error ?? recurring.data);
  const recurringId = recurring.data.assignment_id;
  const expectedDays = horizon().filter((d) => [1, 3, 5].includes(isoDow(d)));
  check(recurring.data.occurrences_created === expectedDays.length * 2, `it generated ${expectedDays.length * 2} occurrences (${expectedDays.length} days x 2 athletes)`, recurring.data);

  // 2. Coach A programs a single-date assignment for their own Athlete A (tomorrow).
  const tomorrow = addDays(today(), 1);
  const single = await createAssignment(p.coachA.client, { templateId, targets: [A], date: tomorrow });
  check(!single.error && single.data?.occurrences_created === 1, 'Coach A creates a single-date assignment for Athlete A tomorrow', single.error ?? single.data);
  const singleId = single.data.assignment_id;

  // Replay: same key + payload = the same assignment (idempotent create).
  const k = uuid();
  const r1 = await createAssignment(p.coachA.client, { templateId, targets: [C], date: addDays(today(), 3), key: k });
  const r2 = await createAssignment(p.coachA.client, { templateId, targets: [C], date: addDays(today(), 3), key: k });
  check(!r1.error && !r2.error && r1.data.assignment_id === r2.data.assignment_id, 'replaying the same idempotency key returns the SAME assignment', [r1.error, r2.error]);
  const dupKeyDifferentPayload = await createAssignment(p.coachA.client, { templateId, targets: [C], date: addDays(today(), 4), key: k });
  check(dupKeyDifferentPayload.error?.code === '42501', 'the same key with a different payload fails closed (42501)', dupKeyDifferentPayload.error);

  // 3. Shape of what was stored (read as the Leader, who sees the whole organization).
  const asg = await p.leader.client.from('workout_assignments').select('id, status, is_recurring, workout_version_id').in('id', [recurringId, singleId]);
  check(asg.data?.length === 2 && asg.data.every((a) => a.status === 'active' && a.workout_version_id === versionId), 'both assignments are active and pinned to the sealed version', asg.data);
  const targets = await p.leader.client.from('assignment_targets').select('assignment_id, athlete_id').in('assignment_id', [recurringId, singleId]);
  check(targets.data?.length === 3, 'assignment_targets holds 3 rows (2 recurring + 1 single-date)', targets.data);
  const sched = await p.leader.client.from('recurring_schedules').select('days_of_week, timezone, is_active').eq('assignment_id', recurringId).single();
  check(JSON.stringify(sched.data?.days_of_week) === '[1,3,5]' && sched.data.timezone === TZ && sched.data.is_active, 'the schedule stores the normalized weekdays {1,3,5}, the org timezone, active', sched.data);
  const occA = await occurrencesOf(p.leader.client, recurringId, A);
  const occB = await occurrencesOf(p.leader.client, recurringId, B);
  check(
    JSON.stringify(occA.map((o) => o.scheduled_date)) === JSON.stringify(expectedDays) &&
      JSON.stringify(occB.map((o) => o.scheduled_date)) === JSON.stringify(expectedDays),
    'each athlete has exactly the Mon/Wed/Fri dates of [today, today+13]',
    { occA: occA.map((o) => o.scheduled_date), expectedDays },
  );
  const first = occA[0];
  check(
    new Date(first.due_datetime) - new Date(first.scheduled_at) === 24 * 3600 * 1000 && first.status === 'upcoming',
    'occurrence due_datetime is the next local midnight (24h after scheduled_at on a non-DST day), status upcoming',
    first,
  );

  // 4. What each person can see (RLS, live).
  const athleteAView = await p.athleteA.client.from('assignment_occurrences').select('id, athlete_id');
  check(athleteAView.data?.length > 0 && athleteAView.data.every((o) => o.athlete_id === A), 'Athlete A sees only their own occurrences (upcoming workouts)', athleteAView.data?.length);
  const athleteBView = await p.athleteB.client.from('assignment_occurrences').select('id, athlete_id, assignment_id');
  check(athleteBView.data?.length === occB.length && athleteBView.data.every((o) => o.athlete_id === B && o.assignment_id === recurringId), "Athlete B sees only their own Mon/Wed/Fri occurrences", athleteBView.data?.length);
  const athleteBTargets = await p.athleteB.client.from('assignment_targets').select('athlete_id');
  check(athleteBTargets.data?.length === 1 && athleteBTargets.data[0].athlete_id === B, "Athlete B sees only their OWN target row", athleteBTargets.data);
  const coachATargets = await p.coachA.client.from('assignment_targets').select('assignment_id, athlete_id').eq('assignment_id', recurringId);
  check(coachATargets.data?.length === 1 && coachATargets.data[0].athlete_id === A, "Athlete A's coach sees Athlete A's target row but NOT Athlete B's (target-safe RLS)", coachATargets.data);
  const coachAOcc = await p.coachA.client.from('assignment_occurrences').select('athlete_id').eq('assignment_id', recurringId);
  check(coachAOcc.data?.length === occA.length && coachAOcc.data.every((o) => o.athlete_id === A), "Athlete A's coach sees only Athlete A's occurrences on the shared assignment", coachAOcc.data?.length);
  const coachBTargets = await p.coachB.client.from('assignment_targets').select('athlete_id').eq('assignment_id', recurringId);
  check(coachBTargets.data?.length === 1 && coachBTargets.data[0].athlete_id === B, "Athlete B's coach sees only Athlete B's target row", coachBTargets.data);
  const otherOrg = await Promise.all([
    p.leaderB.client.from('workout_assignments').select('id').in('id', [recurringId, singleId]),
    p.leaderB.client.from('assignment_targets').select('id').in('assignment_id', [recurringId, singleId]),
    p.leaderB.client.from('recurring_schedules').select('id').eq('assignment_id', recurringId),
    p.leaderB.client.from('assignment_occurrences').select('id').in('assignment_id', [recurringId, singleId]),
  ]);
  check(otherOrg.every((r) => r.data?.length === 0), 'a leader from ANOTHER organization receives 0 rows of these assignments, targets, schedules and occurrences', otherOrg.map((r) => r.data?.length));

  // 5. Former coach: 0 assignment rows; sees only an occurrence scheduled inside their closed window.
  const past = await createAssignment(p.leader.client, { templateId, targets: [A], date: addDays(today(), -20) });
  check(!past.error, 'the Leader records a past-dated assignment (falls inside the former coach tenure)', past.error);
  const formerAsg = await p.formerCoach.client.from('workout_assignments').select('id');
  const formerTargets = await p.formerCoach.client.from('assignment_targets').select('id');
  const formerOcc = await p.formerCoach.client.from('assignment_occurrences').select('id, assignment_id');
  check(formerAsg.data?.length === 0 && formerTargets.data?.length === 0, 'the FORMER coach sees 0 assignments and 0 targets', [formerAsg.data?.length, formerTargets.data?.length]);
  check(formerOcc.data?.length === 1 && formerOcc.data[0].assignment_id === past.data.assignment_id, 'the FORMER coach sees exactly the occurrence scheduled inside their closed coaching window', formerOcc.data);

  // 6. Authority checks over the wire.
  const athleteTries = await createAssignment(p.athleteA.client, { templateId, targets: [A], date: addDays(today(), 5) });
  check(athleteTries.error?.code === '42501', 'an athlete cannot create an assignment (42501)', athleteTries.error);
  const coachOutOfScope = await createAssignment(p.coachA.client, { templateId, targets: [B], date: addDays(today(), 5) });
  check(coachOutOfScope.error?.code === '42501', "a coach cannot assign to an athlete they do not coach (42501)", coachOutOfScope.error);
  const direct = await p.coachA.client.from('workout_assignments').insert({ organization_id: uuid(), workout_template_id: templateId, workout_version_id: versionId, assigned_by: state.fixtures.coachA.id, target_date: today() });
  check(direct.error?.code === '42501', 'direct client INSERT into workout_assignments is rejected (42501)', direct.error);

  state.slice1 = { recurringId, singleId, pastId: past.data.assignment_id };
  saveState(state);
  console.log(`\n# Slice 1 ids: recurring=${recurringId} single=${singleId} past=${past.data.assignment_id}`);
  finish();
}

// ---------------------------------------------------------------------------
async function slice2() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const B = state.fixtures.athleteB.id;
  const { templateId, versionId } = state.template;

  // 1. Athlete A starts TODAY's recurring occurrence if their schedule has one, else a fresh single-date one.
  const todays = await createAssignment(p.coachA.client, { templateId, versionId, targets: [A], date: today(), notes: 'Slice 2 live occurrence' });
  check(!todays.error, "Coach A programs today's workout for Athlete A", todays.error);
  const occToday = (await occurrencesOf(p.athleteA.client, todays.data.assignment_id, A))[0];
  check(occToday?.status === 'upcoming' && occToday.scheduled_date === today(), "Athlete A sees today's occurrence as upcoming", occToday);

  const started = await p.athleteA.client.rpc('start_workout_session', {
    p_workout_version_id: versionId, p_idempotency_key: uuid(), p_assignment_occurrence_id: occToday.id,
  });
  check(!started.error && started.data?.assignment_occurrence_id === occToday.id, 'the Workout Player starts a session linked to the occurrence', started.error ?? started.data);
  const afterStart = (await occurrencesOf(p.athleteA.client, todays.data.assignment_id, A))[0];
  check(afterStart.status === 'in_progress', 'the occurrence moved upcoming -> in_progress', afterStart);
  const mapping = started.data.exercise_mapping;
  const firstSe = Object.values(mapping)[0];
  const setRes = await p.athleteA.client.rpc('record_session_set', {
    p_session_id: started.data.session_id, p_session_exercise_id: firstSe,
    p_set_data: { set_number: 1, actual_reps: 10, is_completed: true }, p_idempotency_key: uuid(),
  });
  check(!setRes.error, 'the athlete records a set', setRes.error);
  const done = await p.athleteA.client.rpc('complete_workout_session', {
    p_session_id: started.data.session_id, p_status: 'completed', p_abandonment_reason_code: null,
    p_feedback: { difficulty_rating: 6, energy_level: 4 }, p_private_feedback: null, p_idempotency_key: uuid(),
  });
  check(!done.error, 'the athlete finishes the session', done.error);
  const afterDone = (await occurrencesOf(p.athleteA.client, todays.data.assignment_id, A))[0];
  check(afterDone.status === 'completed' && !!afterDone.completed_at, 'the occurrence moved in_progress -> completed with completed_at populated', afterDone);
  const dml = await Promise.all([
    p.athleteA.client.from('assignment_occurrences').update({ status: 'upcoming', completed_at: null }).eq('id', occToday.id).select(),
    p.athleteA.client.from('assignment_occurrences').delete().eq('id', occToday.id).select(),
  ]);
  check(dml.every((r) => r.error?.code === '42501' || (r.data?.length ?? 0) === 0), 'a client UPDATE / DELETE of the completed occurrence changes nothing (no DML grant; privileged path 22000 is covered by pgTAP and slice2b)', dml.map((r) => r.error?.code ?? r.data?.length));

  // 2. YESTERDAY's unstarted occurrence for Athlete B (overdue: due_datetime already passed).
  const yesterday = addDays(today(), -1);
  const overdue = await createAssignment(p.leader.client, { templateId, targets: [B], date: yesterday, notes: 'Slice 2 overdue' });
  check(!overdue.error, "the Leader records yesterday's assignment for Athlete B", overdue.error);
  const occYesterday = (await occurrencesOf(p.athleteB.client, overdue.data.assignment_id, B))[0];
  check(occYesterday.status === 'upcoming' && new Date(occYesterday.due_datetime) < new Date(), "yesterday's occurrence is still upcoming but its due_datetime is in the past", occYesterday);

  // 3. A recurring assignment for the cancellation step (Athlete A + C, every day).
  const C = state.fixtures.athleteC.id;
  const rec = await createAssignment(p.coachA.client, {
    templateId, targets: [A, C], rule: { days_of_week: [1, 2, 3, 4, 5, 6, 7], start_date: today(), end_date: null, timezone: TZ },
  });
  check(!rec.error && rec.data.occurrences_created > 0, 'Coach A creates an every-day recurring assignment for Athletes A and C (to cancel later)', rec.error ?? rec.data);

  state.slice2 = { todaysId: todays.data.assignment_id, occTodayId: occToday.id, overdueAssignmentId: overdue.data.assignment_id, occYesterdayId: occYesterday.id, cancelId: rec.data.assignment_id, createdOnce: rec.data.occurrences_created };
  saveState(state);
  console.log(`
# ---------------------------------------------------------------------------
# Operator step: run the overdue job once (it is scheduled hourly by pg_cron):
#   SELECT app_private.mark_overdue_assignments_as_missed();
# then: node --env-file=.env.hosted.local scripts/e2e/sprint5-slices.mjs slice2b
# ---------------------------------------------------------------------------`);
  finish();
}

// ---------------------------------------------------------------------------
async function slice2b() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const s = state.slice2;

  const occ = await p.athleteB.client.from('assignment_occurrences').select('status').eq('id', s.occYesterdayId).single();
  check(occ.data?.status === 'missed', "yesterday's unstarted occurrence is now 'missed'", occ.data);
  const audit = await p.president.client.from('audit_logs').select('actor_type, actor_user_id, old_values, new_values')
    .eq('entity_type', 'assignment_occurrence').eq('entity_id', s.occYesterdayId).eq('action', 'updated');
  check(
    audit.data?.length === 1 && audit.data[0].actor_type === 'cron' && audit.data[0].actor_user_id === null &&
      audit.data[0].new_values?.status === 'missed',
    "the transition is audited with actor_type 'cron' and no user id", audit.data,
  );
  const todays = await p.athleteA.client.from('assignment_occurrences').select('status').eq('id', s.occTodayId).single();
  check(todays.data?.status === 'completed', "today's completed occurrence was not touched by the overdue job", todays.data);

  // Seed history that must survive cancellation: yesterday's overdue upcoming for A is created directly? — done via
  // the past-dated single assignment below, then cancelled with the recurring one.
  const past = await createAssignment(p.coachA.client, { templateId: state.template.templateId, targets: [A], date: addDays(today(), -1) });
  check(!past.error, 'Coach A records an overdue (yesterday) occurrence for Athlete A', past.error);

  // Cancel the recurring assignment as its (only) coach; both targets are Coach A's athletes.
  const beforeCancel = await occurrencesOf(p.coachA.client, s.cancelId, null);
  const cancelKey = uuid();
  const cancelled = await p.coachA.client.rpc('cancel_workout_assignment', { p_assignment_id: s.cancelId, p_idempotency_key: cancelKey });
  check(!cancelled.error && cancelled.data?.status === 'cancelled', 'Coach A cancels the recurring assignment', cancelled.error ?? cancelled.data);
  const replay = await p.coachA.client.rpc('cancel_workout_assignment', { p_assignment_id: s.cancelId, p_idempotency_key: cancelKey });
  check(!replay.error && replay.data?.status === 'cancelled', 'replaying the cancel key returns the cached result', replay.error);
  const afterCancel = await occurrencesOf(p.coachA.client, s.cancelId, null);
  check(beforeCancel.length > 0 && afterCancel.filter((o) => o.status === 'upcoming' && o.scheduled_date >= today()).length === 0,
    'every future / today upcoming occurrence of the cancelled assignment was deleted', { before: beforeCancel.length, after: afterCancel.length });
  const history = afterCancel.filter((o) => o.scheduled_date < today() && o.athlete_id === A).map((o) => o.status);
  check(JSON.stringify(history) === JSON.stringify(['completed', 'missed', 'upcoming']),
    "F-S5-P12: the cancelled assignment's PAST history (completed, missed, overdue upcoming) is strictly preserved", history);
  const stillThere = await Promise.all([
    p.athleteB.client.from('assignment_occurrences').select('status').eq('id', s.occYesterdayId).single(),
    p.athleteA.client.from('assignment_occurrences').select('status').eq('id', s.occTodayId).single(),
  ]);
  check(stillThere[0].data?.status === 'missed' && stillThere[1].data?.status === 'completed', 'the missed and completed history (other assignments) is untouched', stillThere.map((r) => r.data));
  const asg = await p.coachA.client.from('workout_assignments').select('status').eq('id', s.cancelId).single();
  const sch = await p.coachA.client.from('recurring_schedules').select('is_active').eq('assignment_id', s.cancelId).single();
  check(asg.data?.status === 'cancelled' && sch.data?.is_active === false, 'the assignment is cancelled and its schedule deactivated', [asg.data, sch.data]);
  const cancelAudit = await p.president.client.from('audit_logs').select('actor_type, new_values').eq('entity_type', 'workout_assignment').eq('entity_id', s.cancelId).eq('action', 'cancelled');
  check(cancelAudit.data?.length === 1 && cancelAudit.data[0].actor_type === 'user', "the cancellation is audited as actor_type 'user'", cancelAudit.data);

  // A start on the cancelled assignment's past occurrence (if any survived) or a deleted id fails closed.
  const tryStart = await p.athleteA.client.rpc('start_workout_session', {
    p_workout_version_id: state.template.versionId, p_idempotency_key: uuid(), p_assignment_occurrence_id: beforeCancel.find((o) => o.athlete_id === A).id,
  });
  check(tryStart.error?.code === '22000', 'starting an occurrence of the cancelled assignment fails closed (22000)', tryStart.error);

  console.log(`
# Privileged-path proof (run via the SQL editor — direct DML by a privileged role must still fail 22000):
#   DO $$ BEGIN UPDATE public.assignment_occurrences SET status='upcoming', completed_at=NULL WHERE id='${s.occTodayId}'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'UPDATE -> %', SQLSTATE; END $$;
#   DO $$ BEGIN DELETE FROM public.assignment_occurrences WHERE id='${s.occTodayId}'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'DELETE -> %', SQLSTATE; END $$;`);
  finish();
}

// ---------------------------------------------------------------------------
async function slice3() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const { templateId, versionId: v1 } = await seedRoutine(p.coachA.client, `${state.runId}-s3`);
  const v2 = await publishVersion(p.coachA.client, templateId, 12);

  // Recurring assignment starting late in the horizon so the generator still has days left to fill.
  const startLate = addDays(today(), 9);
  const rule = { days_of_week: [1, 2, 3, 4, 5, 6, 7], start_date: startLate, end_date: null, timezone: TZ };
  const sel = await createAssignment(p.coachA.client, { templateId, versionId: v1, targets: [A], rule });
  check(!sel.error, 'Coach A creates a recurring assignment pinned to V1', sel.error);
  const occs = await occurrencesOf(p.coachA.client, sel.data.assignment_id, A);
  const [o1, o2, o3] = occs;
  const migrate = await p.coachA.client.rpc('migrate_assignment_version', {
    p_assignment_id: sel.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'selected_upcoming_assignments',
    p_selected_occurrence_ids: [o2.id, o3.id], p_idempotency_key: uuid(),
  });
  check(!migrate.error && migrate.data?.updated_occurrences === 2, 'selected_upcoming_assignments migrates the two selected occurrences', migrate.error ?? migrate.data);
  const after = await occurrencesOf(p.coachA.client, sel.data.assignment_id, A);
  const asgRow = await p.coachA.client.from('workout_assignments').select('workout_version_id').eq('id', sel.data.assignment_id).single();
  check(asgRow.data?.workout_version_id === v1, 'the assignment DEFAULT version is still V1', asgRow.data);
  check(after[0].workout_version_id === v1 && after[1].workout_version_id === v2 && after[2].workout_version_id === v2, 'occurrence 1 stays on V1; occurrences 2 and 3 are on V2', after.slice(0, 3).map((o) => o.workout_version_id));
  const audit = await p.president.client.from('audit_logs').select('actor_type, new_values').eq('entity_type', 'workout_assignment').eq('entity_id', sel.data.assignment_id).eq('action', 'version_migrated');
  check(
    audit.data?.length === 1 && audit.data[0].new_values.migration_choice === 'selected_upcoming_assignments' &&
      audit.data[0].new_values.migrated_occurrence_ids?.length === 2 && audit.data[0].new_values.old_version_id === v1 && audit.data[0].new_values.new_version_id === v2,
    "version_migrated is audited with the choice, old/new versions and the migrated occurrence ids", audit.data,
  );

  // Boundaries: an in_progress or completed occurrence in the selection fails 22000.
  const todaysAsg = await createAssignment(p.coachA.client, { templateId, versionId: v1, targets: [A], date: today() });
  const todaysOcc = (await occurrencesOf(p.athleteA.client, todaysAsg.data.assignment_id, A))[0];
  const started = await p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: v1, p_idempotency_key: uuid(), p_assignment_occurrence_id: todaysOcc.id });
  check(!started.error, 'Athlete A starts an occurrence (now in_progress)', started.error);
  const inProgTry = await p.coachA.client.rpc('migrate_assignment_version', {
    p_assignment_id: todaysAsg.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'selected_upcoming_assignments',
    p_selected_occurrence_ids: [todaysOcc.id], p_idempotency_key: uuid(),
  });
  check(inProgTry.error?.code === '22000', 'migrating an IN-PROGRESS occurrence fails closed (22000)', inProgTry.error);
  await p.athleteA.client.rpc('complete_workout_session', { p_session_id: started.data.session_id, p_status: 'completed', p_abandonment_reason_code: null, p_feedback: null, p_private_feedback: null, p_idempotency_key: uuid() });
  const doneTry = await p.coachA.client.rpc('migrate_assignment_version', {
    p_assignment_id: todaysAsg.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'selected_upcoming_assignments',
    p_selected_occurrence_ids: [todaysOcc.id], p_idempotency_key: uuid(),
  });
  check(doneTry.error?.code === '22000', 'migrating a COMPLETED occurrence fails closed (22000)', doneTry.error);
  const sessionAfter = await p.athleteA.client.from('workout_sessions').select('workout_version_id').eq('id', started.data.session_id).single();
  check(sessionAfter.data?.workout_version_id === v1, 'the workout session stays pinned to its original version', sessionAfter.data);

  // future_assignments_only on a separate recurring assignment.
  const fut = await createAssignment(p.coachA.client, { templateId, versionId: v1, targets: [A], rule: { ...rule, start_date: addDays(today(), 9) } });
  const before = await occurrencesOf(p.coachA.client, fut.data.assignment_id, A);
  const futMig = await p.coachA.client.rpc('migrate_assignment_version', {
    p_assignment_id: fut.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'future_assignments_only', p_selected_occurrence_ids: null, p_idempotency_key: uuid(),
  });
  check(!futMig.error && futMig.data?.updated_occurrences === 0, 'future_assignments_only reports 0 updated occurrences', futMig.error ?? futMig.data);
  const futAsg = await p.coachA.client.from('workout_assignments').select('workout_version_id').eq('id', fut.data.assignment_id).single();
  const futAfter = await occurrencesOf(p.coachA.client, fut.data.assignment_id, A);
  check(futAsg.data?.workout_version_id === v2 && futAfter.length === before.length && futAfter.every((o) => o.workout_version_id === v1),
    'future_assignments_only: the assignment default is now V2 while every EXISTING occurrence stays on V1', { asg: futAsg.data, n: futAfter.length });
  const templateOnly = await p.coachA.client.rpc('migrate_assignment_version', {
    p_assignment_id: sel.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'template_only', p_selected_occurrence_ids: null, p_idempotency_key: uuid(),
  });
  check(!templateOnly.error && templateOnly.data?.updated_occurrences === 0, 'template_only changes nothing', templateOnly.error ?? templateOnly.data);
  const outsider = await p.coachB.client.rpc('migrate_assignment_version', {
    p_assignment_id: sel.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'template_only', p_selected_occurrence_ids: null, p_idempotency_key: uuid(),
  });
  check(outsider.error?.code === '42501', 'a coach without scope over the target cannot migrate (42501)', outsider.error);

  state.slice3 = { selId: sel.data.assignment_id, futId: fut.data.assignment_id, v1, v2 };
  saveState(state);
  finish();
}

// ---------------------------------------------------------------------------
async function concurrency() {
  const state = loadState();
  const p = await people(state);
  const A = state.fixtures.athleteA.id;
  const { templateId, versionId } = state.template;
  const singleFor = async (offset) => {
    const r = await createAssignment(p.leader.client, { templateId, versionId, targets: [A], date: addDays(today(), offset) });
    if (r.error) throw r.error;
    const occ = (await occurrencesOf(p.athleteA.client, r.data.assignment_id, A))[0];
    return { assignmentId: r.data.assignment_id, occId: occ.id };
  };
  const startRpc = (occId, k = uuid()) => p.athleteA.client.rpc('start_workout_session', { p_workout_version_id: versionId, p_idempotency_key: k, p_assignment_occurrence_id: occId });
  const finishSession = (sessionId) =>
    p.athleteA.client.rpc('complete_workout_session', { p_session_id: sessionId, p_status: 'completed', p_abandonment_reason_code: null, p_feedback: null, p_private_feedback: null, p_idempotency_key: uuid() });

  // Probe 1: two concurrent CREATE_ASSIGNMENT calls, identical payload + key.
  const ck = uuid();
  const payload = { templateId, versionId, targets: [A], date: addDays(today(), 20 + Math.floor(Math.random() * 200)), key: ck };
  const [c1, c2] = await Promise.all([createAssignment(p.leader.client, payload), createAssignment(p.leader.client, payload)]);
  check(!c1.error && !c2.error && c1.data.assignment_id === c2.data.assignment_id, 'PROBE 1: two concurrent CREATE_ASSIGNMENT calls with the SAME key return the identical assignment', [c1.error, c2.error]);
  const created = await p.leader.client.from('workout_assignments').select('id').eq('id', c1.data.assignment_id);
  const occCount = await p.leader.client.from('assignment_occurrences').select('id').eq('assignment_id', c1.data.assignment_id);
  check(created.data?.length === 1 && occCount.data?.length === 1, 'PROBE 1: exactly ONE assignment and ONE occurrence exist', [created.data?.length, occCount.data?.length]);

  // Probe 2: two concurrent assigned STARTs, same key.
  const one = await singleFor(21);
  const sk = uuid();
  const [s1, s2] = await Promise.all([startRpc(one.occId, sk), startRpc(one.occId, sk)]);
  check(!s1.error && !s2.error && s1.data.session_id === s2.data.session_id, 'PROBE 2: two concurrent assigned START calls with the SAME key return the identical session', [s1.error, s2.error]);
  const sessCount = await p.athleteA.client.from('workout_sessions').select('id').eq('assignment_occurrence_id', one.occId);
  check(sessCount.data?.length === 1, 'PROBE 2: exactly ONE session is linked to the occurrence', sessCount.data?.length);
  await finishSession(s1.data.session_id);

  // Probe 3: two concurrent assigned STARTs, DIFFERENT keys -> one success, the other 22000.
  const rounds = [];
  for (let i = 0; i < 4; i++) {
    const t = await singleFor(22 + i);
    const [a, b] = await Promise.all([startRpc(t.occId), startRpc(t.occId)]);
    const ok = [a, b].filter((r) => !r.error);
    const bad = [a, b].filter((r) => r.error);
    rounds.push({ ok: ok.length, badCodes: bad.map((r) => r.error.code) });
    if (ok[0]) await finishSession(ok[0].data.session_id);
  }
  check(rounds.every((r) => r.ok === 1 && r.badCodes.length === 1 && r.badCodes[0] === '22000'), 'PROBE 3: racing STARTs with DIFFERENT keys on one occurrence: exactly one succeeds, the other fails 22000 (4/4 rounds)', rounds);

  // Probe 4: START racing CANCELLATION on the same occurrence.
  const outcomes = [];
  for (let i = 0; i < 6; i++) {
    const t = await singleFor(30 + i);
    const [st, ca] = await Promise.all([
      startRpc(t.occId),
      p.leader.client.rpc('cancel_workout_assignment', { p_assignment_id: t.assignmentId, p_idempotency_key: uuid() }),
    ]);
    const occAfter = await p.athleteA.client.from('assignment_occurrences').select('status').eq('id', t.occId).maybeSingle();
    const consistent = !ca.error && (
      (!st.error && occAfter.data?.status === 'in_progress') ||   // start committed first: its occurrence survives cancellation
      (st.error?.code === '22000' && occAfter.data === null)      // cancellation committed first: occurrence deleted, start fails closed
    );
    outcomes.push({ start: st.error?.code ?? 'ok', cancel: ca.error?.code ?? 'ok', occurrence: occAfter.data?.status ?? 'deleted', consistent });
    if (!st.error) await finishSession(st.data.session_id);
  }
  console.log(`# probe 4 outcomes: ${JSON.stringify(outcomes)}`);
  console.log(`# probe 3 rounds: ${JSON.stringify(rounds)}`);
  check(outcomes.every((o) => o.consistent), 'PROBE 4: START vs CANCELLATION always resolves to one of the two legal serializations (start-first keeps its in_progress occurrence; cancel-first makes START fail 22000)', outcomes);

  // Probe 5: duplicate CANCEL and duplicate MIGRATE with the same key.
  const cancelTarget = await singleFor(40);
  const kk = uuid();
  const [x1, x2] = await Promise.all([
    p.leader.client.rpc('cancel_workout_assignment', { p_assignment_id: cancelTarget.assignmentId, p_idempotency_key: kk }),
    p.leader.client.rpc('cancel_workout_assignment', { p_assignment_id: cancelTarget.assignmentId, p_idempotency_key: kk }),
  ]);
  check(!x1.error && !x2.error && x1.data.status === 'cancelled' && x2.data.status === 'cancelled', 'PROBE 5a: two concurrent CANCEL calls with the same key both return the cached logical success', [x1.error, x2.error]);
  const v2 = await publishVersion(p.coachA.client, templateId, 14);
  const migTarget = await createAssignment(p.leader.client, { templateId, versionId, targets: [A], rule: { days_of_week: [1, 2, 3, 4, 5, 6, 7], start_date: addDays(today(), 9), end_date: null, timezone: TZ } });
  const mk = uuid();
  const mig = () => p.leader.client.rpc('migrate_assignment_version', { p_assignment_id: migTarget.data.assignment_id, p_new_version_id: v2, p_migration_choice: 'future_assignments_only', p_selected_occurrence_ids: null, p_idempotency_key: mk });
  const [m1, m2] = await Promise.all([mig(), mig()]);
  check(!m1.error && !m2.error && m1.data.status === 'migrated' && m2.data.status === 'migrated', 'PROBE 5b: two concurrent MIGRATE calls with the same key both return the cached logical success', [m1.error, m2.error]);
  const audits = await p.president.client.from('audit_logs').select('id').eq('action', 'version_migrated').eq('entity_id', migTarget.data.assignment_id);
  check(audits.data?.length === 1, 'PROBE 5b: exactly ONE version_migrated audit row was written', audits.data?.length);

  console.log('\n# Service-side races (START vs overdue job, generator vs cancellation): scripts/e2e/sprint5-cron-races.sql');
  finish();
}

const command = process.argv[2];
const commands = { setup, slice1, slice2, slice2b, slice3, concurrency };
if (!commands[command]) {
  console.error('Usage: sprint5-slices.mjs setup|slice1|slice2|slice2b|slice3|concurrency');
  process.exit(2);
}
await commands[command]();
