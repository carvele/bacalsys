#!/usr/bin/env node
/**
 * Production web build: exports with the public config in .env.production,
 * then verifies the bundle (scripts/web/check-bundle.mjs).
 *
 *   node scripts/web/build.mjs           → dist/ for root-path hosts (Vercel/Netlify)
 *   node scripts/web/build.mjs --pages   → dist/ for GitHub Pages at /bacalsys
 *
 * Variables already in the process environment win over .env files, so CI
 * can override them without editing files.
 */
import { spawnSync } from 'node:child_process';

const pages = process.argv.includes('--pages');

process.loadEnvFile('.env.production');
if (pages) process.env.EXPO_BASE_URL ??= '/bacalsys';

function run(args) {
  const result = spawnSync(process.execPath, args, { stdio: 'inherit', env: process.env });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

run(['node_modules/expo/bin/cli', 'export', '--platform', 'web', '--clear']);
run(['scripts/web/check-bundle.mjs']);
if (pages) run(['scripts/web/prepare-pages.mjs']);
