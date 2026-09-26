/**
 * Builds a brand-new offline PostgreSQL (PGlite) database the same way
 * `supabase db reset` does: platform shim, pgTAP shim, every migration in
 * supabase/migrations (in order, one transaction each) and supabase/seed.sql.
 * Shared by scripts/db/verify.mjs and the node:test suites under scripts/.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';

export const root = resolve(fileURLToPath(import.meta.url), '../../..');
export const read = (...p) => readFileSync(join(root, ...p), 'utf8');

export function migrationFiles() {
  return readdirSync(join(root, 'supabase/migrations'))
    .filter((f) => f.endsWith('.sql'))
    .sort();
}

/**
 * @param {{ onStep?: (label: string, err?: Error, sql?: string) => void }} [options]
 * @returns {Promise<PGlite>}
 */
export async function buildDatabase({ onStep } = {}) {
  const db = new PGlite({ extensions: { pgcrypto } });
  const step = async (label, sql) => {
    try {
      await db.exec(sql);
      onStep?.(label);
    } catch (err) {
      onStep?.(label, err, sql);
      throw err;
    }
  };
  await step('supabase platform shim', read('scripts/db/supabase-shim.sql'));
  await step('pgTAP shim', read('scripts/db/pgtap-shim.sql'));
  for (const file of migrationFiles()) {
    // Supabase applies each migration file in its own transaction.
    await step(`migration ${file}`, `BEGIN;\n${read('supabase/migrations', file)}\nCOMMIT;`);
  }
  await step('seed.sql', read('supabase/seed.sql'));
  return db;
}
