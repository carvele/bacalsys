#!/usr/bin/env node
/**
 * Sprint 3 · Tasks 3.12 / 3.14 — hosted verification of Acceptance Slices 1 and 2.
 *
 * Drives the real Supabase stack (Auth + PostgREST + Postgres/RLS) through
 * supabase-js, one client per person, exactly as the app does.
 *
 *   setup   Registers tagged fixtures (Coach, Athlete, Vice President, Coach B in
 *           a second organization), has the President approve them, and saves
 *           their credentials to a local state file (never printed). Prints the
 *           one operator SQL step: granting positions (there is no
 *           position-assignment RPC yet) and the coaching relationship.
 *   slice1  Hierarchical creation & prescription measurement modes (Section 10).
 *   slice2  Version immutability, historical version safety & deep cloning.
 *   concurrency  Two concurrent publishes; a publish racing a clone (both lock orders).
 *
 * Fixtures carry the tags from scripts/test/fixtures.mjs and are removed with
 * scripts/test/cleanup-fixtures.mjs. Env: as walking-skeleton.mjs, plus optional
 * E2E_STATE_FILE (default: <os tmpdir>/bacalsys-sprint3-e2e.json).
 *
 *   node --env-file=.env.hosted.local scripts/e2e/sprint3-slices.mjs setup|slice1|slice2|concurrency
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
const stateFile = process.env.E2E_STATE_FILE ?? join(tmpdir(), 'bacalsys-sprint3-e2e.json');
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

// One block / one item / one set, for the mode-rule matrix.
const oneSet = (exerciseId, mode, set) => [
  { title: 't', block_type: 'standard_set', items: [{ exercise_id: exerciseId, measurement_mode: mode, sets: [set] }] },
];

// ---------------------------------------------------------------------------------
async function setup() {
  const runId = `s3r${Date.now()}`;
  const roles = { coachA: 'Coach A', athleteA: 'Athlete A', vp: 'Vice President Fixture', coachB: 'Coach B (Org B)' };
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
  console.log('# Fixture ids (for the operator SQL step: positions + a second organization + coaching relationship):');
  for (const [role, f] of Object.entries(fixtures)) console.log(`#   ${role}: ${f.id}`);
  finish();
}

// ---------------------------------------------------------------------------------
async function slice1() {
  const state = loadState();
  const p = await people(state);

  const bySlug = async (client, slugs) => {
    const { data, error } = await client.from('exercises').select('id, slug').in('slug', slugs);
    if (error) throw error;
    return Object.fromEntries(data.map((e) => [e.slug, e.id]));
  };
  const ids = await bySlug(p.coachA.client, ['pull-up', 'parallel-bar-dip', 'hanging-leg-raise', 'push-up']);

  // Canonical Slice 1 scenario.
  const created = await p.coachA.client.rpc('create_workout_template', {
    p_name: 'Upper Body Calisthenics Strength',
    p_description: 'Slice 1 hosted probe',
    p_visibility: 'organization',
    p_blocks: [
      {
        title: 'Primary Strength',
        block_type: 'superset',
        items: [
          {
            exercise_id: ids['pull-up'],
            measurement_mode: 'added_weight',
            sets: [
              { target_reps: 5, target_load_kg: 10, load_type: 'added', target_rest_seconds: 120, target_rpe: 7.5 },
              { target_reps: 3, target_load_kg: 15, load_type: 'added', target_rest_seconds: 120, target_rpe: 8.5 },
              { target_reps: 1, target_load_kg: 20, load_type: 'added', target_rest_seconds: 180, target_rpe: 9.5 },
            ],
          },
          {
            exercise_id: ids['parallel-bar-dip'],
            measurement_mode: 'added_weight',
            sets: [
              { target_reps: 5, target_load_kg: 15, load_type: 'added', target_rest_seconds: 120 },
              { target_reps: 5, target_load_kg: 15, load_type: 'added', target_rest_seconds: 120 },
              { target_reps: 8, target_load_kg: 10, load_type: 'added', target_rest_seconds: 120, notes: 'back-off set' },
            ],
          },
        ],
      },
      {
        title: 'Core Finisher',
        block_type: 'amrap',
        amrap_duration_seconds: 420,
        items: [{ exercise_id: ids['hanging-leg-raise'], measurement_mode: 'reps', sets: [{ target_reps: 10 }] }],
      },
    ],
  });
  check(!created.error, 'Coach creates the Slice 1 organization template through the RPC', created.error);
  const templateId = created.data?.template_id;
  const versionId = created.data?.version_id;

  const tpl = await p.coachA.client.from('workout_templates').select('*').eq('id', templateId).single();
  check(tpl.data?.visibility === 'organization', 'workout_templates: 1 row, visibility organization', tpl);
  const ver = await p.coachA.client.from('workout_versions').select('*').eq('template_id', templateId);
  check(ver.data?.length === 1 && ver.data[0].is_sealed && ver.data[0].version_number === 1, 'workout_versions: 1 sealed row, version 1', ver.data);
  const blocks = await p.coachA.client.from('workout_blocks').select('*').eq('workout_version_id', versionId);
  check(blocks.data?.length === 2, 'workout_blocks: 2 rows', blocks.data?.length);
  const blockIds = (blocks.data ?? []).map((b) => b.id);
  const items = await p.coachA.client.from('workout_items').select('*').in('block_id', blockIds);
  check(items.data?.length === 3, 'workout_items: 3 rows', items.data?.length);
  const itemIds = (items.data ?? []).map((i) => i.id);
  const sets = await p.coachA.client.from('workout_item_sets').select('*').in('workout_item_id', itemIds);
  check(sets.data?.length === 7, 'workout_item_sets: 7 rows', sets.data?.length);

  // Direct authenticated client mutation on every hierarchy table -> 42501.
  const dmlAttempts = [
    () => p.coachA.client.from('workout_templates').insert({ organization_id: tpl.data.organization_id, name: 'x', created_by: p.coachA.id }),
    () => p.coachA.client.from('workout_versions').update({ notes: 'x' }).eq('id', versionId),
    () => p.coachA.client.from('workout_blocks').delete().eq('id', blockIds[0]),
    () => p.coachA.client.from('workout_items').update({ notes: 'x' }).eq('id', itemIds[0]),
    () => p.coachA.client.from('workout_item_sets').insert({ workout_item_id: itemIds[0], set_number: 9, target_reps: 1 }),
  ];
  for (const [i, attempt] of dmlAttempts.entries()) {
    const res = await attempt();
    check(res.error?.code === '42501', `direct authenticated DML #${i + 1} on a hierarchy table fails with 42501`, res.error);
  }

  // Payload validation: mode mismatch is rejected server-side.
  const badMode = await p.coachA.client.rpc('create_workout_template', {
    p_name: 'Bad mode probe',
    p_description: null,
    p_visibility: 'private',
    p_blocks: oneSet(ids['push-up'], 'holds', { target_duration_seconds: 30 }),
  });
  check(badMode.error?.code === '22023', 'an unsupported measurement mode for the exercise is rejected (22023)', badMode.error);

  console.log(`\n# Slice 1 ids: template=${templateId} version=${versionId}`);
  finish();
}

// ---------------------------------------------------------------------------------
async function slice2() {
  const state = loadState();
  const p = await people(state);

  const ex = await p.athleteA.client.from('exercises').select('id, slug').eq('is_official', true).eq('status', 'approved').limit(3);
  const officialId = ex.data?.[0]?.id;

  // Step 1: athlete creates a private routine with a private custom exercise (V1 unsafe).
  const customEx = await p.athleteA.client
    .from('exercises')
    .insert({
      name: `Slice2 Private Move ${state.runId}`,
      category: 'core',
      measurement_types: ['reps'],
      equipment_needed: ['none'],
      created_by: p.athleteA.id,
    })
    .select()
    .single();
  check(!customEx.error, 'athlete creates a private custom exercise', customEx.error);

  const hist = await p.athleteA.client.rpc('create_workout_template', {
    p_name: `Slice2 History ${state.runId}`,
    p_description: null,
    p_visibility: 'private',
    p_blocks: oneSet(customEx.data.id, 'reps', { target_reps: 12 }),
  });
  check(!hist.error, 'step 1: athlete creates a private routine using the private exercise (V1)', hist.error);
  const templateId = hist.data?.template_id;

  // Step 2: assigned coach sees 0 rows.
  const coachSeesNone = await p.coachA.client.from('workout_templates').select('id').eq('id', templateId);
  check(coachSeesNone.data?.length === 0, 'step 2: the assigned coach sees 0 rows (latest sealed version V1 is unsafe)', coachSeesNone);

  // Step 3: publish V2 with official exercises only.
  const v2 = await p.athleteA.client.rpc('publish_new_workout_version', {
    p_template_id: templateId,
    p_version_notes: 'now safe',
    p_blocks: oneSet(officialId, 'reps', { target_reps: 8 }),
  });
  check(!v2.error && v2.data?.version_number === 2, 'step 3: the athlete publishes version 2 with approved exercises', v2.error ?? v2.data);

  // Step 4: coach now sees the routine; V2 visible, V1 hidden.
  const coachSeesTpl = await p.coachA.client.from('workout_templates').select('id').eq('id', templateId);
  const coachVersions = await p.coachA.client.from('workout_versions').select('version_number').eq('template_id', templateId);
  check(coachSeesTpl.data?.length === 1, 'step 4: the coach now sees the routine', coachSeesTpl);
  check(
    (coachVersions.data ?? []).map((v) => v.version_number).sort().join(',') === '2',
    'step 4: only V2 is visible to the coach (V1 stays hidden)',
    coachVersions.data,
  );

  // Step 5: coach clones while V2 is latest.
  const clone = await p.coachA.client.rpc('clone_workout_template', { p_template_id: templateId, p_new_name: `Slice2 Clone ${state.runId}` });
  check(!clone.error, 'step 5: the coach clones the routine while V2 is the latest safe version', clone.error);
  const cloneVersion = await p.coachA.client.from('workout_versions').select('notes').eq('template_id', clone.data?.template_id).single();
  check(cloneVersion.data?.notes?.includes('version 2'), 'the clone copied version 2 (not the unsafe V1)', cloneVersion.data);

  // Step 6: athlete publishes V3, unsafe again.
  const v3 = await p.athleteA.client.rpc('publish_new_workout_version', {
    p_template_id: templateId,
    p_version_notes: 'oops',
    p_blocks: oneSet(customEx.data.id, 'reps', { target_reps: 15 }),
  });
  check(!v3.error && v3.data?.version_number === 3, 'step 6: the athlete publishes version 3 introducing an unapproved exercise', v3.error ?? v3.data);

  // Step 7: coach sees 0 rows again; cannot clone.
  const coachSeesNoneAgain = await p.coachA.client.from('workout_templates').select('id').eq('id', templateId);
  check(coachSeesNoneAgain.data?.length === 0, 'step 7: the coach sees 0 rows (V3 unsafe hides the whole template, even the safe V2)', coachSeesNoneAgain);
  const cloneRejected = await p.coachA.client.rpc('clone_workout_template', { p_template_id: templateId });
  check(cloneRejected.error?.code === '42501', 'step 7: the coach cannot clone the now-hidden routine (42501)', cloneRejected.error);

  // Step 8: creator sees everything.
  const creatorVersions = await p.athleteA.client.from('workout_versions').select('version_number').eq('template_id', templateId);
  check((creatorVersions.data ?? []).length === 3, 'step 8: the creator sees all three versions (creator shortcut)', creatorVersions.data);

  // Step 9: cross-organization probe.
  const coachBSees = await p.coachB.client.from('workout_templates').select('id').eq('id', templateId);
  const coachBClone = await p.coachB.client.rpc('clone_workout_template', { p_template_id: templateId });
  check(coachBSees.data?.length === 0, 'step 9: a Coach in Organization B sees 0 rows', coachBSees);
  check(coachBClone.error?.code === '42501', 'step 9: a Coach in Organization B is rejected with 42501 on clone', coachBClone.error);

  console.log(`\n# Slice 2 ids: template=${templateId} clone=${clone.data?.template_id}`);
  finish();
}

// ---------------------------------------------------------------------------------
async function concurrency() {
  const state = loadState();
  const p = await people(state);
  const ex = await p.coachA.client.from('exercises').select('id').eq('is_official', true).eq('status', 'approved').limit(1).single();

  const created = await p.coachA.client.rpc('create_workout_template', {
    p_name: `Concurrency Probe ${state.runId}`,
    p_description: null,
    p_visibility: 'private',
    p_blocks: oneSet(ex.data.id, 'reps', { target_reps: 5 }),
  });
  check(!created.error, 'seed template for the concurrency probes', created.error);
  const templateId = created.data.template_id;

  // Probe 1: two concurrent publishes on the same template -> sequential versions, no conflict.
  const [pub1, pub2] = await Promise.all([
    p.coachA.client.rpc('publish_new_workout_version', { p_template_id: templateId, p_version_notes: 'A', p_blocks: oneSet(ex.data.id, 'reps', { target_reps: 6 }) }),
    p.coachA.client.rpc('publish_new_workout_version', { p_template_id: templateId, p_version_notes: 'B', p_blocks: oneSet(ex.data.id, 'reps', { target_reps: 7 }) }),
  ]);
  const versions = [pub1.data?.version_number, pub2.data?.version_number].filter(Boolean).sort();
  check(!pub1.error && !pub2.error, 'both concurrent publishes succeed (parent row lock serializes them)', [pub1.error, pub2.error]);
  check(versions.join(',') === '2,3', 'the two publishes produced sequential versions 2 and 3, never a duplicate', versions);

  // Probe 2: publish racing clone. FOR SHARE (clone) vs FOR UPDATE (publish) serialize; both succeed either order.
  const [pub3, clone] = await Promise.all([
    p.coachA.client.rpc('publish_new_workout_version', { p_template_id: templateId, p_version_notes: 'C', p_blocks: oneSet(ex.data.id, 'reps', { target_reps: 8 }) }),
    p.coachA.client.rpc('clone_workout_template', { p_template_id: templateId, p_new_name: `Concurrency Clone ${state.runId}` }),
  ]);
  check(!pub3.error && !clone.error, 'a publish racing a clone: both complete without error (row lock ordering)', [pub3.error, clone.error]);
  const cloneVer = await p.coachA.client.from('workout_versions').select('notes').eq('template_id', clone.data?.template_id).single();
  check(
    /version \d+/.test(cloneVer.data?.notes ?? ''),
    'the clone recorded a complete, sealed source version (never a partial copy)',
    cloneVer.data,
  );
  const cloneBlocks = await p.coachA.client
    .from('workout_blocks')
    .select('id', { count: 'exact', head: true })
    .eq(
      'workout_version_id',
      (await p.coachA.client.from('workout_versions').select('id').eq('template_id', clone.data?.template_id).single()).data?.id,
    );
  check(cloneBlocks.count === 1, 'the clone has a complete hierarchy (1 block), never zero or a partial row set', cloneBlocks);

  finish();
}

const command = process.argv[2];
const commands = { setup, slice1, slice2, concurrency };
if (!commands[command]) {
  console.error('Usage: sprint3-slices.mjs setup|slice1|slice2|concurrency');
  process.exit(2);
}
await commands[command]();
