#!/usr/bin/env node
/**
 * Offline database verification harness (no Docker required).
 *
 * Builds a brand-new PostgreSQL (PGlite) instance, applies the Supabase
 * platform shim, every migration in supabase/migrations (in order) and
 * supabase/seed.sql — i.e. recreates the whole database from scratch — then
 * runs every supabase/tests/*.test.sql pgTAP file and reports TAP results.
 *
 * The canonical runner remains `supabase test db` against the local Supabase
 * stack; this harness exists so migrations and RLS boundaries are verified on
 * machines and CI jobs without Docker.
 *
 * Usage: node scripts/db/verify.mjs [--filter <substring>]
 */
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

import { buildDatabase, read, root } from './build-db.mjs';

const filterArg = process.argv.indexOf('--filter');
const filter = filterArg > -1 ? process.argv[filterArg + 1] : null;

console.log('# Building database from scratch');
let db;
try {
  db = await buildDatabase({
    onStep: (label, err, sql) => {
      if (!err) return console.log(`  ✓ ${label}`);
      console.error(`  ✗ ${label}\n    ${err.message}`);
      if (err.position) {
        const pos = Number(err.position);
        console.error(`    near: …${sql.slice(Math.max(0, pos - 120), pos + 60).replace(/\s+/g, ' ')}…`);
      }
    },
  });
} catch {
  process.exit(1);
}
console.log(`# ${(await db.query('select version() as v')).rows[0].v.split(' on ')[0]}`);

// Match the search_path the Supabase test runner uses.
await db.exec(`SET search_path = "$user", public, extensions;`);

const tests = readdirSync(join(root, 'supabase/tests'))
  .filter((f) => f.endsWith('.test.sql') && (!filter || f.includes(filter)))
  .sort();

let totalPass = 0;
let totalFail = 0;
const failedFiles = [];

for (const file of tests) {
  // Real pgTAP is not available in PGlite; the shim is preinstalled instead.
  const sql = read('supabase/tests', file).replace(
    /^\s*create\s+extension\s+if\s+not\s+exists\s+pgtap[^;]*;/gim,
    '-- (pgtap provided by harness shim)',
  );

  console.log(`\n# ${file}`);
  let lines = [];
  try {
    const results = await db.exec(sql);
    for (const r of results) {
      for (const row of r.rows) {
        const v = Object.values(row)[0];
        // Keep TAP output only; ignore values returned by helper SELECTs (set_config etc.).
        if (typeof v === 'string') lines.push(...v.split('\n').filter((l) => /^(ok |not ok|1\.\.|#)/.test(l)));
      }
    }
  } catch (err) {
    lines.push(`not ok - test file aborted: ${err.message}`);
    await db.exec('ROLLBACK;').catch(() => {});
    await db.exec('RESET ROLE;').catch(() => {});
  }

  let planned = null;
  let pass = 0;
  let fail = 0;
  for (const line of lines) {
    const m = /^1\.\.(\d+)$/.exec(line);
    if (m) planned = Number(m[1]);
    if (line.startsWith('ok ')) pass++;
    if (line.startsWith('not ok')) fail++;
    console.log(line.startsWith('not ok') || line.startsWith('# Looks') ? `  !! ${line}` : `  ${line}`);
  }
  if (planned !== null && pass + fail !== planned) {
    fail++;
    console.log(`  !! planned ${planned} tests but ran ${pass + fail - 1}`);
  }
  totalPass += pass;
  totalFail += fail;
  if (fail > 0) failedFiles.push(file);
}

console.log(`\n# ${tests.length} file(s), ${totalPass} passed, ${totalFail} failed`);
if (totalFail > 0) {
  console.log(`# FAILED: ${failedFiles.join(', ')}`);
  process.exit(1);
}
console.log('# ALL TESTS PASSED');
