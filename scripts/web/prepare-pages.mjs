#!/usr/bin/env node
/**
 * Post-export tweaks for GitHub Pages:
 *  - .nojekyll: Pages' Jekyll step drops folders starting with "_", which would
 *    remove dist/_expo (the whole app bundle).
 *  - 404.html: Pages serves it for unknown paths, giving the single-page app
 *    a fallback so deep links like /bacalsys/register survive a refresh.
 */
import { copyFileSync, writeFileSync } from 'node:fs';

writeFileSync('dist/.nojekyll', '');
copyFileSync('dist/index.html', 'dist/404.html');
console.log('✓ GitHub Pages files written (.nojekyll, 404.html)');
