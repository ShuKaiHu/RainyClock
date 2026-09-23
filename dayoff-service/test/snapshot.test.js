import test from 'node:test';
import assert from 'node:assert/strict';
import { ServiceError } from '../src/errors.js';
import { createSnapshotReader } from '../src/snapshot.js';
import { SuspensionService } from '../src/service.js';
import { cap, atom, CAP_URL, NOW, xmlResponse, memoryStore } from './helpers.js';

const checkedAt = new Date(NOW - 60_000).toISOString();
const revision = 'a'.repeat(64);
const stateDocument = (overrides = {}) => ({
  schemaVersion: 1, revision, checkedAt, sourceUpdatedAt: '2026-08-24T10:29:00.000Z', noticesJSON: '[]', noticeCount: 0,
  errorCode: null, failures: 0, lastAttemptAt: checkedAt, lastSuccessAt: checkedAt, nextAttemptAt: NOW + 240_000, pendingBroadcastRevision: null,
  push: { configured: true, mode: 'alert' }, job: { owner: 'execution-1', finishedAt: checkedAt, durationMs: 1200, code: null, changed: false }, updatedAt: checkedAt, ...overrides
});

// Counts reads so the cache and the herd coalescing are observable.
function countingStore(store) {
  let reads = 0;
  return { store: { ...store, get: (path) => { reads += 1; return store.get(path); } }, reads: () => reads };
}

test('no document is not_configured; a failed poll reports its code even with a fresh snapshot; age alone gives stale_cache', async () => {
  const store = memoryStore();
  let time = NOW;
  const reader = createSnapshotReader({ store, now: () => time, cacheMs: 0 });
  assert.deepEqual(await reader.health(), { configured: false, available: false, state: 'not_configured', errorCode: 'not_configured', lastAttemptAt: null, lastSuccessAt: null, nextAttemptAt: null });
  await assert.rejects(reader.getSnapshot(), /not_configured/);
  await store.set('state/current', stateDocument({ revision: null, checkedAt: null, noticesJSON: null, lastSuccessAt: null, errorCode: 'upstream_http_error', failures: 1 }));
  assert.equal((await reader.health()).errorCode, 'upstream_http_error');
  await store.set('state/current', stateDocument({ revision: null, checkedAt: null, noticesJSON: null, lastSuccessAt: null, failures: 0, lastAttemptAt: null, nextAttemptAt: 0 }));
  assert.equal((await reader.health()).errorCode, 'not_yet_checked');
  await store.set('state/current', stateDocument());
  assert.deepEqual(await reader.health(), { configured: true, available: true, state: 'ready', errorCode: null, lastAttemptAt: checkedAt, lastSuccessAt: checkedAt, nextAttemptAt: new Date(NOW + 240_000).toISOString() });
  assert.deepEqual(await reader.getSnapshot(), { schemaVersion: 1, checkedAt, sourceUpdatedAt: '2026-08-24T10:29:00.000Z', notices: [], revision });
  await store.set('state/current', stateDocument({ errorCode: 'upstream_rate_limited', failures: 1 }));
  assert.equal((await reader.health()).state, 'unavailable');
  await assert.rejects(reader.getSnapshot(), /upstream_rate_limited/);
  await store.set('state/current', stateDocument());
  time = NOW + 840_001;
  assert.equal((await reader.health()).errorCode, 'stale_cache');
  await assert.rejects(reader.getSnapshot(), (error) => error instanceof ServiceError && error.code === 'stale_cache');
});

test('one read per cache window is shared by concurrent callers, and a cached document is still judged by the clock', async () => {
  const { store, reads } = countingStore(memoryStore());
  await store.set('state/current', stateDocument());
  let time = NOW;
  const reader = createSnapshotReader({ store, now: () => time, cacheMs: 5000 });
  const results = await Promise.all([reader.getSnapshot(), reader.health(), reader.getSnapshot()]);
  assert.equal(results[0].revision, revision);
  assert.equal(reads(), 1);
  time += 4999;
  assert.equal((await reader.health()).available, true);
  assert.equal(reads(), 1);
  time += 1;
  assert.equal((await reader.health()).available, true);
  assert.equal(reads(), 2);
  // Within the window, but past the snapshot's age limit: the answer flips
  // without a read.
  time = NOW + 840_001;
  const stale = createSnapshotReader({ store, now: () => NOW, cacheMs: 3_600_000 });
  assert.equal((await stale.health()).available, true);
  const before = reads();
  const later = createSnapshotReader({ store, now: () => time, cacheMs: 3_600_000 });
  assert.equal((await later.health()).errorCode, 'stale_cache');
  await assert.rejects(later.getSnapshot(), /stale_cache/);
  assert.equal(reads(), before + 1);
  time = NOW + 840_002;
  await assert.rejects(later.getSnapshot(), /stale_cache/);
  assert.equal(reads(), before + 1);
});

test('the served bytes equal the poller snapshot for the same feed', async () => {
  const store = memoryStore();
  const service = new SuspensionService({ apiKey: 'key', store, now: () => NOW, fetchImpl: async (url) => xmlResponse(url === CAP_URL ? cap : atom()) });
  assert.equal(await service.refresh(), true);
  const reader = createSnapshotReader({ store, now: () => NOW + 1000 });
  const served = await reader.getSnapshot();
  assert.equal(JSON.stringify(served), JSON.stringify(service.getSnapshot()));
  assert.deepEqual(Object.keys(served), ['schemaVersion', 'checkedAt', 'sourceUpdatedAt', 'notices', 'revision']);
  assert.equal(served.revision, (await store.get('state/current')).revision);
  assert.deepEqual(await reader.health(), service.health());
});

test('a store failure is storage_unavailable, and a document that cannot be decoded is never served', async () => {
  const outage = async () => { throw new Error('UNAVAILABLE: 14'); };
  const failing = { ...memoryStore(), get: outage, getAll: outage };
  const reader = createSnapshotReader({ store: failing, now: () => NOW });
  await assert.rejects(reader.health(), (error) => error instanceof ServiceError && error.code === 'storage_unavailable');
  await assert.rejects(reader.getSnapshot(), /storage_unavailable/);
  await assert.rejects(reader.details(), /storage_unavailable/);
  const store = memoryStore();
  const broken = createSnapshotReader({ store, now: () => NOW, cacheMs: 0 });
  await store.set('state/current', stateDocument({ noticesJSON: '{not json' }));
  await assert.rejects(broken.getSnapshot(), /invalid_stored_state/);
  await store.set('state/current', { schemaVersion: 2, checkedAt, noticesJSON: '[]' });
  assert.equal((await broken.health()).errorCode, 'invalid_stored_state');
  assert.equal((await broken.health()).configured, true);
});

test('details reads live state, the lease and the pending claim, and never carries tokens or installation ids', async () => {
  const store = memoryStore();
  const token = 'b'.repeat(64);
  const installationId = '310251b2-9c20-4dcb-b695-89b78bb1f148';
  const claim = { revision, claimedAt: NOW - 30_000, state: 'sending', owner: 'execution-2', leaseUntil: NOW + 90_000, attempts: 1, cursor: installationId, passComplete: false, accepted: 5, failed: 1, unregistered: 2, retryPending: 3, finishedAt: null, expiresAt: new Date(NOW + 7 * 86_400_000) };
  await store.set('state/current', stateDocument({ pendingBroadcastRevision: revision }));
  await store.set('state/lease', { owner: 'execution-2', leaseUntil: NOW + 100_000 });
  await store.set(`broadcasts/${revision}`, claim);
  await store.set(`broadcasts/${revision}/retries/${token}`, { token, reason: 'TooManyRequests', claimedAt: claim.claimedAt, attempts: 1, expiresAt: new Date(NOW + 7 * 86_400_000) });
  await store.set(`devices/${installationId}`, { installationId, deviceToken: token, credentialHash: 'c'.repeat(64), updatedAt: NOW, expiresAt: new Date(NOW + 90 * 86_400_000) });
  const reader = createSnapshotReader({ store, now: () => NOW });
  const details = await reader.details();
  assert.deepEqual(details, {
    configured: true, available: true, state: 'ready', errorCode: null, lastAttemptAt: checkedAt, lastSuccessAt: checkedAt, nextAttemptAt: new Date(NOW + 240_000).toISOString(),
    revision, checkedAt, noticeCount: 0, ageMs: 60_000, sourceUpdatedAt: '2026-08-24T10:29:00.000Z',
    job: { owner: 'execution-1', finishedAt: checkedAt, durationMs: 1200, code: null, changed: false },
    lease: { owner: 'execution-2', leaseUntil: NOW + 100_000 },
    broadcast: { revision, state: 'sending', attempts: 1, accepted: 5, failed: 1, unregistered: 2, retryPending: 3, finishedAt: null },
    storage: 'memory-test-only', serverTime: new Date(NOW).toISOString()
  });
  const text = JSON.stringify(details);
  assert.equal(text.includes(token), false);
  assert.equal(text.includes(installationId), false);
  const empty = createSnapshotReader({ store: memoryStore(), now: () => NOW });
  assert.deepEqual(await empty.details(), { configured: false, available: false, state: 'not_configured', errorCode: 'not_configured', lastAttemptAt: null, lastSuccessAt: null, nextAttemptAt: null, revision: null, checkedAt: null, noticeCount: null, ageMs: null, sourceUpdatedAt: null, job: null, lease: null, broadcast: null, storage: 'memory-test-only', serverTime: new Date(NOW).toISOString() });
});
