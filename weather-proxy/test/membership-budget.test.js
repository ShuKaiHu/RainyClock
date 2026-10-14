'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { randomUUID } = require('node:crypto')
const { createMemoryStore, createFirestoreStore } = require('../membership/store')
const { createPersistentTTSBudget } = require('../membership/budget')
const { createMembershipService } = require('../membership/service')
const { createGenerationService } = require('../membership/generation')
const { createPolicy } = require('../membership/policy')

test('separate server replicas share an atomic daily upstream cost ceiling', async () => {
  const store = createMemoryStore()
  const replicas = Array.from({ length: 4 }, () => createPersistentTTSBudget({ store, limit: 3 }))
  const results = await Promise.allSettled(Array.from({ length: 20 }, (_, i) => replicas[i % 4].consume()))
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 3)
  for (const result of results.filter((r) => r.status === 'rejected')) {
    assert.equal(result.reason.code, 'daily_upstream_limit_reached')
    assert.equal(result.reason.status, 503)
  }
})

test('cost ceiling resets at server UTC midnight independently of member timezone', async () => {
  let now = Date.parse('2026-09-16T23:59:59Z')
  const budget = createPersistentTTSBudget({ store: createMemoryStore(), limit: 1, clock: () => now })
  assert.equal((await budget.consume()).serviceDate, '2026-09-16')
  await assert.rejects(budget.consume(), /daily_upstream_limit_reached/)
  now += 1000
  assert.equal((await budget.consume()).serviceDate, '2026-09-17')
})

test('failed attempts consume operational budget but refund member credit; replay consumes neither again', async () => {
  const store = createMemoryStore()
  const budget = createPersistentTTSBudget({ store, limit: 2 })
  const membership = createMembershipService({ store, policy: createPolicy({ migrationCutoverAt: 0 }),
    products: { monthly: 'monthly', yearly: 'yearly', lifetime: 'lifetime' },
    identityHashSecret: 'budget-tests-only-secret-at-least-32-characters' })
  const member = await membership.recognizeMember({ environment: 'Sandbox', appTransactionId: 'budget-account',
    bundleId: 'com.shukaihu.RainyClock', originalPurchaseDate: 1, timeZone: 'Asia/Taipei' })
  let calls = 0
  const generation = createGenerationService({ membership, generate: async () => {
    await budget.consume()
    calls++
    if (calls === 1) throw new Error('upstream failed after possibly billing')
    return { pcm: Buffer.from([1, 0, 2, 0]), sampleRate: 24_000, emotions: [] }
  } })
  const input = { text: 'Morning.', persona: 'steady', language: 'en' }
  await assert.rejects(generation.execute({ memberId: member.memberId, requestId: 'failed-cost-attempt', input }), /generation_failed/)
  assert.equal((await membership.status(member.memberId)).quota.freeRemaining, 1)
  await generation.execute({ memberId: member.memberId, requestId: 'successful-cost-attempt', input })
  await generation.execute({ memberId: member.memberId, requestId: 'successful-cost-attempt', input })
  await generation.getResult({ memberId: member.memberId, requestId: 'successful-cost-attempt' })
  assert.equal(calls, 2)
  await membership.creditVerifiedReward({ memberId: member.memberId, provider: 'levelplay',
    eventId: 'budget-test-reward', proofId: 'a'.repeat(64) })
  await assert.rejects(generation.execute({ memberId: member.memberId, requestId: 'budget-refused-attempt', input }), /daily_upstream_limit_reached/)
  assert.equal(calls, 2, 'budget refusal must happen before provider invocation')
  assert.equal((await membership.status(member.memberId)).quota.freeRemaining, 0)
  assert.equal((await membership.status(member.memberId)).quota.rewardCredits, 1, 'budget refusal must refund the ad reservation')
  const row = (await store.list('costBudgets'))[0].data
  assert.equal(row.attempts, 2, 'failed upstream call does not refund global spending guard')
})

test('Firestore Emulator enforces the same cost cap across independently constructed server replicas', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST ? 'Requires local Firestore Emulator; never uses production.' : false
}, async () => {
  const { Firestore } = require('@google-cloud/firestore')
  const firestore = new Firestore({ projectId: 'rainyclock-membership-emulator', ssl: false })
  const namespace = `cost_test_${randomUUID().replaceAll('-', '')}`
  try {
    const replicas = Array.from({ length: 3 }, () => createPersistentTTSBudget({
      store: createFirestoreStore({ firestore, namespace }), limit: 2
    }))
    const results = await Promise.allSettled(Array.from({ length: 10 }, (_, i) => replicas[i % 3].consume()))
    assert.equal(results.filter((r) => r.status === 'fulfilled').length, 2)
    assert.ok(results.filter((r) => r.status === 'rejected').every((r) => r.reason.code === 'daily_upstream_limit_reached'))
  } finally {
    await firestore.recursiveDelete(firestore.doc(`membershipNamespaces/${namespace}`))
    await firestore.terminate()
  }
})
