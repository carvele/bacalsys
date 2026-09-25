#!/usr/bin/env node
// PostToolUse (Write|Edit|MultiEdit): typecheck the project and report errors in the edited file only,
// so pre-existing errors elsewhere don't drown out the ones this edit introduced.
const { spawnSync } = require('node:child_process');
const path = require('node:path');

let raw = '';
process.stdin.on('data', (c) => (raw += c));
process.stdin.on('end', () => {
  const input = JSON.parse(raw || '{}');
  const filePath = (input.tool_input || {}).file_path;
  if (!filePath || !/\.(ts|tsx)$/.test(filePath)) return;

  const root = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
  const rel = path.relative(root, path.resolve(root, filePath)).split(path.sep).join('/');
  if (rel.startsWith('..') || rel.startsWith('node_modules/')) return;

  const tsc = path.join(root, 'node_modules', 'typescript', 'bin', 'tsc');
  const res = spawnSync(process.execPath, [tsc, '--noEmit', '-p', root, '--pretty', 'false'], {
    cwd: root,
    encoding: 'utf8',
  });
  if (res.status === 0) return;

  const errors = (res.stdout || '')
    .split(/\r?\n/)
    .filter((line) => line.replace(/\\/g, '/').startsWith(`${rel}(`));
  if (errors.length === 0) return;

  process.stderr.write(
    `TypeScript errors in ${rel} after this edit (npx tsc --noEmit):\n${errors.slice(0, 30).join('\n')}\n`,
  );
  process.exit(2);
});
