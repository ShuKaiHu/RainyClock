// Headless Chrome, run the way that works on this Mac.
//
// Headless Chrome here often finishes its job (screenshot written, DOM dumped) and then never
// exits. So stdout/stderr go to files (a pipe would also be held open by helper processes),
// the job's own completion signal is polled, the browser gets a short grace period to quit on
// its own, and then its whole process group is killed. A run that has not finished after 60 s
// is killed and reported. Runs are strictly sequential: callers await each one.

import { readFileSync, existsSync, statSync, rmSync, openSync, closeSync, mkdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } };

function runChrome(args, label, { outPath, errPath, done, timeoutMs = 60_000, graceMs = 2000 }) {
  return new Promise((resolvePromise, reject) => {
    const out = openSync(outPath, 'w');
    const err = openSync(errPath, 'w');
    const child = spawn(CHROME, args, { stdio: ['ignore', out, err], detached: true });
    const started = Date.now();
    let doneAt = 0, settled = false;
    const isDone = () => { try { return done(); } catch { return false; } };
    const killGroup = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch {} } };
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearInterval(poll);
      closeSync(out); closeSync(err);
      if (error) reject(error); else resolvePromise(read(outPath));
    };
    const poll = setInterval(() => {
      if (!doneAt && isDone()) doneAt = Date.now();
      if (doneAt && Date.now() - doneAt > graceMs) { killGroup(); finish(); }
      else if (!doneAt && Date.now() - started > timeoutMs) { killGroup(); finish(new Error(`${label}: Chrome hung for ${timeoutMs / 1000} s and was killed`)); }
    }, 150);
    child.on('error', (e) => finish(e));
    child.on('exit', () => setTimeout(() => {
      if (!settled) finish(isDone() ? undefined : new Error(`${label}: Chrome exited without finishing`));
    }, 100));
  });
}

function baseArgs(profileDir, w, h) {
  mkdirSync(profileDir, { recursive: true });
  return [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--force-color-profile=srgb', `--user-data-dir=${profileDir}`, `--window-size=${w},${h}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync',
    '--disable-background-networking', '--disable-component-update', '--mute-audio',
    // Lets web fonts finish loading (and a measuring page's promise resolve) before Chrome
    // dumps the DOM or takes the screenshot.
    '--virtual-time-budget=8000',
  ];
}

// Screenshot htmlPath at w x h into pngPath. Resolves when the file is written.
export async function screenshot(htmlPath, pngPath, { profileDir, w, h }) {
  const log = pngPath + '.log';
  if (existsSync(pngPath)) rmSync(pngPath);
  try {
    await runChrome([...baseArgs(profileDir, w, h), `--screenshot=${pngPath}`, pathToFileURL(htmlPath).href], 'screenshot', {
      outPath: log, errPath: log + '.err',
      done: () => /bytes written to file/.test(read(log) + read(log + '.err')),
    });
  } finally {
    rmSync(log, { force: true }); rmSync(log + '.err', { force: true });
  }
  if (!existsSync(pngPath) || statSync(pngPath).size === 0) throw new Error(`Chrome wrote no screenshot for ${htmlPath}`);
}

// Load htmlPath, let its scripts run, and return the serialised DOM.
export async function dumpDom(htmlPath, { profileDir, w, h }) {
  const dump = htmlPath + '.dom';
  try {
    return await runChrome([...baseArgs(profileDir, w, h), '--dump-dom', pathToFileURL(htmlPath).href], 'dump-dom', {
      outPath: dump, errPath: dump + '.err', graceMs: 500,
      done: () => /<\/html>\s*$/.test(read(dump)),
    });
  } finally {
    rmSync(dump, { force: true }); rmSync(dump + '.err', { force: true });
  }
}

// The JSON a measuring page leaves in <script type="application/json" id="result">.
export function readResult(dom) {
  const m = /<script type="application\/json" id="result">([\s\S]*?)<\/script>/.exec(dom);
  if (!m) throw new Error('measuring page left no result (did its script throw?)');
  return JSON.parse(m[1]);
}
