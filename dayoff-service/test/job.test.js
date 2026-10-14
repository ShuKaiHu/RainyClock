import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { jobConfig, runJob } from '../src/job.js';
import { DeviceRegistry } from '../src/devices.js';
import { ServiceError } from '../src/errors.js';
import { cap, atom, CAP_URL, NOW, xmlResponse, memoryStore, apnsEnv } from './helpers.js';

const JOB = fileURLToPath(new URL('../src/job.js', import.meta.url));
const SECRET = 'fake-ncdr-key-value';
const baseEnv = { NCDR_API_KEY: SECRET, GOOGLE_CLOUD_PROJECT: 'demo-rc-dayoff', DAYOFF_FIRESTORE_DATABASE: 'dayoff-emulator', CLOUD_RUN_EXECUTION: 'exec-1' };
const registration = (number = 1) => ({ installationId: `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`, deviceToken: number.toString(16).padStart(64, '0'), credential: 'c'.repeat(64) });

function harness({ store = memoryStore(), time = NOW, feed = () => atom(), served = async () => ({ revision: null }) } = {}) {
  const state = { store, time, calls: [], sends: [], closes: 0, storeCloses: 0, logs: [], lines: [] };
  state.fetchImpl = async (url, options) => {
    state.calls.push(url);
    if (url === CAP_URL) return xmlResponse(cap);
    if (url.startsWith('https://dayoff.example/')) return new Response(JSON.stringify(await served()), { headers: { 'Content-Type': 'application/json' } });
    const body = feed();
    if (body instanceof Response) return body;
    if (body instanceof Error) throw body;
    return xmlResponse(body, options);
  };
  state.transport = async ({ headers }) => { state.sends.push(headers[':path'].slice('/3/device/'.length)); return state.respond?.(state.sends.length) ?? { status: 200, body: '' }; };
  state.transport.close = () => { state.closes += 1; };
  state.run = (env, extra = {}) => runJob({ env: { ...baseEnv, ...env }, store, closeStore: async () => { state.storeCloses += 1; }, fetchImpl: state.fetchImpl, transport: state.transport, now: () => state.time, log: (event) => state.logs.push(event), stdout: (line) => state.lines.push(line), ...extra });
  return state;
}

test('jobConfig validates every setting before any I/O and applies the documented defaults', async (t) => {
  assert.throws(() => jobConfig({}), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, NCDR_API_KEY: ' ' }), /invalid_configuration/);
  assert.equal(jobConfig(baseEnv).source, 'member');
  assert.equal(jobConfig({ ...baseEnv, NCDR_API_KEY: undefined, NCDR_SOURCE: 'open-data' }).source, 'open-data');
  assert.equal(jobConfig({ ...baseEnv, NCDR_API_KEY: undefined, NCDR_SOURCE: 'open-data' }).apiKey, null);
  assert.throws(() => jobConfig({ ...baseEnv, NCDR_SOURCE: 'open-data' }), /invalid_configuration/, 'a key with the open-data source is a mistake');
  assert.equal(jobConfig({ ...baseEnv, NCDR_API_KEY: undefined, NCDR_SOURCE: 'history' }).source, 'history');
  assert.throws(() => jobConfig({ ...baseEnv, NCDR_SOURCE: 'history' }), /invalid_configuration/, 'a key with the history source is a mistake');
  assert.throws(() => jobConfig({ ...baseEnv, NCDR_SOURCE: 'html' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, APNS_TEAM_ID: 'TEAM123456' }), /invalid_apns_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, APNS_PUSH_MODE: 'silent' }), /invalid_apns_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, POLL_INTERVAL_MS: '1000' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, BROADCAST_PAGE_SIZE: '10' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, LEASE_MS: '30000', LEASE_RENEW_MS: '30000' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, DAYOFF_SERVICE_URL: 'http://dayoff.example' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, DAYOFF_SERVICE_URL: 'https://dayoff.example/?x=1' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, DAYOFF_FIRESTORE_DATABASE: '(default)' }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...baseEnv, GOOGLE_CLOUD_PROJECT: 'rainyclock', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686' }), /unsafe_firestore_project/);
  const apns = await apnsEnv(t);
  assert.throws(() => jobConfig({ ...baseEnv, ...apns, APNS_PRODUCTION: undefined }), /invalid_apns_configuration/);
  const config = jobConfig({ ...baseEnv, ...apns, DAYOFF_SERVICE_URL: 'https://dayoff.example/' });
  assert.deepEqual({ pollIntervalMs: config.pollIntervalMs, requestTimeoutMs: config.requestTimeoutMs, concurrency: config.concurrency, pageSize: config.pageSize, leaseMs: config.leaseMs, leaseRenewMs: config.leaseRenewMs, runBudgetMs: config.runBudgetMs, serviceUrl: config.serviceUrl, owner: config.owner, pushMode: config.pushMode },
    { pollIntervalMs: 300_000, requestTimeoutMs: 10_000, concurrency: 16, pageSize: 200, leaseMs: 120_000, leaseRenewMs: 30_000, runBudgetMs: 420_000, serviceUrl: 'https://dayoff.example', owner: 'exec-1', pushMode: 'alert' });
  assert.equal(config.apns.production, false);
  assert.deepEqual(config.firestore, { projectId: 'demo-rc-dayoff', databaseId: 'dayoff-emulator', namespace: 'dayoff_production_v1', emulatorHost: null });
  assert.match(jobConfig({ ...baseEnv, CLOUD_RUN_EXECUTION: '' }).owner, /^[0-9a-f-]{36}$/);
  assert.equal(jobConfig(baseEnv).apns, null);
  await assert.rejects(runJob({ env: { ...baseEnv, ...apns, APNS_PRIVATE_KEY_PATH: join(apns.APNS_PRIVATE_KEY_PATH, 'missing') }, store: memoryStore() }), /invalid_apns_configuration/);
});

test('a lease held by another live execution skips the run with exit 0; its own lease is taken over', async () => {
  const job = harness();
  await job.store.set('state/lease', { owner: 'exec-0', leaseUntil: NOW + 60_000 });
  const { exitCode, summary } = await job.run({});
  assert.equal(exitCode, 0);
  assert.deepEqual({ ok: summary.ok, skipped: summary.skipped, refreshed: summary.refreshed, severity: summary.severity }, { ok: true, skipped: 'lease_held', refreshed: false, severity: 'INFO' });
  assert.equal(job.calls.length, 0);
  assert.deepEqual(await job.store.get('state/lease'), { owner: 'exec-0', leaseUntil: NOW + 60_000 });
  assert.equal(job.storeCloses, 1);
  assert.equal(job.lines.length, 1);
  const retry = await job.run({ CLOUD_RUN_EXECUTION: 'exec-0' });
  assert.equal(retry.summary.skipped, null);
  assert.equal(retry.summary.refreshed, true);
  assert.deepEqual(await job.store.get('state/lease'), { owner: null, leaseUntil: 0 });
});

test('a changed feed is committed, warmed up, broadcast to every device, and never pushed again while unchanged', async (t) => {
  // The warm-up GET is answered from the store, as the deployed service would.
  const job = harness({ served: async () => ({ revision: (await job.store.get('state/current'))?.revision ?? null }) });
  const registry = new DeviceRegistry({ store: job.store, now: () => NOW });
  await registry.register(registration(1));
  await registry.register(registration(2));
  const env = { ...await apnsEnv(t), DAYOFF_SERVICE_URL: 'https://dayoff.example' };
  // Without APNs the pointer stays; the configured run that follows sends it.
  const before = await job.run({ DAYOFF_SERVICE_URL: 'https://dayoff.example' });
  job.revision = before.summary.revision;
  assert.match(job.revision, /^[0-9a-f]{64}$/);
  assert.deepEqual({ ok: before.summary.ok, changed: before.summary.changed, broadcast: before.summary.broadcast, warmup: before.summary.warmup }, { ok: true, changed: true, broadcast: null, warmup: { status: 200, revisionMatches: true } });
  assert.equal((await job.store.get('state/current')).pendingBroadcastRevision, job.revision);
  // A success never gates the next tick (only a failure's backoff carries
  // over), so this run refreshes, finds the feed unchanged, and sends the
  // pointer the previous run left behind.
  const { exitCode, summary } = await job.run(env);
  assert.equal(exitCode, 0);
  assert.deepEqual(Object.keys(summary), ['event', 'severity', 'ok', 'owner', 'source', 'skipped', 'refreshed', 'changed', 'revision', 'noticeCount', 'errorCode', 'warmup', 'broadcast', 'durationMs']);
  assert.deepEqual({ ...summary, durationMs: 0 }, { event: 'dayoff_job', severity: 'INFO', ok: true, owner: 'exec-1', source: 'member', skipped: null, refreshed: true, changed: false, revision: job.revision, noticeCount: 1, errorCode: null, warmup: null, broadcast: { revision: job.revision, state: 'done', attempts: 1, accepted: 2, failed: 0, unregistered: 0, retryPending: 0, complete: true }, durationMs: 0 });
  assert.deepEqual(job.sends.sort(), [registration(1).deviceToken, registration(2).deviceToken]);
  assert.equal((await job.store.get('state/current')).pendingBroadcastRevision, null);
  assert.equal(job.closes, 1);
  assert.equal(job.storeCloses, 2);
  assert.deepEqual(JSON.parse(job.lines[1]), summary);
  job.time += 300_001;
  const unchanged = await job.run(env);
  assert.deepEqual({ refreshed: unchanged.summary.refreshed, changed: unchanged.summary.changed, broadcast: unchanged.summary.broadcast, warmup: unchanged.summary.warmup, skipped: unchanged.summary.skipped }, { refreshed: true, changed: false, broadcast: null, warmup: null, skipped: null });
  assert.equal(job.sends.length, 2);
  assert.equal((await job.store.get('state/current')).checkedAt, new Date(job.time).toISOString());
  assert.deepEqual((await job.store.get('state/current')).push, { configured: true, mode: 'alert' });
});

test('a source failure exits 0 with a persisted backoff; the next run skips the fetch but still resumes a pending broadcast', async (t) => {
  const job = harness();
  const env = await apnsEnv(t);
  await new DeviceRegistry({ store: job.store, now: () => NOW }).register(registration(1));
  const first = await job.run({});
  assert.equal(first.summary.changed, true);
  assert.equal(job.sends.length, 0);
  job.time += 300_001;
  const failing = harness({ store: job.store, time: job.time, feed: () => new Error(`request to https://alerts.example/?apikey=${SECRET} failed`) });
  const failed = await failing.run({});
  assert.equal(failed.exitCode, 0);
  assert.deepEqual({ ok: failed.summary.ok, severity: failed.summary.severity, errorCode: failed.summary.errorCode, refreshed: failed.summary.refreshed, skipped: failed.summary.skipped, revision: failed.summary.revision }, { ok: false, severity: 'WARNING', errorCode: 'upstream_unavailable', refreshed: false, skipped: null, revision: first.summary.revision });
  const stored = await job.store.get('state/current');
  assert.deepEqual({ failures: stored.failures, errorCode: stored.errorCode, nextAttemptAt: stored.nextAttemptAt, pending: stored.pendingBroadcastRevision }, { failures: 1, errorCode: 'upstream_unavailable', nextAttemptAt: job.time + 30_000, pending: first.summary.revision });
  const output = JSON.stringify([failing.lines, failing.logs]);
  assert.equal(output.includes(SECRET), false);
  assert.equal(output.includes('alerts.example'), false);
  job.time += 10_000;
  const resumed = await job.run(env);
  assert.equal(resumed.exitCode, 0);
  assert.deepEqual({ ok: resumed.summary.ok, skipped: resumed.summary.skipped, errorCode: resumed.summary.errorCode, state: resumed.summary.broadcast.state, accepted: resumed.summary.broadcast.accepted }, { ok: false, skipped: 'backoff', errorCode: 'upstream_unavailable', state: 'done', accepted: 1 });
  assert.equal(job.calls.length, 2);
  assert.equal(job.sends.length, 1);
  assert.equal((await job.store.get('state/current')).pendingBroadcastRevision, null);
  assert.equal(job.logs.some((event) => event.event === 'source_check_skipped'), true);
  const summaryText = JSON.stringify(job.lines);
  for (const forbidden of [SECRET, registration(1).deviceToken, registration(1).installationId, 'https://']) assert.equal(summaryText.includes(forbidden), false, forbidden);
});

test('an incomplete pass exits 1 and a later execution resumes it from the cursor', async (t) => {
  const job = harness();
  const env = { ...await apnsEnv(t), BROADCAST_PAGE_SIZE: '50' };
  const registry = new DeviceRegistry({ store: job.store, now: () => NOW });
  for (let i = 1; i <= 120; i += 1) await registry.register(registration(i));
  const controller = new AbortController();
  job.respond = () => { controller.abort(); return { status: 200, body: '' }; };
  const cancelled = await job.run(env, { signal: controller.signal });
  assert.equal(cancelled.exitCode, 1);
  assert.deepEqual({ ok: cancelled.summary.ok, severity: cancelled.summary.severity, state: cancelled.summary.broadcast.state, complete: cancelled.summary.broadcast.complete }, { ok: false, severity: 'ERROR', state: 'partial', complete: false });
  assert.equal(job.sends.length, 50);
  assert.deepEqual(await job.store.get('state/lease'), { owner: null, leaseUntil: 0 });
  job.respond = null;
  const resumed = await job.run({ ...env, CLOUD_RUN_EXECUTION: 'exec-2' });
  assert.equal(resumed.exitCode, 0);
  assert.deepEqual({ state: resumed.summary.broadcast.state, attempts: resumed.summary.broadcast.attempts, accepted: resumed.summary.broadcast.accepted }, { state: 'done', attempts: 2, accepted: 120 });
  assert.equal(new Set(job.sends).size, 120);
  assert.equal(job.sends.length, 120);
});

test('a retry-only partial pass is not a failure, and rejected credentials are', async (t) => {
  const job = harness();
  const env = await apnsEnv(t);
  await new DeviceRegistry({ store: job.store, now: () => NOW }).register(registration(1));
  job.respond = () => ({ status: 503, body: JSON.stringify({ reason: 'ServiceUnavailable' }) });
  const partial = await job.run(env);
  assert.equal(partial.exitCode, 0);
  assert.deepEqual({ ok: partial.summary.ok, state: partial.summary.broadcast.state, retryPending: partial.summary.broadcast.retryPending }, { ok: true, state: 'partial', retryPending: 1 });
  job.time += 300_001;
  job.respond = () => ({ status: 403, body: JSON.stringify({ reason: 'ExpiredProviderToken' }) });
  const rejected = await job.run(env);
  assert.equal(rejected.exitCode, 1);
  assert.deepEqual({ ok: rejected.summary.ok, severity: rejected.summary.severity, errorCode: rejected.summary.errorCode, broadcast: rejected.summary.broadcast }, { ok: false, severity: 'ERROR', errorCode: 'apns_credentials_rejected', broadcast: null });
  assert.deepEqual(await job.store.get('state/lease'), { owner: null, leaseUntil: 0 });
  assert.equal(job.closes, 2);
  // The rejected run gave its attempt back, so the retry of this execution
  // and the rotated key that follows still have the budget.
  assert.equal((await job.store.get(`broadcasts/${partial.summary.revision}`)).attempts, 1);
});

test('one failed heartbeat renewal does not lose the lease; an expired one does', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const store = memoryStore();
  let failLease = false;
  // The renewal transaction is the only one that reads state/lease while a
  // send is in flight; refusing it once stands in for a Firestore blip.
  const flaky = { ...store, runTransaction: (operation) => store.runTransaction((tx) => operation({ ...tx, get: async (path) => { if (failLease && path === 'state/lease') { failLease = false; throw new ServiceError('storage_unavailable'); } return tx.get(path); } })) };
  const job = harness({ store: flaky });
  const env = { ...await apnsEnv(t), LEASE_MS: '10000', LEASE_RENEW_MS: '1000', BROADCAST_PAGE_SIZE: '50' };
  const registry = new DeviceRegistry({ store, now: () => NOW });
  for (let i = 1; i <= 60; i += 1) await registry.register(registration(i));
  await job.run({});
  // The blip lands during the first page; the second page is only sent if
  // the run still believes it holds the lease.
  let tripped = false;
  const blip = (advanceMs) => () => { if (!tripped) { tripped = true; failLease = true; job.time += advanceMs; t.mock.timers.tick(1000); } return { status: 200, body: '' }; };
  job.respond = blip(0);
  const survived = await job.run(env);
  assert.equal(failLease, false);
  assert.deepEqual({ exitCode: survived.exitCode, state: survived.summary.broadcast.state, accepted: survived.summary.broadcast.accepted }, { exitCode: 0, state: 'done', accepted: 60 });
  assert.deepEqual(await store.get('state/lease'), { owner: null, leaseUntil: 0 });
  // With the lease expired unrenewed the run is cancelled at its checkpoint.
  const revision = survived.summary.revision;
  await store.set('state/current', { ...await store.get('state/current'), pendingBroadcastRevision: revision });
  await store.set(`broadcasts/${revision}`, { ...await store.get(`broadcasts/${revision}`), state: 'pending', attempts: 0, cursor: null, passComplete: false, accepted: 0, claimedAt: job.time });
  tripped = false;
  job.respond = blip(10_001);
  const lost = await job.run({ ...env, CLOUD_RUN_EXECUTION: 'exec-2' });
  assert.deepEqual({ exitCode: lost.exitCode, state: lost.summary.broadcast.state, accepted: lost.summary.broadcast.accepted }, { exitCode: 1, state: 'partial', accepted: 50 });
  // The document still named this execution, so it was released all the same.
  assert.deepEqual(await store.get('state/lease'), { owner: null, leaseUntil: 0 });
});

test('an unavailable store exits 1 and still closes everything', async (t) => {
  const env = await apnsEnv(t);
  const broken = { kind: 'memory-test-only', runTransaction: async () => { throw new ServiceError('storage_unavailable'); }, get: async () => { throw new ServiceError('storage_unavailable'); } };
  const job = harness({ store: broken });
  const { exitCode, summary } = await job.run(env);
  assert.equal(exitCode, 1);
  assert.deepEqual({ ok: summary.ok, severity: summary.severity, errorCode: summary.errorCode }, { ok: false, severity: 'ERROR', errorCode: 'storage_unavailable' });
  assert.equal(job.calls.length, 0);
  assert.equal(job.closes, 1);
  assert.equal(job.storeCloses, 1);
});

test('run directly with a bad environment, the Job exits 1 and prints only a failure code', () => {
  const empty = spawnSync(process.execPath, [JOB], { env: {}, encoding: 'utf8' });
  assert.equal(empty.status, 1);
  assert.equal(empty.stdout, '');
  assert.equal(empty.stderr, '{"event":"dayoff_job_failed","code":"invalid_configuration"}\n');
  const partial = spawnSync(process.execPath, [JOB], { env: { ...baseEnv, APNS_TEAM_ID: 'TEAM123456', APNS_PRIVATE_KEY_PATH: '/nonexistent/secret-path.p8' }, encoding: 'utf8' });
  assert.equal(partial.status, 1);
  assert.equal(partial.stdout, '');
  assert.equal(partial.stderr, '{"event":"dayoff_job_failed","code":"invalid_apns_configuration"}\n');
  assert.equal((empty.stdout + empty.stderr + partial.stdout + partial.stderr).includes(SECRET), false);
});
