import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { jobConfig, runJob } from '../src/job.js';
import { SuspensionService, FIXTURE_PATH, fixtureFeed, revisionFor } from '../src/service.js';
import { createSnapshotReader } from '../src/snapshot.js';
import { DeviceRegistry } from '../src/devices.js';
import { buildFixture, parseCommand, runFixtureCli, COUNTY_GEOCODES, DISTRICTS_URL } from '../src/fixture-cli.js';
import { NOW, memoryStore, apnsEnv } from './helpers.js';

const CLI = fileURLToPath(new URL('../src/fixture-cli.js', import.meta.url));
const SECRET = 'fake-ncdr-key-value';
const sandboxEnv = { GOOGLE_CLOUD_PROJECT: 'demo-rc-dayoff', DAYOFF_FIRESTORE_DATABASE: 'dayoff-emulator', DAYOFF_NAMESPACE: 'dayoff_sandbox_test', CLOUD_RUN_EXECUTION: 'exec-1' };
const productionEnv = { ...sandboxEnv, DAYOFF_NAMESPACE: 'dayoff_production_v1' };
const registration = (number = 1) => ({ installationId: `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`, deviceToken: number.toString(16).padStart(64, '0'), credential: 'c'.repeat(64) });
const districts = [{ county: '新北市', district: '板橋區' }, { county: '臺東縣', district: '蘭嶼鄉' }];

// The Job with the fixture source over the memory store: no fetch is ever
// answered, so any network call fails the test.
function harness({ store = memoryStore(), time = NOW } = {}) {
  const state = { store, time, calls: [], sends: [], logs: [], lines: [] };
  state.fetchImpl = async (url) => { state.calls.push(url); throw new Error('no network in fixture mode'); };
  state.transport = async ({ headers }) => { state.sends.push(headers[':path'].slice('/3/device/'.length)); return { status: 200, body: '' }; };
  state.transport.close = () => {};
  state.run = (env) => runJob({ env: { ...sandboxEnv, NCDR_SOURCE: 'fixture', ...env }, store, fetchImpl: state.fetchImpl, transport: state.transport, now: () => state.time, log: (event) => state.logs.push(event), stdout: (line) => state.lines.push(line) });
  return state;
}

test('the fixture source is refused outside a sandbox namespace, with a key, and without a namespace', () => {
  assert.throws(() => jobConfig({ ...productionEnv, NCDR_SOURCE: 'fixture' }), /fixture_not_allowed/);
  assert.throws(() => jobConfig({ ...sandboxEnv, NCDR_SOURCE: 'fixture', NCDR_API_KEY: SECRET }), /invalid_configuration/);
  assert.throws(() => jobConfig({ ...sandboxEnv, NCDR_SOURCE: 'fixture', DAYOFF_NAMESPACE: 'dayoff_Sandbox_v1' }), /fixture_not_allowed/, 'the marker is literal, not case-folded');
  const config = jobConfig({ ...sandboxEnv, NCDR_SOURCE: 'fixture' });
  assert.deepEqual({ source: config.source, apiKey: config.apiKey, namespace: config.firestore.namespace }, { source: 'fixture', apiKey: null, namespace: 'dayoff_sandbox_test' });
  assert.throws(() => new SuspensionService({ source: 'fixture', store: memoryStore() }), /fixture_not_allowed/);
  assert.throws(() => new SuspensionService({ source: 'fixture', store: memoryStore(), namespace: 'dayoff_production_v1' }), /fixture_not_allowed/);
  assert.equal(new SuspensionService({ source: 'fixture', store: memoryStore(), namespace: 'dayoff_sandbox_v1' }).configured, true);
});

test('a fixture change is committed, broadcast, not repeated while unchanged, and clearing it broadcasts the empty feed', async (t) => {
  const job = harness();
  const env = await apnsEnv(t);
  const registry = new DeviceRegistry({ store: job.store, now: () => NOW });
  await registry.register(registration(1));
  await registry.register(registration(2));
  // No document yet: the first run serves a legitimately empty feed, which
  // is itself the first revision.
  const empty = await job.run(env);
  assert.deepEqual({ exitCode: empty.exitCode, ok: empty.summary.ok, source: empty.summary.source, changed: empty.summary.changed, noticeCount: empty.summary.noticeCount, revision: empty.summary.revision, state: empty.summary.broadcast.state, accepted: empty.summary.broadcast.accepted }, { exitCode: 0, ok: true, source: 'fixture', changed: true, noticeCount: 0, revision: revisionFor([]), state: 'done', accepted: 2 });
  job.time += 1000;
  const document = buildFixture({ county: '新北市', district: '板橋區', now: job.time, districts });
  await job.store.set(FIXTURE_PATH, document);
  const set = await job.run(env);
  assert.deepEqual({ exitCode: set.exitCode, changed: set.summary.changed, noticeCount: set.summary.noticeCount, revision: set.summary.revision, state: set.summary.broadcast.state, accepted: set.summary.broadcast.accepted }, { exitCode: 0, changed: true, noticeCount: 1, revision: revisionFor(document.notices), state: 'done', accepted: 2 });
  assert.equal(job.sends.length, 4);
  assert.equal(job.calls.length, 0, 'fixture mode never touches the network');
  const stored = await job.store.get('state/current');
  assert.deepEqual({ source: stored.source, pending: stored.pendingBroadcastRevision, sourceUpdatedAt: stored.sourceUpdatedAt, push: stored.push }, { source: 'fixture', pending: null, sourceUpdatedAt: document.sourceUpdatedAt, push: { configured: true, mode: 'alert' } });
  assert.equal(stored.noticesJSON, JSON.stringify(document.notices));
  assert.deepEqual(await job.store.list('caps'), [], 'no CAP cache is written for a fixture');
  // The reader serves and reports the fixture exactly like a real feed.
  const reader = createSnapshotReader({ store: job.store, now: () => job.time });
  const snapshot = await reader.getSnapshot();
  assert.equal(snapshot.notices[0].description, '[停班停課通知]新北市板橋區:明天停止上班、停止上課。行政院人事行政總處。');
  assert.equal((await reader.details()).source, 'fixture');
  job.time += 60_001;
  const unchanged = await job.run(env);
  assert.deepEqual({ refreshed: unchanged.summary.refreshed, changed: unchanged.summary.changed, broadcast: unchanged.summary.broadcast }, { refreshed: true, changed: false, broadcast: null });
  assert.equal(job.sends.length, 4);
  await job.store.delete(FIXTURE_PATH);
  job.time += 60_001;
  const cleared = await job.run(env);
  assert.deepEqual({ changed: cleared.summary.changed, noticeCount: cleared.summary.noticeCount, revision: cleared.summary.revision, state: cleared.summary.broadcast.state, accepted: cleared.summary.broadcast.accepted }, { changed: true, noticeCount: 0, revision: revisionFor([]), state: 'done', accepted: 2 });
  assert.equal(job.sends.length, 6);
  const output = JSON.stringify([job.lines, job.logs]);
  for (const forbidden of [registration(1).deviceToken, registration(1).installationId, 'https://']) assert.equal(output.includes(forbidden), false, forbidden);
});

test('an invalid fixture is a failed poll: the snapshot is kept, the code and backoff are persisted, exit 0', async () => {
  const job = harness();
  const good = buildFixture({ county: '臺東縣', now: NOW, districts });
  await job.store.set(FIXTURE_PATH, good);
  const first = await job.run({});
  assert.equal(first.summary.changed, true);
  const cases = [
    [{ notices: [{ ...good.notices[0], geocodes: ['65000-1'] }], sourceUpdatedAt: good.sourceUpdatedAt }, 'invalid_fixture_notice'],
    [{ notices: [{ ...good.notices[0], description: '' }], sourceUpdatedAt: good.sourceUpdatedAt }, 'invalid_fixture_notice'],
    [{ notices: [{ ...good.notices[0], sentAt: '2026/09/28' }], sourceUpdatedAt: good.sourceUpdatedAt }, 'invalid_source_time'],
    [{ notices: [{ ...good.notices[0], id: 'not-a-dgpa-id' }], sourceUpdatedAt: good.sourceUpdatedAt }, 'invalid_fixture_notice'],
    [{ notices: [good.notices[0], good.notices[0]], sourceUpdatedAt: good.sourceUpdatedAt }, 'invalid_fixture_notice'],
    [{ notices: [good.notices[0]] }, 'invalid_fixture_document'],
    [{ notices: 'one' }, 'invalid_fixture_document'],
    [{ notices: [{ ...good.notices[0], sentAt: new Date(NOW + 600_000).toISOString() }], sourceUpdatedAt: good.sourceUpdatedAt }, 'source_time_in_future']
  ];
  for (const [document, code] of cases) {
    // fixtureFeed is clock-free; the future-dated check belongs to the poll.
    if (code !== 'source_time_in_future') assert.throws(() => fixtureFeed(document), new RegExp(code), code);
    const failing = harness({ store: job.store, time: NOW + 60_001 });
    await failing.store.set(FIXTURE_PATH, document);
    const failed = await failing.run({});
    assert.deepEqual({ exitCode: failed.exitCode, ok: failed.summary.ok, refreshed: failed.summary.refreshed, errorCode: failed.summary.errorCode, revision: failed.summary.revision }, { exitCode: 0, ok: false, refreshed: false, errorCode: code, revision: first.summary.revision }, code);
    const stored = await job.store.get('state/current');
    assert.deepEqual({ errorCode: stored.errorCode, failures: stored.failures, noticeCount: stored.noticeCount, nextAttemptAt: stored.nextAttemptAt }, { errorCode: code, failures: 1, noticeCount: 1, nextAttemptAt: NOW + 60_001 + 30_000 }, code);
    // The persisted backoff gates the next execution like any source failure.
    const gated = harness({ store: job.store, time: NOW + 60_002 });
    assert.equal((await gated.run({})).summary.skipped, 'backoff');
    await job.store.set('state/current', { ...stored, failures: 0, nextAttemptAt: 0, errorCode: null });
  }
  // A Cancel without an info block is the one bare notice the parser allows.
  const cancel = { notices: [{ id: 'dgpa.gov.tw_workSchlClos_20260928080000_i_10014_002', sentAt: good.sourceUpdatedAt, description: '', severity: '', msgType: 'Cancel', status: 'Actual', geocodes: [], references: [good.notices[0].id] }], sourceUpdatedAt: good.sourceUpdatedAt };
  assert.deepEqual(fixtureFeed(cancel).notices[0].references, [good.notices[0].id]);
  assert.deepEqual(fixtureFeed(null), { sourceUpdatedAt: null, notices: [] });
  // Key order in the document does not change the revision.
  const shuffled = { sourceUpdatedAt: good.sourceUpdatedAt, notices: [Object.fromEntries(Object.entries(good.notices[0]).reverse())] };
  assert.equal(revisionFor(fixtureFeed(shuffled).notices), revisionFor(good.notices));
});

test('buildFixture writes the DGPA wording the phone evaluator was tested against', () => {
  const now = Date.parse('2026-09-28T02:03:04Z');
  const full = buildFixture({ county: '新北市', district: '板橋區', now, districts });
  assert.deepEqual(full.notices[0], { id: 'dgpa.gov.tw_workSchlClos_20260928100304_i_65000_001', sentAt: '2026-09-28T02:03:04.000Z', description: '[停班停課通知]新北市板橋區:明天停止上班、停止上課。行政院人事行政總處。', severity: 'Extreme', msgType: 'Alert', status: 'Actual', geocodes: ['65000'], references: [] });
  assert.deepEqual(Object.keys(full), ['notices', 'sourceUpdatedAt', 'writtenAt', 'writtenBy', 'request']);
  assert.equal(full.sourceUpdatedAt, full.notices[0].sentAt);
  const wording = (options) => buildFixture({ county: '臺東縣', now, districts, ...options }).notices[0];
  assert.equal(wording({ when: 'today' }).description, '[停班停課通知]臺東縣:今天停止上班、停止上課。行政院人事行政總處。');
  assert.equal(wording({ scope: 'work' }).description, '[停班停課通知]臺東縣:明天停止上班、照常上課。行政院人事行政總處。');
  assert.equal(wording({ scope: 'school' }).description, '[停班停課通知]臺東縣:明天照常上班、停止上課。行政院人事行政總處。');
  assert.equal(wording({ dayPart: 'morning', when: 'today' }).description, '[停班停課通知]臺東縣:今天上午停止上班、停止上課。行政院人事行政總處。');
  assert.equal(wording({ scope: 'school' }).severity, 'Severe');
  assert.equal(wording({ scope: 'work' }).severity, 'Extreme');
  assert.deepEqual(wording({ district: '蘭嶼鄉', geocode: '1001416' }).geocodes, ['1001416']);
  assert.equal(wording({ district: '蘭嶼鄉', geocode: '1001416' }).id, 'dgpa.gov.tw_workSchlClos_20260928100304_i_1001416_001');
  assert.deepEqual(wording({}).geocodes, [COUNTY_GEOCODES.臺東縣]);
  assert.throws(() => buildFixture({ county: '台北市', now, districts }), /unknown_county/);
  assert.throws(() => buildFixture({ county: '新北市', district: '蘭嶼鄉', now, districts }), /unknown_district/);
  assert.throws(() => buildFixture({ county: '新北市', district: '板橋區', now }), /districts_unavailable/);
  assert.throws(() => buildFixture({ county: '新北市', now, districts, geocode: '650-00' }), /invalid_geocode/);
  assert.throws(() => buildFixture({ county: '新北市', now, districts, geocode: '650000' }), /invalid_geocode/, 'only 2, 5 or 7 digits are well-formed on the phone');
  assert.throws(() => buildFixture({ county: '新北市', now, districts, when: 'yesterday' }), /invalid_fixture_option/);
  assert.throws(() => buildFixture({ county: '新北市', now, districts, scope: 'none' }), /invalid_fixture_option/);
  assert.throws(() => buildFixture({ county: '新北市', now, districts, dayPart: 'afternoon' }), /invalid_fixture_option/);
  assert.ok(Object.values(COUNTY_GEOCODES).every((code) => /^\d{5}$/.test(code)));
});

test('parseCommand accepts the three commands and nothing else', () => {
  assert.deepEqual(parseCommand(['set', '--county', '新北市', '--district', '板橋區', '--when', 'today', '--scope', 'work', '--day-part', 'morning', '--geocode', '6500100']), { command: 'set', options: { county: '新北市', district: '板橋區', when: 'today', scope: 'work', dayPart: 'morning', geocode: '6500100' } });
  assert.deepEqual(parseCommand(['set', '--county', '新北市']).options, { county: '新北市', district: null, when: 'tomorrow', scope: 'both', dayPart: 'full', geocode: null });
  assert.equal(parseCommand(['clear']).command, 'clear');
  assert.equal(parseCommand(['show']).command, 'show');
  assert.throws(() => parseCommand([]), /invalid_fixture_command/);
  assert.throws(() => parseCommand(['set']), /invalid_fixture_command/);
  assert.throws(() => parseCommand(['delete']), /invalid_fixture_command/);
  assert.throws(() => parseCommand(['show', '--county', '新北市']), /invalid_fixture_command/);
  assert.throws(() => parseCommand(['set', '--county', '新北市', 'extra']), /invalid_fixture_command/);
  assert.throws(() => parseCommand(['set', '--county', '新北市', '--force']), /invalid_fixture_command/);
  assert.throws(() => parseCommand(['set', '--county']), /invalid_fixture_command/, 'a flag without its value');
  assert.throws(() => parseCommand(['--county', '新北市', 'set']), /invalid_fixture_command/, 'the command must come first');
  assert.throws(() => parseCommand(['--', 'set', '--county', '新北市']), /invalid_fixture_command/);
});

test('runFixtureCli validates the namespace and the notice before a store exists, then writes, shows and clears', async () => {
  const store = memoryStore();
  let opened = 0;
  const createStore = () => { opened += 1; return { store, close: async () => {} }; };
  await assert.rejects(runFixtureCli({ argv: ['set', '--county', '新北市'], env: productionEnv, createStore }), /fixture_not_allowed/);
  await assert.rejects(runFixtureCli({ argv: ['set', '--county', '火星市'], env: sandboxEnv, createStore }), /unknown_county/);
  await assert.rejects(runFixtureCli({ argv: ['set', '--county', '新北市', '--district', '板橋區'], env: sandboxEnv, createStore, districtsUrl: new URL('file:///nonexistent/districts.json') }), /districts_unavailable/);
  await assert.rejects(runFixtureCli({ argv: ['set', '--county', '新北市'], env: { ...sandboxEnv, GOOGLE_CLOUD_PROJECT: 'rainyclock', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686' }, createStore }), /unsafe_firestore_project/);
  assert.equal(opened, 0);
  // The shipped district table is the real lookup; a district that exists
  // there is accepted with the county code by default.
  const set = await runFixtureCli({ argv: ['set', '--county', '新北市', '--district', '板橋區'], env: sandboxEnv, now: () => NOW, createStore });
  assert.deepEqual({ event: set.event, command: set.command, namespace: set.namespace, path: set.path, geocodes: set.document.notices[0].geocodes }, { event: 'dayoff_fixture', command: 'set', namespace: 'dayoff_sandbox_test', path: FIXTURE_PATH, geocodes: ['65000'] });
  assert.deepEqual(await store.get(FIXTURE_PATH), set.document);
  assert.deepEqual((await runFixtureCli({ argv: ['show'], env: sandboxEnv, createStore })).document, set.document);
  assert.equal((await runFixtureCli({ argv: ['clear'], env: sandboxEnv, createStore })).document, null);
  assert.equal(await store.get(FIXTURE_PATH), null);
  assert.equal((await runFixtureCli({ argv: ['show'], env: sandboxEnv, createStore })).document, null);
  assert.equal(opened, 4);
  assert.equal(DISTRICTS_URL.pathname.endsWith('/RainyClock/Resources/taiwan-districts.json'), true);
});

test('runFixtureCli gives the store a logger that reports the gRPC code and nothing else', async () => {
  const lines = [];
  const failing = (env, { log }) => {
    const store = memoryStore();
    return { store: { ...store, set: async () => { log({ severity: 'ERROR', event: 'storage_failure', grpcCode: 7, path: 'dayoffNamespaces/x/fixture/current' }); throw new Error('storage_unavailable'); } }, close: async () => {} };
  };
  await assert.rejects(runFixtureCli({ argv: ['set', '--county', '新北市'], env: sandboxEnv, now: () => NOW, createStore: failing, stderr: (line) => lines.push(line) }));
  assert.deepEqual(lines, ['{"event":"storage_failure","grpcCode":7}\n']);
});

test('run directly with a bad environment, the CLI exits 1 and prints only a failure code', () => {
  const secrets = { NCDR_API_KEY: SECRET, APNS_KEY_ID: 'KEY1234567' };
  const empty = spawnSync(process.execPath, [CLI, 'set', '--county', '新北市'], { env: secrets, encoding: 'utf8' });
  assert.equal(empty.status, 1);
  assert.equal(empty.stdout, '');
  assert.equal(empty.stderr, '{"event":"dayoff_fixture_failed","code":"unsafe_firestore_project"}\n');
  const production = spawnSync(process.execPath, [CLI, 'clear'], { env: { ...secrets, ...productionEnv }, encoding: 'utf8' });
  assert.equal(production.status, 1);
  assert.equal(production.stderr, '{"event":"dayoff_fixture_failed","code":"fixture_not_allowed"}\n');
  const command = spawnSync(process.execPath, [CLI, 'drop', '--county', '新北市'], { env: { ...secrets, ...sandboxEnv }, encoding: 'utf8' });
  assert.equal(command.status, 1);
  assert.equal(command.stderr, '{"event":"dayoff_fixture_failed","code":"invalid_fixture_command"}\n');
  // A mistyped flag is the operator's mistake, not a crash.
  const flag = spawnSync(process.execPath, [CLI, 'set', '--county', '新北市', '--dayPart', 'morning'], { env: { ...secrets, ...sandboxEnv }, encoding: 'utf8' });
  assert.equal(flag.status, 1);
  assert.equal(flag.stderr, '{"event":"dayoff_fixture_failed","code":"invalid_fixture_command"}\n');
  const output = empty.stdout + empty.stderr + production.stdout + production.stderr + command.stdout + command.stderr + flag.stdout + flag.stderr;
  for (const forbidden of [SECRET, 'KEY1234567', 'demo-rc-dayoff', 'dayoff-emulator']) assert.equal(output.includes(forbidden), false, forbidden);
});

test('the operator token replaces stale ADC for laptop tools only, and is never printed', async () => {
  const { operatorAuthClient } = await import('../src/runtime.js');
  assert.equal(await operatorAuthClient({}), undefined);
  assert.equal(await operatorAuthClient({ DAYOFF_ACCESS_TOKEN: '  ' }), undefined);
  assert.equal(await operatorAuthClient({ DAYOFF_ACCESS_TOKEN: 'ya29.fake', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686' }), undefined, 'the emulator needs no token');
  const client = await operatorAuthClient({ DAYOFF_ACCESS_TOKEN: 'ya29.fake-operator-token' });
  assert.equal(client.credentials.access_token, 'ya29.fake-operator-token');

  const handed = [];
  const lines = [];
  const store = memoryStore();
  const createStore = (_env, options) => { handed.push(options.authClient); return { store, close: async () => {} }; };
  const env = { ...sandboxEnv, DAYOFF_ACCESS_TOKEN: 'ya29.fake-operator-token' };
  const result = await runFixtureCli({ argv: ['set', '--county', '新北市', '--district', '板橋區'], env, now: () => NOW, createStore, stderr: (line) => lines.push(line) });
  assert.equal(handed[0].credentials.access_token, 'ya29.fake-operator-token');
  assert.equal(JSON.stringify(result).includes('ya29'), false);
  assert.equal(lines.join('').includes('ya29'), false);
  await runFixtureCli({ argv: ['show'], env: sandboxEnv, createStore });
  assert.equal(handed[1], undefined, 'without a token the SDK falls back to its own credentials');
});
