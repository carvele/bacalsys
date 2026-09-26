#!/usr/bin/env node
/**
 * Sprint 2 · Task 2.0 — guarded dev/test fixture cleanup.
 *
 *   node scripts/test/cleanup-fixtures.mjs --target <supabase-url> [--min-age-minutes N]
 *        [--max-accounts N] [--no-legacy] [--out <file.sql>]
 *
 * Checks the environment first (see assertSafeTarget): local stacks always pass; a
 * hosted project only with FIXTURE_CLEANUP_ALLOWED_URL set to exactly that URL and
 * its ref absent from FIXTURE_CLEANUP_PROTECTED_REFS. It then emits one guarded,
 * transactional SQL batch that removes ONLY tagged test fixtures (fixtures.mjs).
 *
 * The repository deliberately stores no database password or service-role key, so
 * the script does not connect by itself. The operator runs the emitted SQL through
 * the project's SQL editor / SQL API (hosted) or `psql` (local). The SQL re-checks
 * everything it deletes, so a stale or mis-targeted file still fails closed.
 */
import { writeFileSync } from 'node:fs';

import { assertSafeTarget, buildCleanupSql, UnsafeTargetError } from './fixture-cleanup-lib.mjs';

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i > -1 ? args[i + 1] : undefined;
};

const target = opt('--target') ?? process.env.EXPO_PUBLIC_SUPABASE_URL;
if (!target) {
  console.error('Usage: cleanup-fixtures.mjs --target <supabase-url> [--min-age-minutes N] [--out file.sql]');
  process.exit(2);
}

try {
  const verdict = assertSafeTarget(target, process.env);
  const sql = buildCleanupSql({
    minAgeMinutes: Number(opt('--min-age-minutes') ?? 0),
    maxAccounts: Number(opt('--max-accounts') ?? 200),
    includeLegacy: !args.includes('--no-legacy'),
  });
  const out = opt('--out');
  if (out) {
    writeFileSync(out, sql);
    console.error(`Target ${verdict.kind === 'local' ? verdict.host : verdict.ref} passed the environment check.`);
    console.error(`Guarded cleanup SQL written to ${out}. Review it, then run it against that target only.`);
  } else {
    process.stdout.write(sql);
  }
} catch (err) {
  if (err instanceof UnsafeTargetError) {
    console.error(`Refusing: ${err.message}`);
    process.exit(2);
  }
  throw err;
}
