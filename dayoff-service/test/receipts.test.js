import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceRegistry, syncStatus } from '../src/devices.js';
import { createHTTPServer } from '../src/http.js';
import { NOW, memoryStore } from './helpers.js';

const identity = { installationId: '310251b2-9c20-4dcb-b695-89b78bb1f148', credential: 'c'.repeat(64) };
const registration = { ...identity, deviceToken: 'a'.repeat(64) };
const checkedAt = new Date(NOW - 60_000).toISOString();
const appliedAt = new Date(NOW).toISOString();
const acknowledgement = { revision: 'b'.repeat(64), checkedAt, appliedAt, result: 'applied' };
const receiptRequest = (overrides = {}) => ({ ...identity, ...acknowledgement, ...overrides });

async function registeredRegistry(options = {}) {
  const registry = new DeviceRegistry({ store: memoryStore(), now: () => NOW, ...options });
  await registry.register(registration);
  return registry;
}

test('receipts require a registered installation and its credential', async () => {
  const registry = new DeviceRegistry({ store: memoryStore(), now: () => NOW });
  await assert.rejects(registry.recordReceipt(receiptRequest()), /device_not_registered/);
  await assert.rejects(registry.receipt(identity), /device_not_registered/);
  await registry.register(registration);
  await assert.rejects(registry.recordReceipt(receiptRequest({ credential: 'd'.repeat(64) })), /device_credential_mismatch/);
  await assert.rejects(registry.receipt({ ...identity, credential: 'd'.repeat(64) }), /device_credential_mismatch/);
  assert.equal(await registry.receipt(identity), null);
  assert.deepEqual(await registry.recordReceipt(receiptRequest()), { recorded: true });
  assert.deepEqual(await registry.receipt(identity), acknowledgement);
});

test('receipts persist without raw credentials and survive registration refresh and token rotation', async () => {
  const registry = await registeredRegistry();
  await registry.recordReceipt(receiptRequest());
  await registry.register({ ...registration, deviceToken: 'f'.repeat(64) });
  const doc = await registry.store.get(`devices/${identity.installationId}`);
  assert.equal(JSON.stringify(doc).includes(identity.credential), false);
  assert.deepEqual(doc.receipt, acknowledgement);
  const restored = new DeviceRegistry({ store: registry.store, now: () => NOW });
  await restored.initialize();
  assert.deepEqual(await restored.receipt(identity), acknowledgement);
  const externalCopy = await restored.receipt(identity);
  externalCopy.result = 'no_alarm';
  assert.equal((await restored.receipt(identity)).result, 'applied');
  assert.deepEqual(await restored.tokens(), ['f'.repeat(64)]);
});

test('receipt ordering uses checkedAt first, then appliedAt; duplicates and late replies cannot regress it', async () => {
  const registry = await registeredRegistry();
  assert.deepEqual(await registry.recordReceipt(receiptRequest()), { recorded: true });
  assert.deepEqual(await registry.recordReceipt(receiptRequest()), { recorded: false });
  assert.deepEqual(await registry.recordReceipt(receiptRequest({ result: 'no_alarm' })), { recorded: false });
  assert.deepEqual(await registry.recordReceipt(receiptRequest({ checkedAt: new Date(NOW - 120_000).toISOString(), appliedAt: new Date(NOW + 10_000).toISOString(), revision: 'd'.repeat(64) })), { recorded: false });
  assert.deepEqual(await registry.recordReceipt(receiptRequest({ appliedAt: new Date(NOW - 30_000).toISOString() })), { recorded: false });
  const newer = { ...acknowledgement, checkedAt: new Date(NOW - 30_000).toISOString(), result: 'no_alarm', revision: 'e'.repeat(64) };
  assert.deepEqual(await registry.recordReceipt({ ...identity, ...newer }), { recorded: true });
  const later = { ...newer, appliedAt: new Date(NOW + 10_000).toISOString(), result: 'applied' };
  assert.deepEqual(await registry.recordReceipt({ ...identity, ...later }), { recorded: true });
  assert.deepEqual(await registry.receipt(identity), later);
  const latest = { ...later, checkedAt: new Date(NOW - 20_000).toISOString(), appliedAt: new Date(NOW + 20_000).toISOString() };
  assert.deepEqual(await Promise.all([registry.recordReceipt({ ...identity, ...latest }), registry.recordReceipt({ ...identity, ...later })]), [{ recorded: true }, { recorded: false }]);
  assert.deepEqual(await registry.receipt(identity), latest);
});

test('equivalent timezone forms normalize before receipt ordering', async () => {
  const registry = await registeredRegistry();
  await registry.recordReceipt(receiptRequest());
  assert.deepEqual(await registry.recordReceipt(receiptRequest({ checkedAt: '2026-09-15T20:29:00+08:00', appliedAt: '2026-09-15T20:30:00+08:00' })), { recorded: false });
  assert.deepEqual(await registry.receipt(identity), acknowledgement);
});

test('deleting or expiring a registration removes access to its receipt; re-registration starts empty', async () => {
  let now = NOW;
  const registry = await registeredRegistry({ now: () => now });
  await registry.recordReceipt(receiptRequest());
  const deletion = registry.remove(identity);
  const delayedReceipt = registry.recordReceipt(receiptRequest());
  await deletion;
  await assert.rejects(delayedReceipt, /device_not_registered/);
  await registry.register(registration);
  assert.equal(await registry.receipt(identity), null);
  await registry.recordReceipt(receiptRequest());
  now += 91 * 24 * 60 * 60 * 1000;
  await assert.rejects(registry.receipt(identity), /device_not_registered/);
  await assert.rejects(registry.recordReceipt(receiptRequest()), /device_not_registered/);
});

test('APNs unregistration removes the receipt with the registration', async () => {
  const registry = await registeredRegistry();
  await registry.recordReceipt(receiptRequest());
  await registry.removeUnregistered(registration.deviceToken, NOW);
  await assert.rejects(registry.receipt(identity), /device_not_registered/);
});

test('receipt validation rejects malformed, impossible, future and out-of-order timestamps', async () => {
  const registry = await registeredRegistry();
  const invalid = [
    { revision: 'untrusted' }, { revision: 123 }, { result: 'cancelled' },
    { checkedAt: '2026-09-15' }, { appliedAt: '2026-02-30T00:00:00Z' },
    { appliedAt: '2026-09-15T25:30:00Z' }, { checkedAt: '2026-09-15T12:30:00' },
    { checkedAt: new Date(NOW + 300_001).toISOString() },
    { appliedAt: new Date(NOW + 300_001).toISOString() },
    { checkedAt: appliedAt, appliedAt: new Date(NOW - 300_001).toISOString() },
    { personalAddress: 'unexpected field' }, { installationId: null }, { checkedAt: {} }
  ];
  for (const value of invalid) assert.throws(() => registry.recordReceipt(receiptRequest(value)), /invalid_device_request/);
  assert.throws(() => registry.recordReceipt([]), /invalid_device_request/);
  assert.throws(() => registry.recordReceipt(null), /invalid_device_request/);
  await assert.rejects(registry.receipt({ ...identity, deviceToken: registration.deviceToken }), /invalid_device_request/);
  assert.equal(await registry.receipt(identity), null);
});

test('a five-minute device clock skew is allowed without weakening future bounds', async () => {
  const registry = await registeredRegistry();
  const input = receiptRequest({ checkedAt: appliedAt, appliedAt: new Date(NOW - 300_000).toISOString() });
  assert.deepEqual(await registry.recordReceipt(input), { recorded: true });
  assert.equal((await registry.receipt(identity)).appliedAt, input.appliedAt);
});

test('invalid persisted receipt data is rejected when it is read', async () => {
  const registry = await registeredRegistry();
  await registry.recordReceipt(receiptRequest());
  const path = `devices/${identity.installationId}`;
  const doc = await registry.store.get(path);
  await registry.store.set(path, { ...doc, receipt: { ...doc.receipt, result: 'delivered' } });
  const restored = new DeviceRegistry({ store: registry.store, now: () => NOW });
  await restored.initialize();
  await assert.rejects(restored.receipt(identity), /invalid_device_storage/);
  await assert.rejects(restored.recordReceipt(receiptRequest()), /invalid_device_storage/);
});

test('status tracks source revision, not every poll timestamp; unavailable source never looks confirmed', () => {
  const snapshot = { revision: acknowledgement.revision, checkedAt: new Date(NOW + 60_000).toISOString() };
  assert.deepEqual(syncStatus(acknowledgement, snapshot, NOW), { status: 'applied', matchesCurrentRevision: true, currentRevision: snapshot.revision, receipt: acknowledgement });
  assert.equal(syncStatus({ ...acknowledgement, result: 'no_alarm' }, snapshot, NOW).status, 'no_alarm');
  assert.equal(syncStatus(acknowledgement, { revision: 'f'.repeat(64) }, NOW).status, 'pending');
  assert.deepEqual(syncStatus(acknowledgement, null, NOW), { status: 'source_unavailable', matchesCurrentRevision: false, currentRevision: null, receipt: acknowledgement });
  assert.equal(syncStatus(null, snapshot, NOW).status, 'pending');
});

test('historical receipt becomes pending at Taiwan midnight even with unchanged notices', () => {
  const snapshot = { revision: acknowledgement.revision };
  const beforeMidnight = Date.parse('2026-09-15T15:59:59Z');
  const midnight = Date.parse('2026-09-15T16:00:00Z');
  assert.equal(syncStatus(acknowledgement, snapshot, beforeMidnight).status, 'applied');
  assert.deepEqual(syncStatus(acknowledgement, snapshot, midnight), { status: 'pending', matchesCurrentRevision: true, currentRevision: snapshot.revision, receipt: acknowledgement });
});

async function listen(t, server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); });
  return `http://127.0.0.1:${server.address().port}`;
}

test('receipt HTTP routes authenticate first and distinguish receipt state from source availability', async (t) => {
  const registry = await registeredRegistry();
  let available = true, sourceReads = 0;
  const service = { getSnapshot() { sourceReads += 1; if (!available) throw new Error('source failed'); return { revision: acknowledgement.revision }; } };
  // Existing installations can report and inspect even if push is temporarily disabled.
  const base = await listen(t, createHTTPServer({ service, registry, pushConfigured: false, now: () => NOW }));
  const send = (path, body) => fetch(base + '/v1/devices/' + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await send('sync-status', { ...identity, credential: 'd'.repeat(64) })).status, 403);
  assert.equal((await send('sync-receipt', receiptRequest({ credential: 'd'.repeat(64) }))).status, 403);
  assert.equal(sourceReads, 0);
  let response = await send('sync-status', identity);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, 'pending');
  response = await send('sync-receipt', receiptRequest());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { recorded: true });
  assert.equal(sourceReads, 1); // Recording never fetches upstream or reads the cache.
  response = await send('sync-receipt', receiptRequest());
  assert.deepEqual(await response.json(), { recorded: false });
  response = await send('sync-status', identity);
  assert.deepEqual(await response.json(), { status: 'applied', matchesCurrentRevision: true, currentRevision: acknowledgement.revision, receipt: acknowledgement });
  available = false;
  response = await send('sync-status', identity);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, 'source_unavailable');
  await registry.remove(identity);
  response = await send('sync-receipt', receiptRequest());
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: 'device_not_registered' });
  assert.equal((await send('sync-status', identity)).status, 404);
});

test('receipt HTTP content is bounded and uses the same per-peer rate limit', async (t) => {
  const registry = await registeredRegistry();
  const base = await listen(t, createHTTPServer({ service: {}, registry, now: () => NOW }));
  const send = (body, headers = { 'Content-Type': 'application/json' }) => fetch(base + '/v1/devices/sync-receipt', { method: 'POST', headers, body: typeof body === 'string' ? body : JSON.stringify(body) });
  assert.equal((await send(receiptRequest({ extra: 'x'.repeat(2000) }))).status, 413);
  assert.equal((await send(receiptRequest(), { 'Content-Type': 'text/plain' })).status, 400);
  assert.equal((await send('{broken')).status, 400);
  assert.equal((await send(receiptRequest({ result: 'delivered' }))).status, 400);
  assert.equal((await send(receiptRequest(), { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' })).status, 413);
  let last;
  for (let index = 0; index < 30; index += 1) last = await send(receiptRequest());
  assert.equal(last.status, 429);
});
