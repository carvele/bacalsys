#!/usr/bin/env node
/**
 * Post-build guard for the web export (dist/). Fails the build if the bundle
 * contains anything that must never ship to browsers, or points at the wrong
 * backend.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const dist = 'dist';
const expectedUrl = process.env.EXPO_PUBLIC_SUPABASE_URL;
const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (/\.(js|html|json|css)$/.test(name)) files.push(p);
  }
})(dist);

const all = files.map((f) => readFileSync(f, 'utf8')).join('\n');
const problems = [];

// Real secret keys (not library code that merely mentions the prefix).
if (/sb_secret_[A-Za-z0-9_-]{10,}/.test(all)) problems.push('Supabase secret key (sb_secret_…) found');
for (const jwt of all.match(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g) ?? []) {
  try {
    const payload = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString());
    if (payload.role && payload.role !== 'anon') problems.push(`JWT with role "${payload.role}" found`);
  } catch {
    /* not a JWT */
  }
}
if (/E2E_PRESIDENT_PASSWORD|BaCalSys-Local-President-1/.test(all)) problems.push('test credential found');
if (!expectedUrl || !all.includes(expectedUrl)) problems.push(`expected backend URL ${expectedUrl} not found`);
if (/127\.0\.0\.1:54321|localhost:54321/.test(all)) problems.push('local Supabase URL found in production bundle');

if (problems.length) {
  console.error(`✗ web bundle check failed:\n  - ${problems.join('\n  - ')}`);
  process.exit(1);
}
console.log(`✓ web bundle check passed (${files.length} files, backend ${expectedUrl})`);
