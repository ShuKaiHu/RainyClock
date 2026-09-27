import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { serviceConfig } from '../src/server.js';
import { localConfig, localStore } from '../src/local.js';
import { createHTTPServer } from '../src/http.js';
import { createSnapshotReader } from '../src/snapshot.js';
import { DeviceRegistry } from '../src/devices.js';
import { SuspensionService } from '../src/service.js';
import { NOW, memoryStore } from './helpers.js';

const SERVER = fileURLToPath(new URL('../src/server.js', import.meta.url));
const baseEnv = { GOOGLE_CLOUD_PROJECT: 'demo-rc-dayoff', DAYOFF_FIRESTORE_DATABASE: 'dayoff-emulator' };
const registration = (number = 1) => ({ installationId: `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`, deviceToken: number.toString(16).padStart(64, '0'), credential: 'c'.repeat(64) });

async function listen(t, server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); });
  return `http://127.0.0.1:${server.address().port}`;
}

test('serviceConfig applies the documented defaults and derives push fields from non-secret env only', () => {
  const config = serviceConfig(baseEnv);
  assert.deepEqual(config, { port: 8080, host: '0.0.0.0', maxCacheAgeMs: 900_000, cacheMs: 5000, pushConfigured: false, pushMode: null, trustForwardedFor: false, firestore: { projectId: 'demo-rc-dayoff', databaseId: 'dayoff-emulator', namespace: 'dayoff_production_v1', emulatorHost: null } });
  // A mode without PUSH_CONFIGURED stays null: the phones must not be told push exists.
  assert.equal(serviceConfig({ ...baseEnv, APNS_PUSH_MODE: 'background' }).pushMode, null);
  const configured = serviceConfig({ ...baseEnv, PUSH_CONFIGURED: '1', APNS_PUSH_MODE: 'background', TRUST_PROXY: '1', PORT: '9090', HOST: '127.0.0.1', MAX_CACHE_AGE_MS: '600000', SNAPSHOT_CACHE_MS: '0', DAYOFF_NAMESPACE: 'dayoff_test_1' });
  assert.deepEqual({ ...configured, firestore: undefined }, { port: 9090, host: '127.0.0.1', maxCacheAgeMs: 600_000, cacheMs: 0, pushConfigured: true, pushMode: 'background', trustForwardedFor: true, firestore: undefined });
  assert.equal(configured.firestore.namespace, 'dayoff_test_1');
  assert.equal(serviceConfig({ ...baseEnv, PUSH_CONFIGURED: '1' }).pushMode, 'alert');
  assert.equal(serviceConfig({ ...baseEnv, PUSH_CONFIGURED: '0', TRUST_PROXY: '' }).trustForwardedFor, false);
  // Blank values from a copied .env.example mean "default", not "zero".
  assert.equal(serviceConfig({ ...baseEnv, PORT: '', MAX_CACHE_AGE_MS: ' ' }).port, 8080);
  // No NCDR key and no APNs fields are read: the service holds no secrets.
  assert.deepEqual(Object.keys(serviceConfig({ ...baseEnv, NCDR_API_KEY: 'fake-key', APNS_TEAM_ID: 'TEAM123456' })), Object.keys(config));
});

test('serviceConfig refuses what would misroute traffic or reach the wrong database', () => {
  assert.throws(() => serviceConfig({}), /unsafe_firestore_project/);
  assert.throws(() => serviceConfig({ ...baseEnv, GOOGLE_CLOUD_PROJECT: 'rainyclock', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686' }), /unsafe_firestore_project/);
  assert.throws(() => serviceConfig({ GOOGLE_CLOUD_PROJECT: 'demo-rc-dayoff' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, DAYOFF_FIRESTORE_DATABASE: '(default)' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, PUSH_CONFIGURED: 'yes' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, TRUST_PROXY: 'true' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, APNS_PUSH_MODE: 'silent' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, PORT: '70000' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, MAX_CACHE_AGE_MS: '1000' }), /invalid_configuration/);
  assert.throws(() => serviceConfig({ ...baseEnv, SNAPSHOT_CACHE_MS: '-1' }), /invalid_configuration/);
});

test('the rate limiter keys on the last X-Forwarded-For entry only when the deployment trusts the proxy', async (t) => {
  const service = { health() { return { available: false }; }, getSnapshot() { throw new Error('unused'); } };
  const trusted = await listen(t, createHTTPServer({ service, registry: new DeviceRegistry({ store: memoryStore(), now: () => NOW }), pushConfigured: true, trustForwardedFor: true, now: () => NOW }));
  const send = (base, forwarded) => fetch(base + '/v1/devices', { method: 'POST', headers: { 'Content-Type': 'application/json', ...(forwarded ? { 'X-Forwarded-For': forwarded } : {}) }, body: JSON.stringify(registration()) });
  let last;
  // Cloud Run appends the peer it saw; whatever precedes it was written by the client.
  for (let index = 0; index < 30; index += 1) last = await send(trusted, '10.0.0.1, 203.0.113.7');
  assert.equal(last.status, 200);
  assert.equal((await send(trusted, '10.0.0.1, 203.0.113.7')).status, 429);
  // The client-supplied entries before the comma never form part of the key.
  assert.equal((await send(trusted, '10.0.0.2,203.0.113.7')).status, 429);
  assert.equal((await send(trusted, '203.0.113.7')).status, 429);
  assert.equal((await send(trusted, '203.0.113.8')).status, 200);
  assert.equal((await send(trusted)).status, 200);
  // Thirty distinct spoofed leading values from one real peer share one bucket.
  for (let index = 0; index < 30; index += 1) last = await send(trusted, `198.51.100.${index}, 203.0.113.9`);
  assert.equal(last.status, 200);
  assert.equal((await send(trusted, '198.51.100.99, 203.0.113.9')).status, 429);
  // Same socket, header ignored: every request shares one bucket.
  const direct = await listen(t, createHTTPServer({ service, registry: new DeviceRegistry({ store: memoryStore(), now: () => NOW }), pushConfigured: true, now: () => NOW }));
  for (let index = 0; index < 30; index += 1) last = await send(direct, `203.0.113.${index}`);
  assert.equal(last.status, 200);
  assert.equal((await send(direct, '198.51.100.1')).status, 429);
});

test('GET /health/details exists only for a store-backed reader; /health keeps its nine keys', async (t) => {
  const store = memoryStore();
  const reader = createSnapshotReader({ store, now: () => NOW, cacheMs: 0 });
  const registry = new DeviceRegistry({ store, now: () => NOW });
  const base = await listen(t, createHTTPServer({ service: reader, registry, pushConfigured: true, pushMode: 'alert', now: () => NOW }));
  let response = await fetch(base + '/health');
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { configured: false, available: false, state: 'not_configured', errorCode: 'not_configured', lastAttemptAt: null, lastSuccessAt: null, nextAttemptAt: null, pushConfigured: true, pushMode: 'alert' });
  response = await fetch(base + '/health/details');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { configured: false, available: false, state: 'not_configured', errorCode: 'not_configured', lastAttemptAt: null, lastSuccessAt: null, nextAttemptAt: null, revision: null, checkedAt: null, noticeCount: null, ageMs: null, sourceUpdatedAt: null, job: null, source: null, lease: null, broadcast: null, storage: 'memory-test-only', serverTime: new Date(NOW).toISOString() });
  const checkedAt = new Date(NOW - 60_000).toISOString();
  await store.set('state/current', { schemaVersion: 1, revision: 'a'.repeat(64), checkedAt, sourceUpdatedAt: null, noticesJSON: '[]', noticeCount: 0, errorCode: null, failures: 0, lastAttemptAt: checkedAt, lastSuccessAt: checkedAt, nextAttemptAt: NOW + 240_000, pendingBroadcastRevision: null, push: { configured: true, mode: 'alert' }, job: null, source: null, updatedAt: checkedAt });
  response = await fetch(base + '/v1/suspensions');
  assert.equal(response.status, 200);
  assert.equal(JSON.stringify(await response.json()), JSON.stringify({ schemaVersion: 1, checkedAt, sourceUpdatedAt: null, notices: [], revision: 'a'.repeat(64) }));
  assert.equal((await (await fetch(base + '/health/details')).json()).ageMs, 60_000);
  assert.equal((await fetch(base + '/health/details', { method: 'POST' })).status, 404);
  // The fake services the receipt tests use have no details(): 404, not a crash.
  const plain = await listen(t, createHTTPServer({ service: { health() { return { available: false }; } }, registry }));
  response = await fetch(plain + '/health/details');
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: 'not_found' });
  // A reader whose store is down answers 503 with the code, never the error text.
  const outage = async () => { throw new Error('UNAVAILABLE: 14 host secret.internal'); };
  const failing = await listen(t, createHTTPServer({ service: createSnapshotReader({ store: { ...memoryStore(), get: outage, getAll: outage }, now: () => NOW }), registry }));
  response = await fetch(failing + '/health/details');
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'storage_unavailable' });
});

test('server.js started with a bad environment prints one startup_failed line with a code and exits 1', () => {
  const result = spawnSync(process.execPath, [SERVER], { env: { PATH: process.env.PATH, GOOGLE_CLOUD_PROJECT: 'rainyclock', DAYOFF_FIRESTORE_DATABASE: 'dayoff-production', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686', NCDR_API_KEY: 'fake-key-must-not-print' }, encoding: 'utf8', timeout: 20_000 });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, '');
  const lines = result.stdout.trim().split('\n');
  assert.equal(lines.length, 1);
  const line = JSON.parse(lines[0]);
  assert.deepEqual({ ...line, at: undefined }, { severity: 'ERROR', at: undefined, event: 'startup_failed', code: 'unsafe_firestore_project' });
  assert.equal(result.stdout.includes('fake-key'), false);
});

test('local mode uses the memory store unless the emulator is named, and never a real project', async () => {
  const config = localConfig({});
  assert.deepEqual(config, { source: 'member', namespace: 'local_sandbox', apiKey: null, pollIntervalMs: 300_000, maxCacheAgeMs: 900_000, requestTimeoutMs: 10_000, cacheMs: 5000, port: 8080, concurrency: 4, apns: null, pushMode: 'alert' });
  // The namespace is what the fixture source is gated on: the emulator's
  // default is the production name, so fixture needs a sandbox one there.
  const emulatorEnv = { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686', ...baseEnv };
  assert.equal(localConfig(emulatorEnv).namespace, 'dayoff_production_v1');
  assert.equal(localConfig({ ...emulatorEnv, DAYOFF_NAMESPACE: 'dayoff_sandbox_local' }).namespace, 'dayoff_sandbox_local');
  const fixture = localConfig({ ...emulatorEnv, NCDR_SOURCE: 'fixture', DAYOFF_NAMESPACE: 'dayoff_sandbox_local' });
  assert.equal(new SuspensionService({ source: fixture.source, store: memoryStore(), namespace: fixture.namespace }).configured, true);
  const production = localConfig({ ...emulatorEnv, NCDR_SOURCE: 'fixture' });
  assert.throws(() => new SuspensionService({ source: production.source, store: memoryStore(), namespace: production.namespace }), /fixture_not_allowed/);
  assert.throws(() => localConfig({ ...emulatorEnv, DAYOFF_NAMESPACE: 'bad/namespace' }), /invalid_configuration/);
  assert.throws(() => localConfig({ APNS_TEAM_ID: 'TEAM123456' }), /invalid_apns_configuration/);
  assert.throws(() => localConfig({ MAX_CACHE_AGE_MS: '60000' }), /invalid_configuration/);
  const memory = localStore({});
  assert.equal(memory.store.kind, 'memory-test-only');
  await memory.close();
  assert.throws(() => localStore({ FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686', GOOGLE_CLOUD_PROJECT: 'rainyclock', DAYOFF_FIRESTORE_DATABASE: 'dayoff-production' }), /unsafe_firestore_project/);
  const emulated = localStore({ FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686', ...baseEnv });
  assert.equal(emulated.store.kind, 'firestore');
  await emulated.close();
});
