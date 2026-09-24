import test from 'node:test';
import assert from 'node:assert/strict';
import { broadcastRevision, classifyResult } from '../src/broadcast.js';
import { DeviceRegistry } from '../src/devices.js';
import { SuspensionService } from '../src/service.js';
import { cap, atom, CAP_URL, NOW, xmlResponse, memoryStore } from './helpers.js';

const installationId = (number) => `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`;
const tokenOf = (number) => number.toString(16).padStart(64, '0');
const registration = (number, token = tokenOf(number)) => ({ installationId: installationId(number), deviceToken: token, credential: 'c'.repeat(64) });
const accepted = { ok: true, status: 200, unregistered: false, retryable: false };
const retryable = { ok: false, status: 503, reason: 'ServiceUnavailable', unregistered: false, retryable: true };
const rejected = { ok: false, status: 400, reason: 'BadDeviceToken', unregistered: false, retryable: false };

async function registered(count, { store = memoryStore(), now = () => NOW } = {}) {
  const registry = new DeviceRegistry({ store, now });
  for (let i = 1; i <= count; i += 1) await registry.register(registration(i));
  return { store, registry };
}

// Answers per token; `sent` records every send in order.
function fakeDispatcher(respond = () => accepted) {
  const sent = [];
  return { sent, async send(token, body) { sent.push({ token, body }); return respond(token, sent.length); }, close() {} };
}

const broadcast = (overrides) => broadcastRevision({ revision: 'r1', owner: 'me', concurrency: 4, pageSize: 50, leaseMs: 120_000, now: () => NOW, ...overrides });

test('classifyResult separates credential rejections from ordinary rejections and retries', () => {
  assert.equal(classifyResult(accepted), 'accepted');
  assert.equal(classifyResult({ ok: false, status: 410, unregistered: true, retryable: false }), 'unregistered');
  assert.equal(classifyResult(retryable), 'retryable');
  assert.equal(classifyResult({ ok: false, status: 0, reason: 'Timeout', unregistered: false, retryable: true }), 'retryable');
  assert.equal(classifyResult({ ok: false, status: 403, reason: 'ExpiredProviderToken', unregistered: false, retryable: false }), 'credentials_rejected');
  assert.equal(classifyResult({ ok: false, status: 400, reason: 'BadTopic', unregistered: false, retryable: false }), 'credentials_rejected');
  assert.equal(classifyResult({ ok: false, status: 403, reason: 'Forbidden', unregistered: false, retryable: false }), 'failed');
  assert.equal(classifyResult(rejected), 'failed');
  assert.equal(classifyResult(null), 'failed');
});

test('a pass sends each live token once with bounded concurrency and acts on 410 conditionally', async () => {
  let time = NOW;
  const { store, registry } = await registered(6, { now: () => time });
  await registry.register(registration(7, tokenOf(6)));
  time = NOW + 10 * 24 * 3600_000;
  await registry.register(registration(8));
  time = NOW + 91 * 24 * 3600_000;
  await registry.register(registration(9));
  let active = 0, peak = 0;
  const dispatcher = fakeDispatcher(async (token) => {
    active += 1; peak = Math.max(peak, active);
    await new Promise(setImmediate);
    active -= 1;
    if (token === tokenOf(1)) return { ok: false, status: 410, reason: 'Unregistered', unregistered: true, retryable: false, timestamp: time };
    if (token === tokenOf(8)) return { ok: false, status: 410, reason: 'Unregistered', unregistered: true, retryable: false, timestamp: NOW };
    return token === tokenOf(2) ? rejected : accepted;
  });
  const result = await broadcast({ store, registry, dispatcher, concurrency: 2, now: () => time });
  assert.equal(peak, 2);
  // Devices 1-7 aged out; 8 (10 days old) and 9 are live, 6 and 7 share a token.
  assert.deepEqual(dispatcher.sent.map(({ token }) => token).sort(), [tokenOf(8), tokenOf(9)].sort());
  assert.deepEqual(dispatcher.sent[0].body, { revision: 'r1' });
  assert.equal(result.complete, true);
  assert.equal(result.state, 'done');
  // Device 8 re-registered after the 410's timestamp, so it survives.
  assert.equal((await registry.tokens()).includes(tokenOf(8)), true);
  time = NOW;
  const fresh = await registered(7, { store: memoryStore(), now: () => time });
  await fresh.registry.register(registration(7, tokenOf(6)));
  const second = fakeDispatcher((token) => (token === tokenOf(1) ? { ok: false, status: 410, unregistered: true, retryable: false, timestamp: NOW } : token === tokenOf(2) ? rejected : accepted));
  const outcome = await broadcast({ store: fresh.store, registry: fresh.registry, dispatcher: second, now: () => time });
  assert.equal(second.sent.length, 6);
  assert.equal((await fresh.registry.tokens()).includes(tokenOf(1)), false);
  assert.deepEqual({ accepted: outcome.accepted, failed: outcome.failed, unregistered: outcome.unregistered, retryPending: outcome.retryPending, attempts: outcome.attempts, state: outcome.state }, { accepted: 4, failed: 1, unregistered: 1, retryPending: 0, attempts: 1, state: 'done' });
  const claim = await fresh.store.get('broadcasts/r1');
  assert.equal(claim.owner, null);
  assert.equal(claim.leaseUntil, 0);
  assert.equal(claim.passComplete, true);
  assert.equal(claim.finishedAt, new Date(NOW).toISOString());
  assert.ok(claim.expiresAt instanceof Date);
});

test('retryable results are recorded, the pass ends partial, and the next attempt re-sends only those', async () => {
  const { store, registry } = await registered(3);
  await store.set('state/current', { schemaVersion: 1, revision: 'r1', pendingBroadcastRevision: 'r1' });
  const logs = [];
  const first = fakeDispatcher((token) => (token === tokenOf(2) ? retryable : accepted));
  const outcome = await broadcast({ store, registry, dispatcher: first, log: (event) => logs.push(event) });
  assert.equal(first.sent.length, 3);
  assert.deepEqual({ state: outcome.state, passComplete: outcome.passComplete, retryPending: outcome.retryPending, accepted: outcome.accepted, complete: outcome.complete }, { state: 'partial', passComplete: true, retryPending: 1, accepted: 2, complete: false });
  const retry = await store.get(`broadcasts/r1/retries/${tokenOf(2)}`);
  assert.equal(retry.token, tokenOf(2));
  assert.equal(retry.reason, 'ServiceUnavailable');
  assert.equal(retry.attempts, 1);
  assert.equal(retry.claimedAt, (await store.get('broadcasts/r1')).claimedAt);
  assert.ok(retry.expiresAt instanceof Date);
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, 'r1');
  assert.deepEqual(logs.at(-1), { event: 'push_batch', revision: 'r1', accepted: 2, failed: 0, unregistered: 0, retryPending: 1, attempts: 1, state: 'partial' });
  const again = fakeDispatcher(() => retryable);
  const second = await broadcast({ store, registry, dispatcher: again, owner: 'other' });
  assert.deepEqual(again.sent.map(({ token }) => token), [tokenOf(2)]);
  assert.deepEqual({ state: second.state, retryPending: second.retryPending, attempts: second.attempts }, { state: 'partial', retryPending: 1, attempts: 2 });
  assert.equal((await store.get(`broadcasts/r1/retries/${tokenOf(2)}`)).attempts, 2);
  const last = fakeDispatcher(() => accepted);
  const third = await broadcast({ store, registry, dispatcher: last });
  assert.deepEqual(last.sent.map(({ token }) => token), [tokenOf(2)]);
  assert.deepEqual({ state: third.state, retryPending: third.retryPending, accepted: third.accepted, attempts: third.attempts, complete: third.complete }, { state: 'done', retryPending: 0, accepted: 3, attempts: 3, complete: true });
  assert.equal(await store.get(`broadcasts/r1/retries/${tokenOf(2)}`), null);
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, null);
});

test('the attempt cap refuses a fourth claim, says so once, and clears the pointer for good', async () => {
  const { store, registry } = await registered(1);
  await store.set('state/current', { schemaVersion: 1, revision: 'r1', pendingBroadcastRevision: 'r1' });
  const dispatcher = fakeDispatcher(() => retryable);
  for (let i = 0; i < 3; i += 1) await broadcast({ store, registry, dispatcher });
  const logs = [];
  const outcome = await broadcast({ store, registry, dispatcher, log: (event) => logs.push(event) });
  assert.equal(dispatcher.sent.length, 3);
  assert.deepEqual({ exhausted: outcome.exhausted, complete: outcome.complete, attempts: outcome.attempts }, { exhausted: true, complete: false, attempts: 3 });
  assert.equal(logs[0].severity, 'WARNING');
  assert.equal(logs[0].exhausted, true);
  // Exhaustion is terminal: the pointer no longer names the revision, so no
  // later tick re-claims it, and the claim says why it stopped.
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, null);
  const claim = await store.get('broadcasts/r1');
  assert.deepEqual({ state: claim.state, owner: claim.owner, leaseUntil: claim.leaseUntil, attempts: claim.attempts, finishedAt: claim.finishedAt }, { state: 'exhausted', owner: null, leaseUntil: 0, attempts: 3, finishedAt: new Date(NOW).toISOString() });
  const again = await broadcast({ store, registry, dispatcher, log: (event) => logs.push(event) });
  assert.deepEqual({ skipped: again.skipped, exhausted: again.exhausted, complete: again.complete }, { skipped: 'exhausted', exhausted: true, complete: false });
  assert.equal(logs.length, 1);
  assert.equal(dispatcher.sent.length, 3);
  // Once the TTL removes the claim, nothing points at the revision any more,
  // so the Job has nothing to start a fresh pass from.
  await store.delete('broadcasts/r1');
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, null);
});

test('the circuit breaker stops a pass once most results in a run are retryable', async () => {
  const { store, registry } = await registered(120);
  const dispatcher = fakeDispatcher(() => retryable);
  const outcome = await broadcast({ store, registry, dispatcher });
  assert.equal(dispatcher.sent.length, 100);
  assert.deepEqual({ state: outcome.state, passComplete: outcome.passComplete, retryPending: outcome.retryPending, complete: outcome.complete }, { state: 'partial', passComplete: false, retryPending: 100, complete: false });
  assert.equal((await store.get('broadcasts/r1')).cursor, installationId(100));
  const recovered = fakeDispatcher(() => accepted);
  const next = await broadcast({ store, registry, dispatcher: recovered });
  assert.equal(recovered.sent.length, 20);
  assert.deepEqual({ state: next.state, passComplete: next.passComplete, retryPending: next.retryPending }, { state: 'partial', passComplete: true, retryPending: 100 });
});

test('the deadline persists the cursor and a resumed pass sends the rest exactly once', async () => {
  let time = NOW;
  const { store, registry } = await registered(120);
  const dispatcher = fakeDispatcher(() => { time += 10; return accepted; });
  const first = await broadcast({ store, registry, dispatcher, deadlineAt: NOW + 1, now: () => time });
  assert.equal(dispatcher.sent.length, 50);
  assert.equal(first.state, 'partial');
  assert.equal(first.passComplete, false);
  const claim = await store.get('broadcasts/r1');
  assert.equal(claim.cursor, installationId(50));
  assert.equal(claim.owner, null);
  const resumed = await broadcast({ store, registry, dispatcher, owner: 'retry', now: () => time });
  assert.equal(resumed.state, 'done');
  assert.equal(resumed.attempts, 2);
  assert.equal(resumed.accepted, 120);
  assert.deepEqual(new Set(dispatcher.sent.map(({ token }) => token)).size, 120);
  assert.equal(dispatcher.sent.length, 120);
});

test('cancellation stops at the next checkpoint with the cursor persisted', async () => {
  const { store, registry } = await registered(120);
  let cancelled = false;
  const dispatcher = fakeDispatcher(() => { cancelled = true; return accepted; });
  const outcome = await broadcast({ store, registry, dispatcher, isCancelled: () => cancelled });
  assert.equal(dispatcher.sent.length, 50);
  assert.equal(outcome.state, 'partial');
  assert.equal((await store.get('broadcasts/r1')).cursor, installationId(50));
});

test('a newer pending revision supersedes an in-flight pass at its checkpoint and keeps its pointer', async () => {
  const { store, registry } = await registered(120);
  await store.set('state/current', { schemaVersion: 1, revision: 'r2', pendingBroadcastRevision: 'r2' });
  const dispatcher = fakeDispatcher();
  const outcome = await broadcast({ store, registry, dispatcher });
  assert.equal(dispatcher.sent.length, 50);
  assert.deepEqual({ state: outcome.state, complete: outcome.complete }, { state: 'superseded', complete: true });
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, 'r2');
  assert.deepEqual(await broadcast({ store, registry, dispatcher }), { ...outcome, skipped: 'superseded' });
  assert.equal(dispatcher.sent.length, 50);
});

test('a pointer that no longer names this revision is left alone when the pass completes', async () => {
  const { store, registry } = await registered(2);
  await store.set('state/current', { schemaVersion: 1, revision: 'r1', pendingBroadcastRevision: null });
  const outcome = await broadcast({ store, registry, dispatcher: fakeDispatcher() });
  assert.equal(outcome.state, 'done');
  assert.deepEqual(await store.get('state/current'), { schemaVersion: 1, revision: 'r1', pendingBroadcastRevision: null });
});

test('a claim held by another live owner is skipped; a stale or own lease is taken over', async () => {
  const { store, registry } = await registered(2);
  await store.set('broadcasts/r1', { revision: 'r1', claimedAt: NOW - 5000, state: 'sending', owner: 'other', leaseUntil: NOW + 60_000, attempts: 1, cursor: null, passComplete: false, accepted: 0, failed: 0, unregistered: 0, retryPending: 0, finishedAt: null, expiresAt: new Date(NOW + 7 * 24 * 3600_000) });
  const dispatcher = fakeDispatcher();
  const busy = await broadcast({ store, registry, dispatcher });
  assert.deepEqual({ skipped: busy.skipped, complete: busy.complete, state: busy.state }, { skipped: 'broadcast_in_progress', complete: false, state: 'sending' });
  assert.equal(dispatcher.sent.length, 0);
  const own = await broadcast({ store, registry, dispatcher, owner: 'other' });
  assert.equal(own.state, 'done');
  assert.equal(own.attempts, 2);
  assert.equal(dispatcher.sent.length, 2);
});

test('losing the claim mid-page aborts without releasing someone else\'s lease', async () => {
  const { store, registry } = await registered(3);
  const dispatcher = fakeDispatcher(async () => {
    await store.runTransaction(async (tx) => { const claim = await tx.get('broadcasts/r1'); tx.set('broadcasts/r1', { ...claim, owner: 'thief', leaseUntil: NOW + 999_999 }); });
    return accepted;
  });
  await assert.rejects(broadcast({ store, registry, dispatcher, concurrency: 1 }), /lease_lost/);
  const claim = await store.get('broadcasts/r1');
  assert.equal(claim.owner, 'thief');
  assert.equal(claim.accepted, 0);
  assert.equal(claim.cursor, null);
});

test('rejected APNs credentials abort the run and keep the lease for the resumed attempt', async () => {
  const { store, registry } = await registered(3);
  const dispatcher = fakeDispatcher(() => ({ ok: false, status: 403, reason: 'ExpiredProviderToken', unregistered: false, retryable: false }));
  await assert.rejects(broadcast({ store, registry, dispatcher, concurrency: 1 }), /apns_credentials_rejected/);
  const claim = await store.get('broadcasts/r1');
  // The attempt is given back: nothing was sent that the cap should count.
  assert.deepEqual({ state: claim.state, owner: claim.owner, cursor: claim.cursor, attempts: claim.attempts }, { state: 'sending', owner: 'me', cursor: null, attempts: 0 });
  assert.equal(claim.leaseUntil > NOW, true);
  const rotated = fakeDispatcher();
  assert.equal((await broadcast({ store, registry, dispatcher: rotated, owner: 'other' })).skipped, 'broadcast_in_progress');
  const resumed = await broadcast({ store, registry, dispatcher: rotated });
  assert.deepEqual({ state: resumed.state, attempts: resumed.attempts }, { state: 'done', attempts: 1 });
  assert.equal(rotated.sent.length, 3);
});

test('a key rejected on three consecutive ticks leaves the budget for the rotated key to send every device', async () => {
  let time = NOW;
  const { store, registry } = await registered(3, { now: () => time });
  await store.set('state/current', { schemaVersion: 1, revision: 'r1', pendingBroadcastRevision: 'r1' });
  const expired = fakeDispatcher(() => ({ ok: false, status: 403, reason: 'ExpiredProviderToken', unregistered: false, retryable: false }));
  // Ticks five minutes apart under different executions: each lease has
  // expired by the next, so each run claims afresh and is refused afresh.
  for (const owner of ['exec-1', 'exec-2', 'exec-3']) {
    await assert.rejects(broadcast({ store, registry, dispatcher: expired, owner, concurrency: 1, now: () => time }), /apns_credentials_rejected/);
    time += 300_000;
  }
  assert.equal((await store.get('broadcasts/r1')).attempts, 0);
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, 'r1');
  const rotated = fakeDispatcher();
  const outcome = await broadcast({ store, registry, dispatcher: rotated, owner: 'exec-4', now: () => time });
  assert.deepEqual({ state: outcome.state, attempts: outcome.attempts, accepted: outcome.accepted, exhausted: outcome.exhausted }, { state: 'done', attempts: 1, accepted: 3, exhausted: undefined });
  assert.deepEqual(rotated.sent.map(({ token }) => token).sort(), [tokenOf(1), tokenOf(2), tokenOf(3)]);
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, null);
});

test('a revision that becomes current again after a flip-flop starts a full pass', async () => {
  const store = memoryStore();
  let time = NOW;
  const { registry } = await registered(2, { store, now: () => time });
  const feeds = [atom(), atom([]), atom()];
  const service = new SuspensionService({ apiKey: 'key', store, now: () => time, fetchImpl: async (url) => xmlResponse(url === CAP_URL ? cap : feeds.shift()) });
  const dispatcher = fakeDispatcher();
  const sendPending = async () => {
    const pending = (await store.get('state/current')).pendingBroadcastRevision;
    return broadcastRevision({ store, registry, dispatcher, revision: pending, owner: 'me', now: () => time });
  };
  assert.equal(await service.refresh(), true);
  const r1 = service.getSnapshot().revision;
  assert.equal((await sendPending()).state, 'done');
  time += 300_001;
  assert.equal(await service.refresh(), true);
  assert.notEqual(service.getSnapshot().revision, r1);
  assert.equal((await sendPending()).state, 'done');
  time += 300_001;
  assert.equal(await service.refresh(), true);
  assert.equal(service.getSnapshot().revision, r1);
  const reset = await store.get(`broadcasts/${r1}`);
  assert.deepEqual({ state: reset.state, attempts: reset.attempts, cursor: reset.cursor, passComplete: reset.passComplete }, { state: 'pending', attempts: 0, cursor: null, passComplete: false });
  const third = await sendPending();
  assert.deepEqual({ state: third.state, attempts: third.attempts, accepted: third.accepted }, { state: 'done', attempts: 1, accepted: 2 });
  assert.equal(dispatcher.sent.length, 6);
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, null);
});
