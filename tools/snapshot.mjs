#!/usr/bin/env node
// Render still previews of every scene with headless Chromium.
//
//   npx playwright install chromium   # once, if you don't have it
//   node tools/snapshot.mjs [outDir] [extra query string]
//
// Serves ./Renderer on a local port and writes one PNG per scene/framing.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = process.env.RENDERER_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../Renderer');
const outDir = path.resolve(process.argv[2] || 'snapshots');
const extra = process.argv[3] || '';
fs.mkdirSync(outDir, { recursive: true });

const types = { '.html': 'text/html', '.js': 'text/javascript', '.jpg': 'image/jpeg', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const port = server.address().port;

const shots = (process.env.SHOTS || '')
  .split(',')
  .filter(Boolean)
  .map((s) => s.split(':'));
const defaults = [
  ['listening-room', 'wide', 1440, 900],
  ['after-hours', 'wide', 1440, 900],
  ['turntable', 'wide', 1440, 900],
  ['mini', 'wide', 420, 420],
];
const list = shots.length ? shots.map(([s, f, w, h]) => [s, f || 'wide', Number(w) || 1440, Number(h) || 900]) : defaults;

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
});
for (const [scene, framing, width, height] of list) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  page.on('console', (m) => m.type() !== 'debug' && console.log(`[${scene}] ${m.text()}`));
  page.on('pageerror', (e) => console.error(`[${scene}] ${e.message}`));
  const url = `http://localhost:${port}/index.html?snapshot&demo&scene=${scene}&framing=${framing}&${extra}`;
  await page.goto(url);
  await page.waitForFunction(() => window.__vinylReady === true, null, { timeout: 120000 });
  const file = path.join(outDir, `${scene}-${framing}.png`);
  await page.screenshot({ path: file, omitBackground: true });
  console.log(`wrote ${file}`);
  await page.close();
}
await browser.close();
server.close();
