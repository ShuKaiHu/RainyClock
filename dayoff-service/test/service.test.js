import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { SuspensionService } from '../src/service.js';
import { cap, atom, CAP_URL, NOW, xmlResponse, temporaryDirectory } from './helpers.js';

test('one shared source check serves all clients and preserves old source dates', async (t) => {
  const dataDir = await temporaryDirectory(t);
  const calls = [], revisions = [];
  const service = new SuspensionService({ apiKey: 'private-key', dataDir, now: () => NOW, onRevision: async (revision) => revisions.push(revision), fetchImpl: async (url, options) => {
    calls.push({ url, options });
    return xmlResponse(url === CAP_URL ? cap : atom());
  } });
  const first = service.refresh();
  assert.equal(service.refresh(), first);
  assert.equal(await first, true);
  const snapshot = service.getSnapshot();
  assert.equal(snapshot.checkedAt, '2026-09-15T12:30:00.000Z');
  assert.equal(snapshot.sourceUpdatedAt, '2026-08-24T10:29:00.000Z');
  assert.match(snapshot.notices[0].description, /今天下午/);
  for (let i = 0; i < 20; i += 1) assert.equal(service.getSnapshot(), snapshot);
  assert.equal(calls.length, 2);
  assert.equal(new URL(calls[0].url).pathname, '/webapi/RssAtomFeed.ashx');
  assert.equal(new URL(calls[0].url).searchParams.get('apikey'), 'private-key');
  assert.equal(calls[0].options.redirect, 'error');
  assert.equal(calls[1].url.includes('private-key'), false);
  await new Promise(setImmediate);
  assert.equal(revisions.length, 1);
  assert.equal((await readFile(join(dataDir, 'suspensions.json'), 'utf8')).includes('private-key'), false);
});

test('new checkedAt does not produce pushes when notices are unchanged; CAP is cached', async (t) => {
  const dataDir = await temporaryDirectory(t);
  let time = NOW, calls = 0, pushes = 0;
  const service = new SuspensionService({ apiKey: 'key', dataDir, now: () => time, onRevision: async () => { pushes += 1; }, fetchImpl: async (url) => { calls += 1; return xmlResponse(url === CAP_URL ? cap : atom()); } });
  await service.refresh();
  await new Promise(setImmediate);
  const oldRevision = service.getSnapshot().revision;
  time += 300_001;
  await service.refresh();
  await new Promise(setImmediate);
  assert.equal(service.getSnapshot().revision, oldRevision);
  assert.equal(pushes, 1);
  assert.equal(calls, 3);
});

test('successful empty feed is distinct from HTTP or HTML failure', async (t) => {
  const dataDir = await temporaryDirectory(t);
  let time = NOW, failed = false;
  const service = new SuspensionService({ apiKey: 'key', dataDir, now: () => time, fetchImpl: async () => failed ? new Response('<html>denied</html>', { headers: { 'Content-Type': 'text/html' } }) : xmlResponse(atom([])) });
  assert.equal(await service.refresh(), true);
  assert.deepEqual(service.getSnapshot().notices, []);
  failed = true;
  time += 300_001;
  assert.equal(await service.refresh(), false);
  assert.equal(service.health().errorCode, 'invalid_source_content_type');
  assert.throws(() => service.getSnapshot(), /invalid_source_content_type/);
});

test('429 respects Retry-After; no calls during backoff; errors cannot leak key', async (t) => {
  const dataDir = await temporaryDirectory(t);
  let time = NOW, calls = 0;
  const logs = [];
  const service = new SuspensionService({ apiKey: 'super-secret-value', dataDir, now: () => time, log: (event) => logs.push(event), fetchImpl: async () => { calls += 1; return new Response('No', { status: 429, headers: { 'Retry-After': '120' } }); } });
  await service.refresh();
  assert.equal(service.nextAttemptAt, time + 120_000);
  assert.equal(await service.refresh(), false);
  assert.equal(calls, 1);
  time += 120_001;
  service.fetchImpl = async () => { throw new Error('failed URL with super-secret-value'); };
  await service.refresh();
  assert.equal(service.health().errorCode, 'upstream_unavailable');
  assert.equal(JSON.stringify(logs).includes('super-secret-value'), false);
});

test('missing key is explicitly not configured and performs no network work', async (t) => {
  const service = new SuspensionService({ dataDir: await temporaryDirectory(t), fetchImpl: async () => { throw new Error('must never run'); } });
  assert.equal(await service.refresh(), false);
  assert.equal(service.health().configured, false);
  assert.equal(service.health().errorCode, 'not_configured');
  assert.throws(() => service.getSnapshot(), /not_configured/);
  service.start();
  await service.stop();
});

test('restart revalidates feed before serving and reuses validated persisted CAP', async (t) => {
  const dataDir = await temporaryDirectory(t);
  const first = new SuspensionService({ apiKey: 'key', dataDir, now: () => NOW, fetchImpl: async (url) => xmlResponse(url === CAP_URL ? cap : atom()) });
  await first.refresh();
  let calls = 0;
  const restored = new SuspensionService({ apiKey: 'key', dataDir, now: () => NOW, fetchImpl: async (url) => { calls += 1; assert.notEqual(url, CAP_URL); return xmlResponse(atom()); } });
  await restored.initialize();
  assert.throws(() => restored.getSnapshot(), /not_yet_checked/);
  await restored.refresh();
  assert.equal(calls, 1);
  assert.equal(restored.getSnapshot().notices.length, 1);
  assert.equal(restored.getSnapshot().revision, first.getSnapshot().revision);
});

test('corrupt persisted data is ignored and never becomes a ready snapshot', async (t) => {
  const dataDir = await temporaryDirectory(t);
  await writeFile(join(dataDir, 'suspensions.json'), '{"schemaVersion":1,"caps":[{"id":"bad"}]}');
  const service = new SuspensionService({ apiKey: 'key', dataDir });
  await service.initialize();
  assert.equal(service.capCache.size, 0);
  assert.throws(() => service.getSnapshot());
});

test('cache age is enforced even after a past successful check', async (t) => {
  let time = NOW;
  const service = new SuspensionService({ apiKey: 'key', dataDir: await temporaryDirectory(t), now: () => time, fetchImpl: async () => xmlResponse(atom([])) });
  await service.refresh();
  time += 900_001;
  assert.equal(service.health().errorCode, 'stale_cache');
  assert.throws(() => service.getSnapshot(), /stale_cache/);
});

test('partial upstream CAP failures and future-dated feeds reject the whole refresh', async (t) => {
  const service = new SuspensionService({ apiKey: 'key', dataDir: await temporaryDirectory(t), now: () => NOW, fetchImpl: async (url) => url === CAP_URL ? new Response('no', { status: 500 }) : xmlResponse(atom()) });
  await service.refresh();
  assert.equal(service.snapshot, null);
  assert.throws(() => service.getSnapshot());
  service.nextAttemptAt = 0;
  service.fetchImpl = async () => xmlResponse(atom([], '2099-09-15T00:00:00Z'));
  await service.refresh();
  assert.equal(service.health().errorCode, 'source_time_in_future');
});

test('request timeout cancels the request instead of hanging a poller', async (t) => {
  const service = new SuspensionService({ apiKey: 'key', dataDir: await temporaryDirectory(t), now: () => NOW, requestTimeoutMs: 20,
    fetchImpl: (_url, { signal }) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })) });
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    assert.equal(await service.refresh(), false);
    assert.equal(service.health().errorCode, 'upstream_timeout');
  } finally { clearTimeout(keepAlive); }
});

test('response streaming is bounded even without Content-Length', async (t) => {
  const service = new SuspensionService({ apiKey: 'key', dataDir: await temporaryDirectory(t), now: () => NOW, fetchImpl: async () => xmlResponse('x'.repeat(1_048_577)) });
  await service.refresh();
  assert.equal(service.health().errorCode, 'source_too_large');
});
