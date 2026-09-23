import test from 'node:test';
import assert from 'node:assert/strict';
import { FieldPath, Timestamp } from '@google-cloud/firestore';
import { ServiceError } from '../src/errors.js';
import { createFirestoreStore, createMemoryStore, validatePath } from '../src/store.js';
import { createStoreFromEnv, firestoreConfiguration } from '../src/runtime.js';
import { memoryStore } from './helpers.js';

const seeded = async (rows) => {
  const store = memoryStore();
  for (const [path, data] of Object.entries(rows)) await store.set(path, data);
  return store;
};

test('paths: even segments name a document, odd a collection, and no segment may be empty, "." or ".."', async () => {
  const store = memoryStore();
  assert.equal(store.kind, 'memory-test-only');
  assert.equal(validatePath('state/current', true), 'state/current');
  assert.equal(validatePath('broadcasts/r1/retries', false), 'broadcasts/r1/retries');
  for (const path of ['state', 'state/current/retries', '', 'state//current', 'state/.', '../current', 42]) assert.throws(() => validatePath(path, true), /invalid_store_path/);
  for (const path of ['state/current', 'devices/id/receipt/x']) assert.throws(() => validatePath(path, false), /invalid_store_path/);
  await assert.rejects(store.get('state'), /invalid_store_path/);
  await assert.rejects(store.set('state/current/extra', { a: 1 }), /invalid_store_path/);
  await assert.rejects(store.list('state/current'), /invalid_store_path/);
  await assert.rejects(store.count('state/current'), /invalid_store_path/);
  await assert.rejects(store.delete('state'), /invalid_store_path/);
  await assert.rejects(store.getAll(['state/current', 'state']), /invalid_store_path/);
  for (const data of [null, 'text', 7, ['a']]) await assert.rejects(store.set('state/current', data), /invalid_store_document/);
  assert.equal(await store.get('state/current'), null);
});

test('memory store: a transaction cannot read after it has written, and a failed transaction leaves nothing behind', async () => {
  const store = await seeded({ 'state/current': { revision: 'a' } });
  await assert.rejects(store.runTransaction(async (tx) => { tx.set('state/current', { revision: 'b' }); await tx.get('state/current'); }), /transaction_read_after_write/);
  await assert.rejects(store.runTransaction(async (tx) => { tx.delete('state/current'); await tx.list('state'); }), /transaction_read_after_write/);
  await assert.rejects(store.runTransaction(async (tx) => { tx.set('devices/a', { n: 1 }); await tx.count('devices'); }), /transaction_read_after_write/);
  await assert.rejects(store.runTransaction(async (tx) => { tx.set('devices/a', { n: 1 }); await tx.getAll(['devices/a']); }), /transaction_read_after_write/);
  const failure = new ServiceError('lease_lost');
  await assert.rejects(store.runTransaction(async (tx) => { await tx.get('state/current'); tx.set('state/current', { revision: 'c' }); throw failure; }), (error) => error === failure);
  assert.deepEqual(await store.get('state/current'), { revision: 'a' });
  assert.deepEqual(store.dump(), { 'state/current': { revision: 'a' } });
});

test('memory store: reads see the committed state, writes replace whole documents, and results come back from the transaction', async () => {
  const store = await seeded({ 'devices/a': { token: '1', receipt: { r: 1 } } });
  const outcome = await store.runTransaction(async (tx) => {
    const old = await tx.get('devices/a');
    tx.set('devices/a', { token: '2' });
    tx.set('devices/b', { token: '3' });
    tx.delete('devices/missing');
    return { created: old === null, previous: old.token };
  });
  assert.deepEqual(outcome, { created: false, previous: '1' });
  assert.deepEqual(await store.get('devices/a'), { token: '2' });
  assert.deepEqual(await store.getAll(['devices/b', 'devices/none', 'devices/a']), [{ token: '3' }, null, { token: '2' }]);
  assert.deepEqual(await store.getAll([]), []);
  await store.delete('devices/a');
  assert.equal(await store.get('devices/a'), null);
  await store.delete('devices/a');
  assert.equal(await store.count('devices'), 1);
});

test('memory store: where supports ==, <=, < and >, skips documents without the field, and rejects anything else', async () => {
  const store = await seeded({
    'devices/a': { token: 't1', updatedAt: 10 },
    'devices/b': { token: 't2', updatedAt: 20 },
    'devices/c': { token: 't1', updatedAt: 30 },
    'devices/d': { token: 't3' }
  });
  const ids = async (options) => (await store.list('devices', options)).map(({ id }) => id);
  assert.deepEqual(await ids({ where: [{ field: 'token', op: '==', value: 't1' }] }), ['a', 'c']);
  assert.deepEqual(await ids({ where: [{ field: 'updatedAt', op: '<=', value: 20 }] }), ['a', 'b']);
  assert.deepEqual(await ids({ where: [{ field: 'updatedAt', op: '<', value: 20 }] }), ['a']);
  assert.deepEqual(await ids({ where: [{ field: 'updatedAt', op: '>', value: 10 }] }), ['b', 'c']);
  assert.deepEqual(await ids({ where: [{ field: 'token', op: '==', value: 't1' }, { field: 'updatedAt', op: '>', value: 10 }] }), ['c']);
  assert.deepEqual(await ids({ where: [{ field: 'token', op: '==', value: 'none' }] }), []);
  assert.equal(await store.count('devices', { where: [{ field: 'token', op: '==', value: 't1' }] }), 2);
  assert.equal(await store.count('devices'), 4);
  assert.equal(await store.count('broadcasts'), 0);
  await assert.rejects(store.list('devices', { where: [{ field: 'token', op: '!=', value: 't1' }] }), /invalid_store_query/);
  await assert.rejects(store.list('devices', { where: [{ field: 'token', op: 'in', value: ['t1'] }] }), /invalid_store_query/);
  await assert.rejects(store.count('devices', { where: [{ field: 'token', op: '>=', value: 't1' }] }), /invalid_store_query/);
});

test('memory store: list is ordered by id, pages with startAfter and limit, and only lists direct children', async () => {
  const store = await seeded({
    'devices/b': { n: 2 }, 'devices/a': { n: 1 }, 'devices/d': { n: 4 }, 'devices/c': { n: 3 },
    'broadcasts/r1/retries/x': { n: 9 }, 'broadcasts/r1': { n: 8 }
  });
  assert.deepEqual(await store.list('devices'), [
    { id: 'a', path: 'devices/a', data: { n: 1 } }, { id: 'b', path: 'devices/b', data: { n: 2 } },
    { id: 'c', path: 'devices/c', data: { n: 3 } }, { id: 'd', path: 'devices/d', data: { n: 4 } }
  ]);
  const ids = async (options) => (await store.list('devices', options)).map(({ id }) => id);
  assert.deepEqual(await ids({ orderByName: true, limit: 2 }), ['a', 'b']);
  assert.deepEqual(await ids({ orderByName: true, startAfter: 'b', limit: 2 }), ['c', 'd']);
  assert.deepEqual(await ids({ orderByName: true, startAfter: 'bb' }), ['c', 'd']);
  assert.deepEqual(await ids({ orderByName: true, startAfter: 'd' }), []);
  assert.deepEqual(await ids({ orderByName: true, startAfter: 'a', where: [{ field: 'n', op: '>', value: 2 }] }), ['c', 'd']);
  assert.deepEqual((await store.list('broadcasts')).map(({ id }) => id), ['r1']);
  assert.deepEqual(await store.list('broadcasts/r1/retries'), [{ id: 'x', path: 'broadcasts/r1/retries/x', data: { n: 9 } }]);
  await assert.rejects(store.list('devices', { startAfter: 'a' }), /invalid_store_query/);
  await assert.rejects(store.list('devices', { orderByName: true, startAfter: 3 }), /invalid_store_query/);
  for (const limit of [0, -1, 1.5, '2']) await assert.rejects(store.list('devices', { limit }), /invalid_store_query/);
});

test('memory store: transactions run one at a time, so read-modify-write never loses an update', async () => {
  const store = await seeded({ 'state/counter': { n: 0 } });
  let release;
  const gate = store.runTransaction(async () => { await new Promise((resolve) => { release = resolve; }); });
  let laterRan = false;
  const later = store.get('state/counter').then((doc) => { laterRan = true; return doc; });
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(laterRan, false);
  release();
  await gate;
  assert.deepEqual(await later, { n: 0 });
  const increment = () => store.runTransaction(async (tx) => {
    const doc = await tx.get('state/counter');
    await new Promise((resolve) => setTimeout(resolve, 1));
    tx.set('state/counter', { n: doc.n + 1 });
    return doc.n + 1;
  });
  assert.deepEqual(await Promise.all([increment(), increment(), increment()]), [1, 2, 3]);
  assert.deepEqual(await store.get('state/counter'), { n: 3 });
  await assert.rejects(store.runTransaction(async () => { throw new Error('boom'); }), /boom/);
  assert.deepEqual(await store.get('state/counter'), { n: 3 });
});

test('memory store: values are cloned in and out, and Dates stay Dates', async () => {
  const store = memoryStore();
  const expiresAt = new Date('2026-12-14T12:30:00Z');
  const input = { token: 'x', expiresAt, receipt: { result: 'applied' }, geocodes: ['10017'] };
  await store.set('devices/a', input);
  input.token = 'changed';
  input.receipt.result = 'no_alarm';
  input.geocodes.push('10018');
  expiresAt.setFullYear(2000);
  const stored = await store.get('devices/a');
  assert.deepEqual(stored, { token: 'x', expiresAt: new Date('2026-12-14T12:30:00Z'), receipt: { result: 'applied' }, geocodes: ['10017'] });
  assert.ok(stored.expiresAt instanceof Date);
  stored.receipt.result = 'tampered';
  stored.expiresAt.setFullYear(1999);
  assert.deepEqual((await store.get('devices/a')).receipt, { result: 'applied' });
  assert.equal((await store.list('devices'))[0].data.expiresAt.getUTCFullYear(), 2026);
  const dump = store.dump();
  dump['devices/a'].token = 'tampered';
  assert.equal((await store.get('devices/a')).token, 'x');
  const result = await store.runTransaction(async (tx) => tx.get('devices/a'));
  result.token = 'tampered';
  assert.equal((await store.get('devices/a')).token, 'x');
});

// A fake SDK is enough to pin the mapping the emulator suite cannot run in
// CI: the namespace prefix, the query builder calls, Timestamp conversion and
// the error wrapping. Only the paths and methods the store uses exist here.
function fakeFirestore({ documents = {}, failure = null } = {}) {
  const calls = [];
  const raise = () => { if (failure) throw failure; };
  const snapshot = (path) => ({ id: path.split('/').pop(), exists: path in documents, data: () => documents[path] });
  const children = (path) => Object.keys(documents).filter((stored) => stored.startsWith(`${path}/`) && !stored.slice(path.length + 1).includes('/'));
  const query = (path, ops = []) => ({
    path, ops, isQuery: true,
    where: (field, op, value) => query(path, [...ops, ['where', field, op, value]]),
    orderBy: (field) => query(path, [...ops, ['orderBy', field]]),
    startAfter: (value) => query(path, [...ops, ['startAfter', value]]),
    limit: (value) => query(path, [...ops, ['limit', value]]),
    count: () => ({ isCount: true, path, ops, get: async () => resolve({ isCount: true, path, ops }) }),
    get: async () => resolve(query(path, ops))
  });
  const resolve = (target) => {
    raise();
    if (target.isCount) { calls.push(['count', target.path, target.ops]); return { data: () => ({ count: children(target.path).length }) }; }
    if (target.isQuery) { calls.push(['query', target.path, target.ops]); return { docs: children(target.path).map(snapshot) }; }
    calls.push(['get', target.path]);
    return snapshot(target.path);
  };
  const doc = (path) => ({
    path,
    get: async () => resolve({ path }),
    set: async (data) => { raise(); calls.push(['set', path, data]); documents[path] = data; },
    delete: async () => { raise(); calls.push(['delete', path]); delete documents[path]; }
  });
  const getAll = async (...refs) => { raise(); calls.push(['getAll', refs.map((ref) => ref.path)]); return refs.map((ref) => snapshot(ref.path)); };
  return {
    calls, doc, getAll,
    collection: (path) => query(path),
    runTransaction: async (operation) => {
      calls.push(['transaction']);
      return operation({
        get: async (target) => resolve(target),
        getAll,
        set: (ref, data) => { calls.push(['set', ref.path, data]); documents[ref.path] = data; },
        delete: (ref) => { calls.push(['delete', ref.path]); delete documents[ref.path]; }
      });
    }
  };
}

test('firestore store: paths live under dayoffNamespaces/<ns>/ and top-level Timestamps come back as Dates', async () => {
  const expiresAt = Timestamp.fromDate(new Date('2026-12-14T12:30:00Z'));
  const firestore = fakeFirestore({ documents: {
    'dayoffNamespaces/dayoff_test_1/devices/a': { deviceToken: 'ab', updatedAt: 10, expiresAt, receipt: { checkedAt: '2026-09-15T12:30:00.000Z' } },
    'dayoffNamespaces/dayoff_test_1/devices/b': { deviceToken: 'cd', updatedAt: 20 },
    'dayoffNamespaces/other/devices/z': { deviceToken: 'zz' }
  } });
  const store = createFirestoreStore({ firestore, namespace: 'dayoff_test_1' });
  assert.equal(store.kind, 'firestore');
  const device = await store.get('devices/a');
  assert.ok(device.expiresAt instanceof Date);
  assert.equal(device.expiresAt.toISOString(), '2026-12-14T12:30:00.000Z');
  assert.equal(device.receipt.checkedAt, '2026-09-15T12:30:00.000Z');
  assert.equal(await store.get('devices/none'), null);
  assert.deepEqual((await store.getAll(['devices/b', 'devices/none'])).map((doc) => doc?.deviceToken ?? null), ['cd', null]);
  assert.deepEqual(await store.getAll([]), []);
  assert.deepEqual((await store.list('devices')).map(({ id, path }) => ({ id, path })), [{ id: 'a', path: 'devices/a' }, { id: 'b', path: 'devices/b' }]);
  assert.equal(await store.count('devices'), 2);
  await store.set('state/current', { revision: 'r1' });
  await store.delete('devices/b');
  assert.deepEqual(firestore.calls.filter(([kind]) => kind === 'set' || kind === 'delete'), [
    ['set', 'dayoffNamespaces/dayoff_test_1/state/current', { revision: 'r1' }],
    ['delete', 'dayoffNamespaces/dayoff_test_1/devices/b']
  ]);
  assert.deepEqual(firestore.calls.find(([kind]) => kind === 'getAll'), ['getAll', ['dayoffNamespaces/dayoff_test_1/devices/b', 'dayoffNamespaces/dayoff_test_1/devices/none']]);
  await assert.rejects(store.get('devices'), /invalid_store_path/);
  await assert.rejects(store.set('devices/a', 'text'), /invalid_store_document/);
  assert.throws(() => createFirestoreStore({ firestore, namespace: 'bad namespace' }), /invalid_firestore_configuration/);
  assert.throws(() => createFirestoreStore({ namespace: 'ok' }), /invalid_firestore_configuration/);
});

test('firestore store: list builds where, orderBy(documentId), startAfter and limit in that order', async () => {
  const firestore = fakeFirestore();
  const store = createFirestoreStore({ firestore, namespace: 'ns' });
  await store.list('devices', { where: [{ field: 'deviceToken', op: '==', value: 'ab' }], orderByName: true, startAfter: 'cursor', limit: 200 });
  const [, path, ops] = firestore.calls.find(([kind]) => kind === 'query');
  assert.equal(path, 'dayoffNamespaces/ns/devices');
  assert.equal(ops.length, 4);
  assert.deepEqual(ops[0], ['where', 'deviceToken', '==', 'ab']);
  assert.equal(ops[1][0], 'orderBy');
  assert.ok(ops[1][1].isEqual(FieldPath.documentId()));
  assert.deepEqual(ops[2], ['startAfter', 'cursor']);
  assert.deepEqual(ops[3], ['limit', 200]);
  await store.count('devices', { where: [{ field: 'deviceToken', op: '==', value: 'ab' }], orderByName: true, limit: 5 });
  assert.deepEqual(firestore.calls.find(([kind]) => kind === 'count')[2], [['where', 'deviceToken', '==', 'ab']]);
  await assert.rejects(store.list('devices', { startAfter: 'cursor' }), /invalid_store_query/);
  await assert.rejects(store.list('devices', { where: [{ field: 'x', op: '!=', value: 1 }] }), /invalid_store_query/);
});

test('firestore store: transactions use the native reads and writes, SDK failures become storage_unavailable, ServiceErrors pass through', async () => {
  const firestore = fakeFirestore({ documents: { 'dayoffNamespaces/ns/state/current': { revision: 'r1', expiresAt: Timestamp.fromMillis(0) } } });
  const store = createFirestoreStore({ firestore, namespace: 'ns' });
  const result = await store.runTransaction(async (tx) => {
    const current = await tx.get('state/current');
    const [same] = await tx.getAll(['state/current']);
    const rows = await tx.list('state', { orderByName: true, limit: 10 });
    const total = await tx.count('state');
    tx.set('state/current', { revision: 'r2' });
    tx.delete('state/lease');
    return { revision: current.revision, sameRevision: same.revision, expiresAt: current.expiresAt, ids: rows.map(({ id }) => id), total };
  });
  assert.deepEqual(result, { revision: 'r1', sameRevision: 'r1', expiresAt: new Date(0), ids: ['current'], total: 1 });
  assert.deepEqual(await store.get('state/current'), { revision: 'r2' });
  assert.deepEqual(await store.runTransaction(async (tx) => tx.getAll([])), []);
  await assert.rejects(store.runTransaction(async () => { throw new ServiceError('lease_lost'); }), (error) => error instanceof ServiceError && error.code === 'lease_lost');
  await assert.rejects(store.runTransaction(async () => { throw new Error('UNAVAILABLE: 14 network'); }), (error) => error instanceof ServiceError && error.code === 'storage_unavailable');
  const broken = createFirestoreStore({ firestore: fakeFirestore({ failure: new Error('DEADLINE_EXCEEDED') }), namespace: 'ns' });
  for (const operation of [broken.get('state/current'), broken.getAll(['state/current']), broken.list('state'), broken.count('state'), broken.set('state/current', { a: 1 }), broken.delete('state/current'), broken.runTransaction((tx) => tx.get('state/current'))]) {
    await assert.rejects(operation, (error) => error instanceof ServiceError && error.code === 'storage_unavailable');
  }
});

test('runtime: firestoreConfiguration validates the project, refuses the emulator outside demo- projects, and requires a named database', () => {
  const env = { GOOGLE_CLOUD_PROJECT: 'rainyclock', DAYOFF_FIRESTORE_DATABASE: 'dayoff-production' };
  assert.deepEqual(firestoreConfiguration(env), { projectId: 'rainyclock', databaseId: 'dayoff-production', namespace: 'dayoff_production_v1', emulatorHost: null });
  assert.deepEqual(firestoreConfiguration({ ...env, DAYOFF_FIRESTORE_PROJECT: 'demo-rc-dayoff', DAYOFF_NAMESPACE: 'dayoff_test_1', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686' }),
    { projectId: 'demo-rc-dayoff', databaseId: 'dayoff-production', namespace: 'dayoff_test_1', emulatorHost: '127.0.0.1:8686' });
  assert.throws(() => firestoreConfiguration({ ...env, FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686' }), /unsafe_firestore_project/);
  assert.throws(() => firestoreConfiguration({ DAYOFF_FIRESTORE_DATABASE: 'dayoff-production' }), /unsafe_firestore_project/);
  for (const project of ['Rainy', 'rc', 'rainyclock-', '-rainyclock', 'rainy_clock']) assert.throws(() => firestoreConfiguration({ ...env, GOOGLE_CLOUD_PROJECT: project }), /unsafe_firestore_project/);
  assert.throws(() => firestoreConfiguration({ GOOGLE_CLOUD_PROJECT: 'rainyclock' }), /invalid_configuration/);
  for (const database of ['(default)', '', 'Dayoff', 'db', 'dayoff-', 'dayoff_production']) assert.throws(() => firestoreConfiguration({ ...env, DAYOFF_FIRESTORE_DATABASE: database }), /invalid_configuration/);
  for (const namespace of ['', 'bad namespace', 'x'.repeat(101), 'a/b']) assert.throws(() => firestoreConfiguration({ ...env, DAYOFF_NAMESPACE: namespace }), /invalid_configuration/);
  assert.throws(() => createStoreFromEnv({}), (error) => error instanceof ServiceError && error.code === 'unsafe_firestore_project');
  assert.throws(() => createStoreFromEnv({ GOOGLE_CLOUD_PROJECT: 'rainyclock', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8686', DAYOFF_FIRESTORE_DATABASE: 'dayoff-production' }), /unsafe_firestore_project/);
});

test('runtime: createStoreFromEnv builds a Firestore-backed store and close() terminates the client', async () => {
  const { store, close } = createStoreFromEnv({ GOOGLE_CLOUD_PROJECT: 'demo-rc-dayoff', DAYOFF_FIRESTORE_DATABASE: 'dayoff-emulator', FIRESTORE_EMULATOR_HOST: '127.0.0.1:1', DAYOFF_NAMESPACE: 'dayoff_test_x' });
  assert.equal(store.kind, 'firestore');
  for (const method of ['get', 'getAll', 'list', 'count', 'set', 'delete', 'runTransaction']) assert.equal(typeof store[method], 'function');
  assert.equal(typeof store.dump, 'undefined');
  await close();
});
