// Task 2.0 regression suite: node --test scripts/test/__tests__
import assert from 'node:assert/strict';
import { before, describe, test } from 'node:test';

import { buildDatabase } from '../../db/build-db.mjs';
import { assertSafeTarget, buildCleanupSql, UnsafeTargetError } from '../fixture-cleanup-lib.mjs';

const DEV = 'https://abcdefghijklmnopqrst.supabase.co';

describe('assertSafeTarget (environment check)', () => {
  test('allows local stacks', () => {
    for (const url of ['http://127.0.0.1:54321', 'http://localhost:54321', 'http://10.0.2.2:54321', 'http://app.localhost']) {
      assert.equal(assertSafeTarget(url, {}).kind, 'local', url);
    }
  });

  test('refuses a remote project without explicit opt-in', () => {
    assert.throws(() => assertSafeTarget(DEV, {}), UnsafeTargetError);
    assert.throws(
      () => assertSafeTarget(DEV, { FIXTURE_CLEANUP_ALLOWED_URL: 'https://zzzzzzzzzzzzzzzzzzzz.supabase.co' }),
      UnsafeTargetError,
    );
  });

  test('allows a remote project opted in by exact URL', () => {
    assert.deepEqual(assertSafeTarget(`${DEV}/`, { FIXTURE_CLEANUP_ALLOWED_URL: DEV }), {
      kind: 'remote',
      ref: 'abcdefghijklmnopqrst',
    });
  });

  test('protected refs win over opt-in', () => {
    assert.throws(
      () =>
        assertSafeTarget(DEV, {
          FIXTURE_CLEANUP_ALLOWED_URL: DEV,
          FIXTURE_CLEANUP_PROTECTED_REFS: 'prod1, abcdefghijklmnopqrst',
        }),
      /PROTECTED_REFS/,
    );
  });

  test('refuses NODE_ENV=production, non-Supabase hosts and garbage', () => {
    assert.throws(() => assertSafeTarget('http://127.0.0.1:54321', { NODE_ENV: 'production' }), UnsafeTargetError);
    assert.throws(() => assertSafeTarget('https://db.example.com', { FIXTURE_CLEANUP_ALLOWED_URL: 'https://db.example.com' }), UnsafeTargetError);
    assert.throws(() => assertSafeTarget('not a url', {}), UnsafeTargetError);
  });
});

describe('buildCleanupSql (data guard) against a freshly migrated database', () => {
  let db;
  const PRESIDENT = '00000000-0000-4000-8000-00000000a001'; // local seed
  const ids = {
    athlete: 'f0000000-0000-4000-8000-000000000001', // fixture, coached by fixture coach → removed
    coach: 'f0000000-0000-4000-8000-000000000002', // fixture coach → removed
    coachOfReal: 'f0000000-0000-4000-8000-000000000003', // fixture coaching a real member → kept
    realMember: 'f0000000-0000-4000-8000-000000000004', // real e-mail, no tag → kept
    tagOnly: 'f0000000-0000-4000-8000-000000000005', // tag but a real domain → kept
    domainOnly: 'f0000000-0000-4000-8000-000000000006', // fixture domain, no tag → kept
    legacy: 'f0000000-0000-4000-8000-000000000007', // Sprint 1 E2E pattern → removed
    recent: 'f0000000-0000-4000-8000-000000000008', // fixture, too young for min age → kept
  };
  const tag = (name) => JSON.stringify({ full_name: name, bacalsys_test_fixture: 'true' });

  before(async () => {
    db = await buildDatabase();
    await db.exec(`
      INSERT INTO auth.users (id, email, raw_user_meta_data, created_at) VALUES
        ('${ids.athlete}', 'athlete.1@e2e.bacalsys.local', '${tag('Fixture Athlete')}', now() - interval '2 hours'),
        ('${ids.coach}', 'coach.1@e2e.bacalsys.local', '${tag('Fixture Coach')}', now() - interval '2 hours'),
        ('${ids.coachOfReal}', 'coach.2@e2e.bacalsys.local', '${tag('Fixture Coach 2')}', now() - interval '2 hours'),
        ('${ids.realMember}', 'real@example.com', '{"full_name":"Real"}', now() - interval '2 hours'),
        ('${ids.tagOnly}', 'someone@example.com', '${tag('Tag only')}', now() - interval '2 hours'),
        ('${ids.domainOnly}', 'untagged@e2e.bacalsys.local', '{"full_name":"No tag"}', now() - interval '2 hours'),
        ('${ids.legacy}', 'juan.1758000000000@bacalsys.local', '{"full_name":"Juan"}', now() - interval '2 hours'),
        ('${ids.recent}', 'athlete.2@e2e.bacalsys.local', '${tag('Recent')}', now());
      UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'f0000000-%';
      INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by)
      VALUES ('${ids.athlete}', '${ids.coach}', '${PRESIDENT}'),
             ('${ids.realMember}', '${ids.coachOfReal}', '${PRESIDENT}');
      INSERT INTO public.exercises (name, category, measurement_types, equipment_needed, created_by)
      VALUES ('Fixture Ring Dips', 'push', '{reps}', '{rings}', '${ids.athlete}'),
             ('Real Member Drill', 'core', '{reps}', '{none}', '${ids.realMember}');
    `);
  });

  test('removes only tagged fixtures that nothing real depends on', async () => {
    const results = await db.exec(buildCleanupSql({ minAgeMinutes: 30 }));
    const report = results.find((r) => r.fields.some((f) => f.name === 'accounts'))?.rows[0];
    assert.deepEqual(
      { accounts: Number(report.accounts), coach_assignments: Number(report.coach_assignments), exercises: Number(report.exercises) },
      { accounts: 3, coach_assignments: 1, exercises: 1 },
    );

    const remaining = (await db.query(`SELECT id FROM auth.users WHERE id::text LIKE 'f0000000-%' ORDER BY id`)).rows.map((r) => r.id);
    assert.deepEqual(remaining, [ids.coachOfReal, ids.realMember, ids.tagOnly, ids.domainOnly, ids.recent].sort());

    const realHistory = await db.query(`SELECT 1 FROM public.coach_assignments WHERE athlete_id = '${ids.realMember}'`);
    assert.equal(realHistory.rows.length, 1, "a real member's coaching history is never deleted");
    const realExercise = await db.query(`SELECT 1 FROM public.exercises WHERE created_by = '${ids.realMember}'`);
    assert.equal(realExercise.rows.length, 1);
    const seededPresident = await db.query(`SELECT 1 FROM auth.users WHERE id = '${PRESIDENT}'`);
    assert.equal(seededPresident.rows.length, 1);
  });

  test('every removal is audited', async () => {
    const { rows } = await db.query(
      `SELECT action, actor_type FROM public.audit_logs
       WHERE entity_id IN ('${ids.athlete}', '${ids.coach}', '${ids.legacy}') AND action = 'profiles.delete'`,
    );
    assert.equal(rows.length, 3);
    assert.ok(rows.every((r) => r.actor_type === 'system'));
  });

  test('aborts, deleting nothing, if a tagged candidate holds an executive position', async () => {
    await db.exec(`
      INSERT INTO auth.users (id, email, raw_user_meta_data, created_at)
      VALUES ('f0000000-0000-4000-8000-0000000000e1', 'vp.1@e2e.bacalsys.local', '${tag('Tagged VP')}', now() - interval '2 hours');
      INSERT INTO public.member_positions (profile_id, position_id)
      SELECT 'f0000000-0000-4000-8000-0000000000e1', id FROM public.positions WHERE name = 'Vice President';
    `);
    await assert.rejects(db.exec(buildCleanupSql({ minAgeMinutes: 0 })), /executive position/);
    await db.exec('ROLLBACK').catch(() => {});
    const { rows } = await db.query(`SELECT count(*)::int AS n FROM auth.users WHERE id::text LIKE 'f0000000-%'`);
    assert.equal(rows[0].n, 6, 'the aborted batch removed nothing');
  });

  test('rejects invalid options', () => {
    assert.throws(() => buildCleanupSql({ minAgeMinutes: -1 }));
    assert.throws(() => buildCleanupSql({ maxAccounts: 0 }));
  });
});
