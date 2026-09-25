#!/usr/bin/env node
// PreToolUse (Write|Edit|MultiEdit): block edits that break BaCalSys invariants.
const { execFileSync } = require('node:child_process');
const path = require('node:path');

let raw = '';
process.stdin.on('data', (c) => (raw += c));
process.stdin.on('end', () => {
  const input = JSON.parse(raw || '{}');
  const ti = input.tool_input || {};
  if (!ti.file_path) return;

  const root = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
  const rel = path.relative(root, path.resolve(root, ti.file_path)).split(path.sep).join('/');
  const content = [ti.content, ti.new_string, ...(ti.edits || []).map((e) => e.new_string)]
    .filter(Boolean)
    .join('\n');

  const deny = (reason) => {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: reason,
        },
      }),
    );
  };

  if (/^(ios|android)\//.test(rel)) {
    return deny(
      `${rel} is a generated native directory (Continuous Native Generation). Configure native behavior in app.json or a config plugin instead.`,
    );
  }

  if (/^supabase\/migrations\/.+\.sql$/.test(rel) && isCommitted(root, rel)) {
    return deny(
      `${rel} is a committed migration. Never rewrite migration history: add a new migration file that alters the schema forward.`,
    );
  }

  const isClientCode = !rel.startsWith('supabase/') && !rel.startsWith('.claude/') && !rel.startsWith('docs/');
  if (isClientCode && /service_role|SERVICE_ROLE|sb_secret_/.test(content)) {
    return deny(
      `This edit puts a Supabase service-role/secret reference into client code (${rel}). Elevated credentials never ship in the app; use a public RPC wrapper or an Edge Function instead.`,
    );
  }
});

function isCommitted(root, rel) {
  try {
    execFileSync('git', ['cat-file', '-e', `HEAD:${rel}`], { cwd: root, stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}
