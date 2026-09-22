'use strict'

// Shared contract for domain and authentication state. Paths are relative to one
// isolated namespace. The memory implementation obeys Firestore's read-before-
// write rule and serializes transactions; it is never a production fallback.
function validatePath(path, document) {
  if (typeof path !== 'string' || !path || path.split('/').some((p) => !p || p === '.' || p === '..') ||
      (path.split('/').length % 2 === 0) !== document) throw new Error('invalid_store_path')
  return path
}

function clone(value) {
  if (value === null || value === undefined) return value
  if (Buffer.isBuffer(value)) return Buffer.from(value)
  if (value instanceof Uint8Array) return Buffer.from(value)
  if (value instanceof Date) return new Date(value)
  if (Array.isArray(value)) return value.map(clone)
  if (typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, clone(v)]))
  return value
}

function createMemoryStore() {
  let documents = new Map()
  let queue = Promise.resolve()
  const runTransaction = (operation) => {
    const pending = queue.then(async () => {
      const working = new Map(documents)
      let written = false
      const read = () => { if (written) throw new Error('transaction_read_after_write') }
      const tx = {
        async get(path) { read(); return clone(working.get(validatePath(path, true)) ?? null) },
        async list(path, options = {}) {
          read(); validatePath(path, false)
          const prefix = `${path}/`
          return [...working].filter(([p]) => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
            .map(([p, data]) => ({ id: p.slice(prefix.length), path: p, data: clone(data) }))
            .filter(({ data }) => (options.where || []).every(({ field, op, value }) => {
              if (op === '==') return data[field] === value
              if (op === '<=') return data[field] <= value
              throw new Error('unsupported_memory_query_operator')
            })).slice(0, options.limit ?? Infinity)
        },
        set(path, data) { validatePath(path, true); written = true; working.set(path, clone(data)) },
        delete(path) { validatePath(path, true); written = true; working.delete(path) }
      }
      const result = await operation(tx)
      documents = working
      return clone(result)
    })
    queue = pending.catch(() => {})
    return pending
  }
  return {
    kind: 'memory-test-only', runTransaction,
    get: (path) => runTransaction((tx) => tx.get(path)),
    list: (path, options) => runTransaction((tx) => tx.list(path, options)),
    set: (path, data) => runTransaction((tx) => tx.set(path, data)),
    delete: (path) => runTransaction((tx) => tx.delete(path))
  }
}

function createFirestoreStore({ firestore, namespace = 'membership_v1' }) {
  if (!firestore || !/^[a-zA-Z0-9_-]{1,100}$/.test(namespace)) throw new Error('invalid_firestore_config')
  const prefix = `membershipNamespaces/${namespace}/`
  const doc = (path) => firestore.doc(prefix + validatePath(path, true))
  const collection = (path, options = {}) => {
    let query = firestore.collection(prefix + validatePath(path, false))
    for (const { field, op, value } of options.where || []) query = query.where(field, op, value)
    return options.limit ? query.limit(options.limit) : query
  }
  const readData = (snapshot) => snapshot.exists ? snapshot.data() : null
  const listData = (snapshot, path) => snapshot.docs.map((d) => ({ id: d.id, path: `${path}/${d.id}`, data: d.data() }))
  return {
    kind: 'firestore',
    runTransaction: (operation) => firestore.runTransaction(async (native) => operation({
      get: async (path) => readData(await native.get(doc(path))),
      list: async (path, options) => listData(await native.get(collection(path, options)), path),
      set: (path, data) => native.set(doc(path), data),
      delete: (path) => native.delete(doc(path))
    })),
    get: async (path) => readData(await doc(path).get()),
    list: async (path, options) => listData(await collection(path, options).get(), path),
    set: (path, data) => doc(path).set(data),
    delete: (path) => doc(path).delete()
  }
}

module.exports = { createMemoryStore, createFirestoreStore }
