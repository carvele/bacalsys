#!/usr/bin/env node
/**
 * Minimal static server for smoke-testing the production web export (dist/)
 * with the same single-page-app fallback as the hosting config
 * (public/_redirects, vercel.json): unknown paths serve index.html.
 *
 * Usage: node scripts/web/serve.mjs [port] [basePath]
 *   e.g. `node scripts/web/serve.mjs 4174 /bacalsys` to mimic GitHub Pages.
 */
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve } from 'node:path';

const root = resolve('dist');
const port = Number(process.argv[2] ?? 4173);
const base = (process.argv[3] ?? '').replace(/\/$/, '');
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
};

createServer((req, res) => {
  let urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (base) {
    if (!urlPath.startsWith(base)) {
      res.writeHead(404).end('Not under base path');
      return;
    }
    urlPath = urlPath.slice(base.length) || '/';
  }
  const candidate = normalize(join(root, urlPath));
  // Never serve outside dist/.
  const file =
    candidate.startsWith(root) && existsSync(candidate) && statSync(candidate).isFile()
      ? candidate
      : join(root, 'index.html');
  res.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream' });
  createReadStream(file).pipe(res);
}).listen(port, () => console.log(`Serving dist/ on http://localhost:${port}${base}/`));
