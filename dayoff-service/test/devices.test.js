import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DeviceRegistry, RevisionBroadcaster } from '../src/devices.js';
import { createHTTPServer } from '../src/http.js';
import { SuspensionService } from '../src/service.js';
import { NOW, temporaryDirectory } from './helpers.js';

const registration = (number = 1) => ({ installationId: `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`, deviceToken: number.toString(16).padStart(64, '0'), credential: 'c'.repeat(64) });

test('device credentials are hashed; updates/deletes need the same credential', async (t) => {
  const dataDir = await temporaryDirectory(t);
  const registry = new DeviceRegistry({ dataDir, now: () => NOW });
  const input = registration();
  assert.deepEqual(await registry.register(input), { created: true });
  assert.equal((await readFile(join(dataDir, 'devices.json'), 'utf8')).includes(input.credential), false);
  await assert.rejects(registry.register({ ...input, credential: 'd'.repeat(64) }), /device_credential_mismatch/);
  await assert.rejects(registry.remove({ ...input, credential: 'd'.repeat(64) }), /device_credential_mismatch/);
  assert.deepEqual(await registry.register({ ...input, deviceToken: 'f'.repeat(64) }), { created: false });
  const restored = new DeviceRegistry({ dataDir, now: () => NOW });
  await restored.initialize();
  assert.deepEqual(restored.tokens(), ['f'.repeat(64)]);
  await restored.remove(input);
  assert.deepEqual(restored.tokens(), []);
});

test('invalid tokens/credentials, registry capacity, duplicate broadcasts and TTL are bounded', async (t) => {
  let time = NOW;
  const registry = new DeviceRegistry({ dataDir: await temporaryDirectory(t), now: () => time, maxDevices: 2 });
  assert.throws(() => registry.register({ ...registration(), deviceToken: 'bad' }), /invalid_device_request/);
  assert.throws(() => registry.register({ ...registration(), credential: 'a'.repeat(32) }), /invalid_device_request/);
  await registry.register(registration());
  await registry.register({ ...registration(2), deviceToken: registration().deviceToken });
  assert.equal(registry.tokens().length, 1);
  await assert.rejects(registry.register(registration(3)), /device_registry_full/);
  time += 91 * 24 * 3600_000;
  assert.deepEqual(registry.tokens(), []);
  await registry.register(registration(3));
  assert.equal(registry.devices.size, 1);
});

test('push broadcasts use bounded concurrency and delete APNs-unregistered tokens', async (t) => {
  const registry = new DeviceRegistry({ dataDir: await temporaryDirectory(t), now: () => NOW });
  for (let i = 1; i <= 7; i += 1) await registry.register(registration(i));
  let active = 0, peak = 0;
  const sent = [];
  const dispatcher = { send: async (token, body) => {
    active += 1; peak = Math.max(peak, active); sent.push({ token, body });
    await new Promise(setImmediate);
    active -= 1;
    return { ok: false, unregistered: token === registration().deviceToken, timestamp: NOW };
  }, close() {} };
  const broadcaster = new RevisionBroadcaster({ registry, dispatcher, concurrency: 2 });
  await broadcaster.enqueue('revision1');
  assert.equal(peak, 2);
  assert.equal(sent.length, 7);
  assert.deepEqual(sent[0].body, { revision: 'revision1' });
  assert.equal(registry.tokens().includes(registration().deviceToken), false);
  await broadcaster.stop();
});

test('an old 410 cannot remove a newer token re-registration', async (t) => {
  const registry = new DeviceRegistry({ dataDir: await temporaryDirectory(t), now: () => NOW });
  await registry.register(registration());
  await registry.removeUnregistered(registration().deviceToken, NOW - 1000);
  assert.equal(registry.tokens().length, 1);
});

test('registry rejects excess queued writes instead of growing without bound', async (t) => {
  const registry = new DeviceRegistry({ dataDir: await temporaryDirectory(t), now: () => NOW });
  let release;
  registry.queue = new Promise((resolve) => { release = resolve; });
  const pending = Array.from({ length: 128 }, (_, index) => registry.register(registration(index + 1)));
  await assert.rejects(registry.register(registration(129)), /device_registry_busy/);
  release();
  await Promise.all(pending);
  assert.equal(registry.pendingWrites, 0);
});

test('a revision arriving while the previous batch settles is not lost', async (t) => {
  const registry = new DeviceRegistry({ dataDir: await temporaryDirectory(t), now: () => NOW });
  await registry.register(registration());
  const revisions = [];
  let queued = false;
  const broadcaster = new RevisionBroadcaster({ registry, dispatcher: { async send(_token, { revision }) { revisions.push(revision); return { ok: true }; }, close() {} }, log() {
    if (!queued) { queued = true; queueMicrotask(() => { void broadcaster.enqueue('second'); }); }
  } });
  await broadcaster.enqueue('first');
  await new Promise(setImmediate);
  await broadcaster.running;
  assert.deepEqual(revisions, ['first', 'second']);
  await broadcaster.stop();
});

async function listen(t, server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); });
  return `http://127.0.0.1:${server.address().port}`;
}

test('unconfigured health and snapshots are 503; no fallback empty results', async (t) => {
  const dataDir = await temporaryDirectory(t);
  const service = new SuspensionService({ dataDir });
  const registry = new DeviceRegistry({ dataDir });
  const base = await listen(t, createHTTPServer({ service, registry }));
  const health = await fetch(base + '/health');
  assert.equal(health.status, 503);
  assert.deepEqual(await health.json(), { configured: false, available: false, state: 'not_configured', errorCode: 'not_configured', lastAttemptAt: null, lastSuccessAt: null, nextAttemptAt: null, pushConfigured: false });
  const snapshot = await fetch(base + '/v1/suspensions');
  assert.equal(snapshot.status, 503);
  assert.deepEqual(await snapshot.json(), { error: 'not_configured' });
  assert.equal((await fetch(base + '/v1/devices', { method: 'POST' })).status, 503);
});

test('device API validates size and ownership, rate limits writes, and does not call the source', async (t) => {
  const dataDir = await temporaryDirectory(t);
  const service = new SuspensionService({ dataDir, apiKey: 'not-used' });
  const registry = new DeviceRegistry({ dataDir });
  const base = await listen(t, createHTTPServer({ service, registry, pushConfigured: true, now: () => NOW }));
  const send = (method, body) => fetch(base + '/v1/devices', { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await send('POST', registration())).status, 201);
  assert.equal((await send('POST', registration())).status, 200);
  assert.equal((await send('DELETE', { ...registration(), credential: 'a'.repeat(64) })).status, 403);
  assert.equal((await send('POST', { ...registration(), extra: 'x'.repeat(2000) })).status, 413);
  assert.equal((await send('DELETE', registration())).status, 204);
  let limited;
  for (let i = 0; i < 30; i += 1) limited = await send('POST', registration());
  assert.equal(limited.status, 429);
  assert.equal(service.lastAttemptAt, null);
});
