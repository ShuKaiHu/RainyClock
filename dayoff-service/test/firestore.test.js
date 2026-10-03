import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Firestore } from '@google-cloud/firestore';
import { createFirestoreStore } from '../src/store.js';
import { firestoreConfiguration, createStoreFromEnv } from '../src/runtime.js';
import { DeviceRegistry } from '../src/devices.js';
import { SuspensionService, revisionFor } from '../src/service.js';
import { createSnapshotReader } from '../src/snapshot.js';
import { broadcastRevision } from '../src/broadcast.js';
import { runJob } from '../src/job.js';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { FIXTURE_PATH } from '../src/service.js';
import { cap, atom, CAP_ID, CAP_URL, NOW, xmlResponse, apnsEnv } from './helpers.js';

// The memory store serialises transactions; these tests run the same code
// against real Firestore transactions, where two callers can read the same
// document before either commits and the SDK reruns whoever loses (the
// emulator logs a "Transaction lock timeout" warning for each rerun; that is
// the contention under test). Each test owns a random namespace inside the
// demo project and removes it.
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;
const options = { skip: !EMULATOR && 'FIRESTORE_EMULATOR_HOST is not set' };
const SECRET = 'fake-ncdr-key-value';
const installationId = (number) => `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`;
const tokenOf = (number) => number.toString(16).padStart(64, '0');
const registration = (number) => ({ installationId: installationId(number), deviceToken: tokenOf(number), credential: 'c'.repeat(64) });
const identity = { installationId: installationId(1), credential: 'c'.repeat(64) };
const accepted = { ok: true, status: 200, unregistered: false, retryable: false };
const feed = async (url) => xmlResponse(url === CAP_URL ? cap : atom());

// Resolved by whichever of two racing calls finishes first, so the other
// can be held at its next network step until the loser's verdict is in.
// The timeout only matters when both win, which is the failure under test.
function firstFinished() {
  let settle;
  const done = new Promise((resolve) => { settle = resolve; });
  const timer = new Promise((resolve) => setTimeout(resolve, 5000).unref());
  return { settle, wait: () => Promise.race([done, timer]) };
}

// firestoreConfiguration refuses a project outside demo- before a client
// exists, so this helper cannot be pointed at a real database by mistake.
async function withEmulator(work, prefix = 'dayoff_test_') {
  const env = { GOOGLE_CLOUD_PROJECT: 'demo-rc-dayoff', DAYOFF_FIRESTORE_DATABASE: 'dayoff-emulator', DAYOFF_NAMESPACE: `${prefix}${randomUUID().replaceAll('-', '')}`, FIRESTORE_EMULATOR_HOST: EMULATOR };
  const { projectId, databaseId, namespace, emulatorHost } = firestoreConfiguration(env);
  const firestore = new Firestore({ projectId, databaseId, host: emulatorHost, ssl: false });
  try {
    return await work({ env, store: createFirestoreStore({ firestore, namespace }) });
  } finally {
    await firestore.recursiveDelete(firestore.doc(`dayoffNamespaces/${namespace}`));
    await firestore.terminate();
  }
}

test('Firestore: the suite refuses a project that is not demo- before opening a client', options, () => {
  assert.throws(() => createStoreFromEnv({ GOOGLE_CLOUD_PROJECT: 'rainyclock', DAYOFF_FIRESTORE_DATABASE: 'dayoff-emulator', FIRESTORE_EMULATOR_HOST: EMULATOR }), /unsafe_firestore_project/);
});

test('Firestore: the commit needs the lease it was given, keeps noticesJSON byte for byte, and writes Dates only for expiresAt', options, () => withEmulator(async ({ store }) => {
  let time = NOW;
  await store.set('state/lease', { owner: 'other', leaseUntil: NOW + 60_000 });
  const stale = new SuspensionService({ apiKey: SECRET, store, owner: 'me', fetchImpl: feed, now: () => time });
  await assert.rejects(stale.refresh(), /lease_lost/);
  assert.equal(await store.get('state/current'), null);
  assert.deepEqual(await store.list('caps'), []);
  await store.set('state/lease', { owner: 'me', leaseUntil: NOW + 60_000 });
  const service = new SuspensionService({ apiKey: SECRET, store, owner: 'me', fetchImpl: feed, now: () => time });
  assert.equal(await service.refresh(), true);
  const snapshot = service.getSnapshot();
  const stored = await store.get('state/current');
  assert.equal(stored.noticesJSON, JSON.stringify(snapshot.notices));
  assert.equal(revisionFor(JSON.parse(stored.noticesJSON)), stored.revision);
  assert.equal(stored.revision, snapshot.revision);
  assert.equal(stored.checkedAt, new Date(NOW).toISOString());
  assert.equal(stored.pendingBroadcastRevision, stored.revision);
  assert.deepEqual(stored.job, { owner: 'me', finishedAt: new Date(NOW).toISOString(), durationMs: 0, code: null, changed: true });
  const claim = await store.get(`broadcasts/${stored.revision}`);
  assert.deepEqual({ state: claim.state, claimedAt: claim.claimedAt, attempts: claim.attempts }, { state: 'pending', claimedAt: NOW, attempts: 0 });
  assert.ok(claim.expiresAt instanceof Date);
  const [capDoc] = await store.getAll([`caps/${CAP_ID}`]);
  assert.equal(capDoc.xml, cap);
  assert.ok(capDoc.expiresAt instanceof Date);
  assert.equal(typeof capDoc.storedAt, 'string');
  // The reader serves the stored string, so the phone sees the same bytes
  // the poller hashed.
  const reader = createSnapshotReader({ store, now: () => time });
  assert.equal(JSON.stringify(await reader.getSnapshot()), JSON.stringify(snapshot));
  assert.equal((await reader.health()).state, 'ready');
  // A later process reuses the CAP from Firestore and finds nothing changed.
  time += 300_001;
  const calls = [];
  const next = new SuspensionService({ apiKey: SECRET, store, owner: 'me', fetchImpl: async (url) => { calls.push(url); return feed(url); }, now: () => time });
  await next.initialize();
  assert.equal(await next.refresh(), true);
  assert.equal(calls.length, 1);
  assert.equal(calls.includes(CAP_URL), false);
  const after = await store.get('state/current');
  assert.deepEqual({ revision: after.revision, checkedAt: after.checkedAt, changed: after.job.changed, pending: after.pendingBroadcastRevision }, { revision: stored.revision, checkedAt: new Date(time).toISOString(), changed: false, pending: stored.revision });
}));

test('Firestore: a burst of new registrations below the cap all succeed without contending; the cap holds in sequence', options, () => withEmulator(async ({ store }) => {
  let time = NOW;
  const registry = new DeviceRegistry({ store, now: () => time, maxDevices: 8 });
  await registry.register(registration(1));
  await registry.register(registration(2));
  // The cap is counted outside the transaction, so concurrent creates do not
  // invalidate each other's reads and none is rerun into a 503.
  const results = await Promise.all([3, 4, 5, 6].map((number) => registry.register(registration(number))));
  assert.deepEqual(results, [{ created: true }, { created: true }, { created: true }, { created: true }]);
  assert.equal(await store.count('devices'), 6);
  assert.equal(registry.pendingWrites, 0);
  await registry.register(registration(7));
  await registry.register(registration(8));
  await assert.rejects(registry.register(registration(9)), /device_registry_full/);
  assert.equal(await store.count('devices'), 8);
  // An expired registration frees its slot before the TTL policy gets to it.
  time += 91 * 24 * 3600_000;
  assert.deepEqual(await registry.register(registration(9)), { created: true });
  assert.equal((await registry.tokens()).length, 1);
}));

test('Firestore: a 410 racing a re-registration never removes the newer registration', options, () => withEmulator(async ({ store }) => {
  let time = NOW - 5000;
  const registry = new DeviceRegistry({ store, now: () => time });
  await registry.register(registration(1));
  time = NOW;
  for (let round = 0; round < 3; round += 1) {
    await Promise.all([registry.removeUnregistered(tokenOf(1), NOW - 1000), registry.register(registration(1))]);
    assert.equal((await store.get(`devices/${installationId(1)}`)).updatedAt, NOW, `round ${round}`);
  }
  assert.deepEqual(await registry.tokens(), [tokenOf(1)]);
  // A 410 dated at or after the registration, or with no date, removes it.
  await registry.removeUnregistered(tokenOf(1), NOW - 1);
  assert.deepEqual(await registry.tokens(), [tokenOf(1)]);
  await registry.removeUnregistered(tokenOf(1), NOW);
  assert.deepEqual(await registry.tokens(), []);
  await registry.register(registration(1));
  await registry.removeUnregistered(tokenOf(1), undefined);
  assert.deepEqual(await registry.tokens(), []);
}));

test('Firestore: concurrent receipts serialise to [true, false] and the newest one is kept', options, () => withEmulator(async ({ store }) => {
  const registry = new DeviceRegistry({ store, now: () => NOW });
  await registry.register(registration(1));
  const older = { revision: 'b'.repeat(64), checkedAt: new Date(NOW - 60_000).toISOString(), appliedAt: new Date(NOW).toISOString(), result: 'applied' };
  const newer = { ...older, checkedAt: new Date(NOW - 20_000).toISOString(), appliedAt: new Date(NOW + 20_000).toISOString(), result: 'no_alarm' };
  // The older receipt is submitted once the newer one has read the device
  // but before it has committed, so the older transaction is the one that
  // reads stale data and is rerun by the SDK.
  let read;
  const seen = new Promise((resolve) => { read = resolve; });
  const observed = { ...store, runTransaction: (operation) => store.runTransaction((tx) => operation({ ...tx, get: async (path) => { const doc = await tx.get(path); read(); return doc; } })) };
  const first = new DeviceRegistry({ store: observed, now: () => NOW }).recordReceipt({ ...identity, ...newer });
  await seen;
  const second = registry.recordReceipt({ ...identity, ...older });
  assert.deepEqual(await Promise.all([first, second]), [{ recorded: true }, { recorded: false }]);
  assert.deepEqual(await registry.receipt(identity), newer);
  assert.equal((await store.get(`devices/${installationId(1)}`)).expiresAt instanceof Date, true);
}));

test('Firestore: two senders racing one claim: one sends every device, the other reports broadcast_in_progress', options, () => withEmulator(async ({ store }) => {
  const registry = new DeviceRegistry({ store, now: () => NOW });
  for (let number = 1; number <= 3; number += 1) await registry.register(registration(number));
  await store.set('state/current', { schemaVersion: 1, revision: 'r1', pendingBroadcastRevision: 'r1' });
  const race = firstFinished();
  const sent = [];
  const dispatcher = { async send(token) { await race.wait(); sent.push(token); return accepted; }, close() {} };
  const attempt = (owner) => broadcastRevision({ store, registry, dispatcher, revision: 'r1', owner, concurrency: 2, pageSize: 50, now: () => NOW }).finally(race.settle);
  const outcomes = await Promise.all([attempt('a'), attempt('b')]);
  // The loser normally finds the lease held. When the emulator retries the
  // contended claim for longer than the gate's 5 s fallback, the winner has
  // already finished and the loser finds the claim done instead. Both are the
  // correct answer to the race: one pass, every device exactly once.
  const skipped = outcomes.map(({ skipped }) => skipped).sort();
  assert.ok(['broadcast_in_progress', 'done'].includes(skipped[0]) && skipped[1] === undefined, JSON.stringify(skipped));
  const winner = outcomes.find(({ skipped }) => !skipped);
  assert.deepEqual({ state: winner.state, attempts: winner.attempts, accepted: winner.accepted, complete: winner.complete }, { state: 'done', attempts: 1, accepted: 3, complete: true });
  assert.deepEqual(sent.sort(), [tokenOf(1), tokenOf(2), tokenOf(3)]);
  const claim = await store.get('broadcasts/r1');
  assert.deepEqual({ state: claim.state, owner: claim.owner, leaseUntil: claim.leaseUntil, passComplete: claim.passComplete }, { state: 'done', owner: null, leaseUntil: 0, passComplete: true });
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, null);
}));

test('Firestore: a full Job run commits, broadcasts and clears the pointer; an overlapping execution is refused', options, (t) => withEmulator(async ({ env, store }) => {
  const registry = new DeviceRegistry({ store, now: () => NOW });
  await registry.register(registration(1));
  await registry.register(registration(2));
  const jobEnv = { ...env, ...await apnsEnv(t), NCDR_API_KEY: SECRET };
  const sends = [];
  const summaries = [];
  const transport = async ({ headers }) => { sends.push(headers[':path'].slice('/3/device/'.length)); return { status: 200, body: '' }; };
  transport.close = () => {};
  // The Job builds its own client from the environment here, exactly as the
  // deployed entrypoint does; the winner's feed fetch waits for the loser's
  // verdict so the loser cannot arrive after the lease has been released.
  const race = firstFinished();
  const fetchImpl = async (url) => { if (url !== CAP_URL) await race.wait(); return feed(url); };
  const run = (execution) => runJob({ env: { ...jobEnv, CLOUD_RUN_EXECUTION: execution }, fetchImpl, transport, now: () => NOW, log: () => {}, stdout: (line) => summaries.push(JSON.parse(line)) }).finally(race.settle);
  const results = await Promise.all([run('exec-a'), run('exec-b')]);
  assert.deepEqual(results.map(({ exitCode }) => exitCode), [0, 0]);
  assert.deepEqual(results.map(({ summary }) => summary.skipped).sort(), ['lease_held', null].sort());
  const winner = results.find(({ summary }) => summary.skipped === null).summary;
  assert.deepEqual({ ok: winner.ok, refreshed: winner.refreshed, changed: winner.changed, noticeCount: winner.noticeCount, errorCode: winner.errorCode, broadcast: winner.broadcast }, { ok: true, refreshed: true, changed: true, noticeCount: 1, errorCode: null, broadcast: { revision: winner.revision, state: 'done', attempts: 1, accepted: 2, failed: 0, unregistered: 0, retryPending: 0, complete: true } });
  assert.deepEqual(sends.sort(), [tokenOf(1), tokenOf(2)]);
  assert.equal(summaries.length, 2);
  const stored = await store.get('state/current');
  assert.deepEqual({ revision: stored.revision, pending: stored.pendingBroadcastRevision, changed: stored.job.changed, owner: stored.job.owner, push: stored.push }, { revision: winner.revision, pending: null, changed: true, owner: winner.owner, push: { configured: true, mode: 'alert' } });
  const claim = await store.get(`broadcasts/${winner.revision}`);
  assert.deepEqual({ state: claim.state, owner: claim.owner, attempts: claim.attempts, claimedAt: claim.claimedAt, accepted: claim.accepted }, { state: 'done', owner: null, attempts: 1, claimedAt: NOW, accepted: 2 });
  assert.deepEqual(await store.get('state/lease'), { owner: null, leaseUntil: 0 });
  const reader = createSnapshotReader({ store, now: () => NOW });
  assert.equal((await reader.getSnapshot()).revision, winner.revision);
  const details = await reader.details();
  assert.deepEqual({ state: details.state, broadcast: details.broadcast.state, storage: details.storage }, { state: 'ready', broadcast: 'done', storage: 'firestore' });
  // Unchanged feed on the next tick: refreshed, nothing pushed, pointer stays clear.
  const again = await runJob({ env: { ...jobEnv, CLOUD_RUN_EXECUTION: 'exec-c' }, fetchImpl: feed, transport, now: () => NOW + 300_001, log: () => {}, stdout: () => {} });
  assert.deepEqual({ exitCode: again.exitCode, refreshed: again.summary.refreshed, changed: again.summary.changed, broadcast: again.summary.broadcast }, { exitCode: 0, refreshed: true, changed: false, broadcast: null });
  assert.equal(sends.length, 2);
  assert.equal((await store.get('state/current')).checkedAt, new Date(NOW + 300_001).toISOString());
}));

test('Firestore: the fixture CLI writes a sandbox notice and a fixture-mode Job run broadcasts it end to end', options, (t) => withEmulator(async ({ env, store }) => {
  // Unlike its neighbours this test cannot run on NOW: the CLI stamps sentAt
  // with the wall clock, so the Job does too, and a device registered on a
  // frozen date would age past the 90-day TTL and silently stop receiving.
  const registry = new DeviceRegistry({ store, now: Date.now });
  await registry.register(registration(1));
  // The CLI is run as the operator runs it: its own process, its own client
  // built from the environment, a real Firestore write.
  const cli = spawnSync(process.execPath, [fileURLToPath(new URL('../src/fixture-cli.js', import.meta.url)), 'set', '--county', '新北市', '--district', '板橋區', '--when', 'today'], { env: { ...env, PATH: process.env.PATH }, encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  const written = JSON.parse(cli.stdout);
  assert.deepEqual({ event: written.event, command: written.command, namespace: written.namespace }, { event: 'dayoff_fixture', command: 'set', namespace: env.DAYOFF_NAMESPACE });
  assert.deepEqual(await store.get(FIXTURE_PATH), written.document);
  const sends = [];
  const transport = async ({ headers }) => { sends.push(headers[':path'].slice('/3/device/'.length)); return { status: 200, body: '' }; };
  transport.close = () => {};
  const fetchImpl = async () => { throw new Error('fixture mode must not fetch'); };
  // The CLI stamped sentAt with the wall clock, so the Job runs on it too:
  // a frozen NOW would be days behind and the poll would reject the notice
  // as future-dated, exactly as it should.
  const jobEnv = { ...env, ...await apnsEnv(t), NCDR_SOURCE: 'fixture', CLOUD_RUN_EXECUTION: 'exec-fixture' };
  const first = await runJob({ env: jobEnv, fetchImpl, transport, now: Date.now, log: () => {}, stdout: () => {} });
  assert.deepEqual({ exitCode: first.exitCode, ok: first.summary.ok, source: first.summary.source, changed: first.summary.changed, noticeCount: first.summary.noticeCount, revision: first.summary.revision, broadcast: first.summary.broadcast }, { exitCode: 0, ok: true, source: 'fixture', changed: true, noticeCount: 1, revision: revisionFor(written.document.notices), broadcast: { revision: first.summary.revision, state: 'done', attempts: 1, accepted: 1, failed: 0, unregistered: 0, retryPending: 0, complete: true } });
  assert.deepEqual(sends, [tokenOf(1)]);
  const reader = createSnapshotReader({ store, now: Date.now });
  assert.equal((await reader.getSnapshot()).notices[0].description, '[停班停課通知]新北市板橋區:今天停止上班、停止上課。行政院人事行政總處。');
  assert.deepEqual(await store.list('caps'), []);
  assert.equal((await reader.details()).source, 'fixture');
  // The same fixture again is unchanged; clearing it is a new (empty) revision.
  const again = await runJob({ env: { ...jobEnv, CLOUD_RUN_EXECUTION: 'exec-fixture-2' }, fetchImpl, transport, now: Date.now, log: () => {}, stdout: () => {} });
  assert.deepEqual({ changed: again.summary.changed, broadcast: again.summary.broadcast }, { changed: false, broadcast: null });
  const cleared = spawnSync(process.execPath, [fileURLToPath(new URL('../src/fixture-cli.js', import.meta.url)), 'clear'], { env: { ...env, PATH: process.env.PATH }, encoding: 'utf8' });
  assert.equal(cleared.status, 0, cleared.stderr);
  assert.equal(await store.get(FIXTURE_PATH), null);
  const empty = await runJob({ env: { ...jobEnv, CLOUD_RUN_EXECUTION: 'exec-fixture-3' }, fetchImpl, transport, now: Date.now, log: () => {}, stdout: () => {} });
  assert.deepEqual({ changed: empty.summary.changed, noticeCount: empty.summary.noticeCount, revision: empty.summary.revision, accepted: empty.summary.broadcast.accepted }, { changed: true, noticeCount: 0, revision: revisionFor([]), accepted: 1 });
  assert.equal(sends.length, 2);
}, 'dayoff_sandbox_test_'));

test('Firestore: a production-looking namespace refuses the fixture source before any document is touched', options, () => withEmulator(async ({ env, store }) => {
  await assert.rejects(runJob({ env: { ...env, NCDR_SOURCE: 'fixture' }, store, log: () => {}, stdout: () => {} }), /fixture_not_allowed/);
  assert.equal(await store.get('state/lease'), null);
  assert.equal(await store.get('state/current'), null);
}));
