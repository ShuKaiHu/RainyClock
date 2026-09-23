import { FieldPath, Timestamp } from '@google-cloud/firestore';
import { ServiceError } from './errors.js';

// One storage seam for the poll Job, the request-only service and local mode.
// Paths are relative to a namespace; an even number of segments names a
// document, an odd number a collection, in both backends. The memory backend
// exists for tests: it enforces Firestore's read-before-write rule and
// serialises transactions so a test that passes here does not merely pass
// because it never contended. Nothing selects it from the environment.
const NAMESPACE = /^[a-zA-Z0-9_-]{1,100}$/;
const WHERE_OPERATORS = new Set(['==', '<=', '<', '>']);

export function validatePath(path, isDocument) {
  const segments = typeof path === 'string' ? path.split('/') : [];
  if (segments.length === 0 || segments.some((segment) => !segment || segment === '.' || segment === '..') ||
      (segments.length % 2 === 0) !== isDocument) throw new ServiceError('invalid_store_path');
  return path;
}

function validateDocument(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new ServiceError('invalid_store_document');
  return data;
}

// Firestore rejects a cursor without an order and an unknown operator up
// front; the memory store must fail the same tests rather than answer them.
function validateQuery(options = {}) {
  for (const clause of options.where ?? []) {
    if (!clause || typeof clause.field !== 'string' || !WHERE_OPERATORS.has(clause.op)) throw new ServiceError('invalid_store_query');
  }
  if (options.startAfter !== undefined && (!options.orderByName || typeof options.startAfter !== 'string')) throw new ServiceError('invalid_store_query');
  if (options.limit !== undefined && (!Number.isSafeInteger(options.limit) || options.limit < 1)) throw new ServiceError('invalid_store_query');
  return options;
}

function clone(value) {
  if (value === null || typeof value !== 'object') return value;
  if (value instanceof Date) return new Date(value.getTime());
  if (value instanceof Uint8Array) return Buffer.from(value);
  if (Array.isArray(value)) return value.map(clone);
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, clone(entry)]));
}

function matches(data, { field, op, value }) {
  const actual = data[field];
  if (op === '==') return actual === value;
  if (actual === undefined || actual === null) return false;
  if (op === '<=') return actual <= value;
  if (op === '<') return actual < value;
  return actual > value;
}

export function createMemoryStore() {
  let documents = new Map();
  let queue = Promise.resolve();
  const query = (working, path, options) => {
    validatePath(path, false);
    validateQuery(options);
    const prefix = `${path}/`;
    const rows = [...working]
      .filter(([storedPath]) => storedPath.startsWith(prefix) && !storedPath.slice(prefix.length).includes('/'))
      .map(([storedPath, data]) => ({ id: storedPath.slice(prefix.length), path: storedPath, data }))
      .filter(({ data }) => (options.where ?? []).every((clause) => matches(data, clause)))
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const start = options.startAfter === undefined ? 0 : rows.findIndex(({ id }) => id > options.startAfter);
    return (start === -1 ? [] : rows.slice(start)).slice(0, options.limit ?? rows.length);
  };
  const runTransaction = (operation) => {
    const pending = queue.then(async () => {
      const working = new Map(documents);
      let written = false;
      const read = () => { if (written) throw new ServiceError('transaction_read_after_write'); };
      const tx = {
        async get(path) { read(); return clone(working.get(validatePath(path, true)) ?? null); },
        async getAll(paths) { read(); return paths.map((path) => clone(working.get(validatePath(path, true)) ?? null)); },
        async list(path, options = {}) { read(); return query(working, path, options).map((row) => ({ ...row, data: clone(row.data) })); },
        async count(path, options = {}) { read(); return query(working, path, { where: options.where }).length; },
        set(path, data) { validatePath(path, true); validateDocument(data); written = true; working.set(path, clone(data)); },
        delete(path) { validatePath(path, true); written = true; working.delete(path); }
      };
      const result = await operation(tx);
      documents = working;
      return clone(result);
    });
    queue = pending.catch(() => {});
    return pending;
  };
  return {
    kind: 'memory-test-only',
    runTransaction,
    get: (path) => runTransaction((tx) => tx.get(path)),
    getAll: (paths) => runTransaction((tx) => tx.getAll(paths)),
    list: (path, options) => runTransaction((tx) => tx.list(path, options)),
    count: (path, options) => runTransaction((tx) => tx.count(path, options)),
    set: (path, data) => runTransaction((tx) => tx.set(path, data)),
    delete: (path) => runTransaction((tx) => tx.delete(path)),
    dump: () => Object.fromEntries([...documents].map(([path, data]) => [path, clone(data)]))
  };
}

// Only expiresAt fields are written as Dates (Firestore TTL needs a
// Timestamp); every value the phone can see is an ISO string, so converting
// the top level on read is enough to keep both backends returning Dates.
function fromFirestore(data) {
  return Object.fromEntries(Object.entries(data).map(([key, value]) => [key, value instanceof Timestamp ? value.toDate() : value]));
}

// A ServiceError raised by the caller's own logic keeps its code; anything
// the SDK raises is an outage as far as the HTTP status map is concerned.
async function guarded(work) {
  try {
    return await work();
  } catch (error) {
    if (error instanceof ServiceError) throw error;
    throw new ServiceError('storage_unavailable');
  }
}

export function createFirestoreStore({ firestore, namespace } = {}) {
  if (!firestore || typeof namespace !== 'string' || !NAMESPACE.test(namespace)) throw new ServiceError('invalid_firestore_configuration');
  const prefix = `dayoffNamespaces/${namespace}/`;
  const doc = (path) => firestore.doc(prefix + validatePath(path, true));
  const collection = (path, options = {}) => {
    validateQuery(options);
    let query = firestore.collection(prefix + validatePath(path, false));
    for (const { field, op, value } of options.where ?? []) query = query.where(field, op, value);
    if (options.orderByName) query = query.orderBy(FieldPath.documentId());
    if (options.startAfter !== undefined) query = query.startAfter(options.startAfter);
    return options.limit === undefined ? query : query.limit(options.limit);
  };
  const readData = (snapshot) => (snapshot.exists ? fromFirestore(snapshot.data()) : null);
  const listData = (snapshot, path) => snapshot.docs.map((row) => ({ id: row.id, path: `${path}/${row.id}`, data: fromFirestore(row.data()) }));
  const refs = (paths) => paths.map(doc);
  return {
    kind: 'firestore',
    runTransaction: (operation) => guarded(() => firestore.runTransaction((native) => operation({
      get: async (path) => readData(await native.get(doc(path))),
      getAll: async (paths) => (paths.length === 0 ? [] : (await native.getAll(...refs(paths))).map(readData)),
      list: async (path, options) => listData(await native.get(collection(path, options)), path),
      count: async (path, options = {}) => (await native.get(collection(path, { where: options.where }).count())).data().count,
      set: (path, data) => { native.set(doc(path), validateDocument(data)); },
      delete: (path) => { native.delete(doc(path)); }
    }))),
    get: (path) => guarded(async () => readData(await doc(path).get())),
    getAll: (paths) => guarded(async () => (paths.length === 0 ? [] : (await firestore.getAll(...refs(paths))).map(readData))),
    list: (path, options) => guarded(async () => listData(await collection(path, options).get(), path)),
    count: (path, options = {}) => guarded(async () => (await collection(path, { where: options.where }).count().get()).data().count),
    set: (path, data) => guarded(async () => { await doc(path).set(validateDocument(data)); }),
    delete: (path) => guarded(async () => { await doc(path).delete(); })
  };
}
