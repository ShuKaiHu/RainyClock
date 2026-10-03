'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const { randomUUID } = require('node:crypto')
const { createMemoryStore, createFirestoreStore } = require('../membership/store')
const { createStoreDeletionMaintenance } = require('../membership/maintenance')
const { maintenanceConfiguration, runDeletionMaintenance } = require('../membership/maintenance-cli')

const env = { MEMBERSHIP_SERVER_MODE: 'dual', GOOGLE_CLOUD_PROJECT: 'demo-rc-deletion' }
const timestamp = Date.parse('2026-09-21T13:00:00Z')

async function seed(store, id = 'deleted-member') {
  await store.set(`members/${id}`, { id, deletedAt: timestamp, deletionCleanupState: 'pending' })
  for (const collection of ['purchases', 'days', 'generations', 'generationResults', 'sessions', 'devices', 'challenges']) {
    await store.set(`members/${id}/${collection}/old`, { privateData: 'delete-me' })
  }
  for (const collection of ['authSessions', 'authDevices', 'authChallenges', 'authRewardUsers']) {
    await store.set(`${collection}/${id}-old`, { memberId: id, privateData: 'delete-me' })
  }
  await store.set(`authMemberRewards/${id}`, { userId: 'reward-link', memberId: id })
  await store.set(`notifications/${id}`, { memberId: id, appliedAt: timestamp })
  await store.set('members/active', { id: 'active', freeGranted: 1 })
  await store.set('members/active/generationResults/saved', { pcm: Buffer.from([1, 0]) })
  await store.set('authDevices/active', { memberId: 'active', publicKey: 'keep' })
  // Existing deletion policy intentionally retains these minimal guards.
  await store.set('identities/opaque-hmac', { freeGrantConsumed: true, deletedAt: timestamp })
  await store.set('purchaseOwners/purchase-hmac', { identityHash: 'opaque-hmac' })
  await store.set('rewardEvents/event-hmac', { identityHash: 'opaque-hmac' })
  await store.set('rewardProofs/proof-hmac', { identityHash: 'opaque-hmac' })
}

async function assertCleaned(store, id = 'deleted-member') {
  assert.equal((await store.get(`members/${id}`)).deletionCleanupState, 'complete')
  for (const collection of ['purchases', 'days', 'generations', 'generationResults', 'sessions', 'devices', 'challenges']) {
    assert.equal((await store.list(`members/${id}/${collection}`)).length, 0)
  }
  for (const collection of ['authSessions', 'authDevices', 'authChallenges', 'authRewardUsers']) {
    assert.equal(await store.get(`${collection}/${id}-old`), null)
  }
  assert.equal(await store.get(`authMemberRewards/${id}`), null)
  assert.deepEqual(await store.get(`notifications/${id}`), { appliedAt: timestamp })
  assert.equal((await store.get('members/active')).freeGranted, 1)
  assert.ok(await store.get('members/active/generationResults/saved'))
  assert.equal((await store.get('authDevices/active')).publicKey, 'keep')
  assert.equal((await store.get('identities/opaque-hmac')).freeGrantConsumed, true)
  for (const path of ['purchaseOwners/purchase-hmac', 'rewardEvents/event-hmac', 'rewardProofs/proof-hmac']) {
    assert.equal((await store.get(path)).identityHash, 'opaque-hmac')
  }
}

test('maintenance selects both isolated stores without provider credentials or member secrets', () => {
  const config = maintenanceConfiguration(env)
  assert.deepEqual(config.targets.map((c) => [c.environment, c.databaseId, c.namespace]), [
    ['Production', 'membership-production', 'membership_production_v1'],
    ['Sandbox', 'membership-testflight', 'membership_testflight_v1']
  ])
  assert.equal(config.batchSize, 100)
  assert.equal(config.maxBatches, 10)
  for (const overrides of [
    { MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE: 'membership-production' },
    { MEMBERSHIP_SANDBOX_NAMESPACE: 'membership_production_v1' },
    { MEMBERSHIP_PRODUCTION_NAMESPACE: '../../members' },
    { MEMBERSHIP_SERVER_MODE: 'Production' },
    { MEMBERSHIP_MAINTENANCE_BATCH_SIZE: '0' },
    { MEMBERSHIP_MAINTENANCE_BATCH_SIZE: '101' },
    { MEMBERSHIP_MAINTENANCE_MAX_BATCHES: 'Infinity' },
    { GOOGLE_CLOUD_PROJECT: 'rainyclock', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' }
  ]) assert.throws(() => maintenanceConfiguration({ ...env, ...overrides }))
})

test('legacy development cleanup stays explicit and cannot fall back to the default database', () => {
  const sandbox = { GOOGLE_CLOUD_PROJECT: 'demo-rc-deletion', MEMBERSHIP_APPLE_ENVIRONMENT: 'Sandbox',
    MEMBERSHIP_FIRESTORE_DATABASE: 'membership-sandbox' }
  assert.equal(maintenanceConfiguration(sandbox).targets[0].databaseId, 'membership-sandbox')
  assert.throws(() => maintenanceConfiguration({ ...sandbox, MEMBERSHIP_FIRESTORE_DATABASE: undefined }))
  assert.throws(() => maintenanceConfiguration({ ...sandbox, MEMBERSHIP_APPLE_ENVIRONMENT: 'Production' }))
})

test('dual cleanup removes both deleted members while preserving active accounts and anti-replay policy', async () => {
  const stores = { Production: createMemoryStore(), Sandbox: createMemoryStore() }
  for (const store of Object.values(stores)) await seed(store)
  const closed = []
  const createTarget = ({ environment }) => ({ ...createStoreDeletionMaintenance({ store: stores[environment] }),
    close: async () => { closed.push(environment) } })
  const first = await runDeletionMaintenance({ env, createTarget })
  assert.equal(first.ok, true)
  assert.deepEqual(first.results.map((r) => r.completed), [1, 1])
  assert.deepEqual(closed, ['Production', 'Sandbox'])
  for (const store of Object.values(stores)) await assertCleaned(store)
  const repeated = await runDeletionMaintenance({ env, createTarget })
  assert.equal(repeated.ok, true)
  assert.deepEqual(repeated.results.map((r) => r.examined), [0, 0])
})

test('one unavailable database does not prevent the other environment from cleaning; retry finishes only pending work', async () => {
  const stores = { Production: createMemoryStore(), Sandbox: createMemoryStore() }
  for (const store of Object.values(stores)) await seed(store)
  let unavailable = true
  const createTarget = ({ environment }) => {
    if (environment === 'Production' && unavailable) throw new Error('must-not-log-private-provider-error')
    return createStoreDeletionMaintenance({ store: stores[environment] })
  }
  const partial = await runDeletionMaintenance({ env, createTarget })
  assert.equal(partial.ok, false)
  assert.equal(partial.results[0].error, true)
  assert.equal(partial.results[1].completed, 1)
  assert.ok(!JSON.stringify(partial).includes('private-provider'))
  assert.equal((await stores.Production.get('members/deleted-member')).deletionCleanupState, 'pending')
  unavailable = false
  const retried = await runDeletionMaintenance({ env, createTarget })
  assert.equal(retried.ok, true)
  assert.deepEqual(retried.results.map((r) => r.completed), [1, 0])
})

test('auth cleanup failure keeps a durable pending marker and makes the execution fail until retried', async () => {
  const store = createMemoryStore()
  await seed(store)
  let fail = true
  const interruptedStore = { ...store, async delete(path) {
    if (fail && path.startsWith('authMemberRewards/')) throw new Error('temporary Firestore failure')
    return store.delete(path)
  } }
  const single = { GOOGLE_CLOUD_PROJECT: 'demo-rc-deletion', MEMBERSHIP_APPLE_ENVIRONMENT: 'Sandbox',
    MEMBERSHIP_FIRESTORE_DATABASE: 'membership-sandbox' }
  const createTarget = () => createStoreDeletionMaintenance({ store: interruptedStore })
  const first = await runDeletionMaintenance({ env: single, createTarget })
  assert.equal(first.ok, false)
  assert.equal(first.results[0].failed, 1)
  assert.equal(first.results[0].pendingRemaining, true)
  assert.equal((await store.get('members/deleted-member')).deletionCleanupState, 'pending')
  fail = false
  assert.equal((await runDeletionMaintenance({ env: single, createTarget })).ok, true)
  await assertCleaned(store)
})

test('bounded work reports remaining backlog for Cloud Run retries instead of false success', async () => {
  const stores = { Production: createMemoryStore(), Sandbox: createMemoryStore() }
  for (let i = 0; i < 3; i++) await seed(stores.Production, `deleted-${i}`)
  const createTarget = ({ environment }) => createStoreDeletionMaintenance({ store: stores[environment] })
  const first = await runDeletionMaintenance({ env: { ...env, MEMBERSHIP_MAINTENANCE_BATCH_SIZE: '2',
    MEMBERSHIP_MAINTENANCE_MAX_BATCHES: '1' }, createTarget })
  assert.equal(first.ok, false)
  assert.equal(first.results[0].completed, 2)
  assert.equal(first.results[0].pendingRemaining, true)
  const retried = await runDeletionMaintenance({ env, createTarget })
  assert.equal(retried.ok, true)
  assert.equal(retried.results[0].completed, 1)
})

test('overlapping maintenance executions are idempotent', async () => {
  const stores = { Production: createMemoryStore(), Sandbox: createMemoryStore() }
  for (const store of Object.values(stores)) await seed(store)
  const createTarget = ({ environment }) => createStoreDeletionMaintenance({ store: stores[environment] })
  const outcomes = await Promise.all([runDeletionMaintenance({ env, createTarget }), runDeletionMaintenance({ env, createTarget })])
  assert.ok(outcomes.every((r) => r.ok))
  for (const store of Object.values(stores)) await assertCleaned(store)
})

test('pending state without a deletion tombstone never erases an active member', async () => {
  const store = createMemoryStore()
  await store.set('members/active', { id: 'active', deletionCleanupState: 'pending' })
  await store.set('members/active/purchases/paid', { productId: 'keep-paid-purchase' })
  const outcome = await createStoreDeletionMaintenance({ store }).cleanup()
  assert.deepEqual(outcome, { examined: 1, completed: 0, failed: 1 })
  assert.equal((await store.get('members/active/purchases/paid')).productId, 'keep-paid-purchase')
})

test('invalid configuration fails before any store is opened; CLI exits nonzero without raw error details', async () => {
  let opened = 0
  await assert.rejects(runDeletionMaintenance({ env: { ...env, MEMBERSHIP_SANDBOX_NAMESPACE: 'membership_production_v1' },
    createTarget: () => { opened++; throw new Error('should-not-open') } }))
  assert.equal(opened, 0)
  const child = spawnSync(process.execPath, [require.resolve('../membership/maintenance-cli')], { env: {}, encoding: 'utf8' })
  assert.equal(child.status, 1)
  assert.equal(child.stdout, '')
  assert.deepEqual(JSON.parse(child.stderr), { event: 'membership_deletion_maintenance_failed' })
})

test('Firestore Emulator: dual database job clears interrupted deletion from both namespaces', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST
}, async () => {
  const { Firestore } = require('@google-cloud/firestore')
  const namespace = `maintenance_${randomUUID().replaceAll('-', '')}`
  const config = { ...env, FIRESTORE_EMULATOR_HOST: process.env.FIRESTORE_EMULATOR_HOST,
    MEMBERSHIP_PRODUCTION_NAMESPACE: namespace + '_production', MEMBERSHIP_SANDBOX_NAMESPACE: namespace + '_sandbox' }
  const clients = maintenanceConfiguration(config).targets.map((target) => {
    const firestore = new Firestore({ projectId: target.projectId, databaseId: target.databaseId,
      host: target.emulatorHost, ssl: false })
    return { firestore, namespace: target.namespace, store: createFirestoreStore({ firestore, namespace: target.namespace }) }
  })
  try {
    for (const target of clients) await seed(target.store)
    const outcome = await runDeletionMaintenance({ env: config })
    assert.equal(outcome.ok, true)
    assert.deepEqual(outcome.results.map((r) => r.completed), [1, 1])
    for (const target of clients) await assertCleaned(target.store)
  } finally {
    for (const { firestore, namespace } of clients) {
      await firestore.recursiveDelete(firestore.doc(`membershipNamespaces/${namespace}`))
      await firestore.terminate()
    }
  }
})
