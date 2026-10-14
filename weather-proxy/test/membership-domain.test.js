'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { randomUUID, createHash } = require('node:crypto')
const { createMemoryStore, createFirestoreStore } = require('../membership/store')
const { createPolicy, nextMidnight } = require('../membership/policy')
const { createMembershipService, deriveEntitlements } = require('../membership/service')
const { createGenerationService } = require('../membership/generation')

const products = { monthly: 'com.shukaihu.RainyClock.plus.monthly', yearly: 'com.shukaihu.RainyClock.plus.yearly', lifetime: 'com.shukaihu.RainyClock.banner.lifetime' }
const initialTime = Date.parse('2026-09-16T04:00:00Z')
const cutoff = Date.parse('2026-09-01T00:00:00Z')
const identity = (overrides = {}) => ({ appTransactionId: 'apple-account-1', environment: 'Sandbox',
  bundleId: 'com.shukaihu.RainyClock', originalPurchaseDate: cutoff + 1, timeZone: 'Asia/Taipei', ...overrides })
const audio = () => ({ pcm: Buffer.from([1, 0, 2, 0, 3, 0, 4, 0]), sampleRate: 24_000, emotions: ['neutral'] })
const input = { text: 'Good morning.', persona: 'steady', language: 'en' }
const rewardProof = (eventId) => createHash('sha256').update(`verified-fixture:${eventId}`).digest('hex')

async function fixture({ store = createMemoryStore(), policy: options = {}, user = identity(), generate = async () => audio() } = {}) {
  let now = initialTime
  const clock = () => now
  const policy = createPolicy({ migrationCutoverAt: cutoff, ...options })
  const membership = createMembershipService({ store, policy, identityHashSecret: 'test-only-not-a-production-secret-32', products, clock })
  const state = await membership.recognizeMember(user)
  const memberId = state.memberId
  const generation = createGenerationService({ membership, generate, clock })
  const purchase = (overrides = {}) => ({ transactionId: 'txn-1', originalTransactionId: 'chain-1',
    productId: products.monthly, environment: user.environment, bundleId: user.bundleId,
    appTransactionId: user.appTransactionId, appAccountToken: state.appAccountToken,
    purchaseDate: now - 1000, signedDate: now, expiresDate: now + 86_400_000, revocationDate: null, ...overrides })
  return { store, membership, generation, memberId, state, purchase, clock, setTime: (value) => { now = value } }
}
const errorCode = (code) => (error) => { assert.equal(error.code, code); return true }

test('production policy requires an explicit stable migration cutover', () => {
  assert.throws(() => createPolicy(), /migration_cutover_required/)
  assert.throws(() => createPolicy({ migrationCutoverAt: cutoff, approved: false }), /unapproved/)
  assert.throws(() => createPolicy({ migrationCutoverAt: cutoff, initialFreeAllowance: 3 }), /unapproved/)
})

test('verified identity recognizes the same member and appAccountToken on reinstall and a second device', async () => {
  const f = await fixture()
  const states = await Promise.all(Array.from({ length: 12 }, () => f.membership.recognizeMember(identity())))
  assert.ok(states.every((s) => s.memberId === f.memberId && s.appAccountToken === f.state.appAccountToken))
  const sandboxOther = await f.membership.recognizeMember(identity({ appTransactionId: 'another-account' }))
  assert.notEqual(sandboxOther.memberId, f.memberId)
  const production = await f.membership.recognizeMember(identity({ environment: 'Production' }))
  assert.notEqual(production.memberId, f.memberId)
})

test('free members have exactly one initial generation, never a new daily allowance', async () => {
  const f = await fixture()
  assert.equal(f.state.quota.freeRemaining, 1)
  await f.generation.execute({ memberId: f.memberId, requestId: 'free-job-1', input })
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'free-job-2', input }), errorCode('quota_exhausted'))
  f.setTime(initialTime + 3 * 86_400_000)
  const state = await f.membership.status(f.memberId)
  assert.equal(state.quota.freeRemaining, 0)
  assert.equal(state.quota.dailyRemaining, 0)
  const restored = await f.membership.recognizeMember(identity())
  assert.equal(restored.memberId, f.memberId)
  assert.equal(restored.quota.freeRemaining, 0, 'another device or reinstall cannot reclaim the initial generation')
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'free-job-later', input }), errorCode('quota_exhausted'))
})

test('concurrent free requests spend only one initial generation and leave verified ad credit usable', async () => {
  let calls = 0
  const f = await fixture({ generate: async () => { calls++; return audio() } })
  const outcomes = await Promise.allSettled(Array.from({ length: 12 }, (_, n) =>
    f.generation.execute({ memberId: f.memberId, requestId: `free-concurrent-${n}`, input })))
  assert.equal(calls, 1)
  assert.equal(outcomes.filter((r) => r.status === 'fulfilled').length, 1)
  assert.ok(outcomes.filter((r) => r.status === 'rejected').every((r) => r.reason.code === 'quota_exhausted'))
  await f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay',
    eventId: 'free-extra-ad', proofId: rewardProof('free-extra-ad') })
  await f.generation.execute({ memberId: f.memberId, requestId: 'free-ad-generation', input })
  assert.equal(calls, 2)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 0)
})

test('recognizing existing server members preserves their recorded grants, usage and ad rewards', async () => {
  const f = await fixture()
  const path = `members/${f.memberId}`
  const original = await f.store.get(path)
  // Represents an existing, server-issued ledger from a prior policy; the new
  // account default must not retroactively rewrite already issued balances.
  await f.store.set(path, { ...original, freeGranted: 3, freeUsed: 1, rewardGranted: 4, rewardUsed: 1 })
  const restored = await f.membership.recognizeMember(identity())
  assert.equal(restored.quota.freeRemaining, 2)
  assert.equal(restored.quota.rewardCredits, 3)
  const stored = await f.store.get(path)
  for (const [key, value] of Object.entries({ freeGranted: 3, freeUsed: 1, rewardGranted: 4, rewardUsed: 1 })) {
    assert.equal(stored[key], value)
  }
})

test('twenty concurrent paid requests across devices reserve only one daily allowance', async () => {
  let calls = 0
  const f = await fixture({ generate: async () => { calls++; return audio() } })
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  const outcomes = await Promise.allSettled(Array.from({ length: 20 }, (_, n) =>
    f.generation.execute({ memberId: f.memberId, requestId: `daily-job-${n}`, input })))
  assert.equal(calls, 1)
  assert.equal(outcomes.filter((r) => r.status === 'fulfilled').length, 1)
  for (const result of outcomes.filter((r) => r.status === 'rejected')) assert.equal(result.reason.code, 'quota_exhausted')
  assert.equal((await f.membership.status(f.memberId)).quota.dailyRemaining, 0)
})

test('duplicate request coalesces while running and replays durable result without another generation or debit', async () => {
  let finish
  let calls = 0
  const f = await fixture({ generate: async () => { calls++; return new Promise((resolve) => { finish = resolve }) } })
  const first = f.generation.execute({ memberId: f.memberId, requestId: 'same-request', input })
  while (!finish) await new Promise((resolve) => setImmediate(resolve))
  const running = await f.generation.execute({ memberId: f.memberId, requestId: 'same-request', input })
  assert.equal(running.status, 'processing')
  finish(audio())
  const result = await first
  assert.deepEqual(result.pcm, audio().pcm)
  const replay = await f.generation.execute({ memberId: f.memberId, requestId: 'same-request', input: { ...input } })
  assert.deepEqual(replay.pcm, result.pcm)
  assert.equal(replay.replayed, true)
  assert.equal(calls, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 0)
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'same-request', input: { ...input, text: 'changed' } }), errorCode('idempotency_conflict'))
})

test('stored result expires without resetting an old idempotency key or charging a download', async () => {
  const f = await fixture()
  await f.generation.execute({ memberId: f.memberId, requestId: 'expiring-result', input })
  f.setTime(initialTime + 86_400_001)
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'expiring-result', input }), errorCode('generation_result_expired'))
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 0)
})

test('known generation failure refunds the original funding and does not rerun the same failed request', async () => {
  let calls = 0
  const f = await fixture({ generate: async () => { calls++; throw new Error('upstream failure') } })
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'failed-request', input }), errorCode('generation_failed'))
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 1)
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'failed-request', input }), errorCode('generation_failed'))
  assert.equal(calls, 1)
})

test('a lost commit acknowledgement replays saved audio and never synthesizes or charges twice', async () => {
  const base = createMemoryStore()
  let loseNextResultAcknowledgement = true
  const store = { ...base, runTransaction: async (operation) => {
    let wroteResult = false
    const value = await base.runTransaction((tx) => operation({ ...tx, set: (path, data) => {
      wroteResult ||= path.includes('/generationResults/')
      tx.set(path, data)
    } }))
    if (wroteResult && loseNextResultAcknowledgement) {
      loseNextResultAcknowledgement = false
      throw new Error('simulated transport loss after successful commit')
    }
    return value
  } }
  let calls = 0
  const f = await fixture({ store, generate: async () => { calls++; return audio() } })
  assert.equal((await f.generation.execute({ memberId: f.memberId, requestId: 'lost-commit-ack', input })).status, 'uncertain')
  const result = await f.generation.execute({ memberId: f.memberId, requestId: 'lost-commit-ack', input })
  assert.equal(result.status, 'succeeded')
  assert.deepEqual(result.pcm, audio().pcm)
  assert.equal(calls, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 0)
})

test('storage failure cannot debit without durable audio; expiration refunds without repeating upstream', async () => {
  const base = createMemoryStore()
  const store = { ...base, runTransaction: (operation) => base.runTransaction((tx) => operation({ ...tx,
    set: (path, data) => {
      if (path.includes('/generationResults/')) throw new Error('simulated storage write failure')
      tx.set(path, data)
    }
  })) }
  let calls = 0
  const f = await fixture({ store, generate: async () => { calls++; return audio() } })
  assert.equal((await f.generation.execute({ memberId: f.memberId, requestId: 'failed-storage', input })).status, 'uncertain')
  let member = await f.store.get(`members/${f.memberId}`)
  assert.equal(member.freeUsed, 0)
  assert.equal(member.freeReserved, 1)
  assert.equal((await f.store.list(`members/${f.memberId}/generationResults`)).length, 0)
  f.setTime(initialTime + 6 * 60_000)
  await assert.rejects(f.generation.getResult({ memberId: f.memberId, requestId: 'failed-storage' }), errorCode('generation_interrupted'))
  member = await f.store.get(`members/${f.memberId}`)
  assert.equal(member.freeReserved, 0)
  assert.equal(calls, 1)
})

test('paid members use one daily generation then a verified reward, preserving failed reward credit', async () => {
  let shouldFail = false
  const f = await fixture({ generate: async () => { if (shouldFail) throw new Error('failure'); return audio() } })
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  await f.generation.execute({ memberId: f.memberId, requestId: 'paid-daily', input })
  await f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay', eventId: 'impression-1', proofId: rewardProof('impression-1') })
  shouldFail = true
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'ad-failed', input }), errorCode('generation_failed'))
  let state = await f.membership.status(f.memberId)
  assert.equal(state.quota.rewardCredits, 1)
  assert.equal(state.quota.freeRemaining, 0, 'paid UI must not promise free credits that require an ad instead')
  const member = await f.store.get(`members/${f.memberId}`)
  assert.equal(member.freeGranted - member.freeUsed, 1, 'paid users must not silently consume old free credits')
  shouldFail = false
  await f.generation.execute({ memberId: f.memberId, requestId: 'ad-success', input })
  state = await f.membership.status(f.memberId)
  assert.equal(state.quota.rewardCredits, 0)
})

test('reward events are deduplicated transactionally and cannot be replayed for another account', async () => {
  const f = await fixture()
  const outcomes = await Promise.all(Array.from({ length: 10 }, () => f.membership.creditVerifiedReward({
    memberId: f.memberId, provider: 'levelplay', eventId: 'shared-reward', proofId: rewardProof('shared-reward') })))
  assert.equal(outcomes.filter((r) => r.credited).length, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardGrantCount, 1)
  const other = await f.membership.recognizeMember(identity({ appTransactionId: 'another-account' }))
  await assert.rejects(f.membership.creditVerifiedReward({ memberId: other.memberId, provider: 'levelplay', eventId: 'shared-reward', proofId: rewardProof('shared-reward') }), errorCode('reward_already_linked'))
})

test('reward grant sequence confirms verified delivery even when another device already consumed the reward', async () => {
  const f = await fixture()
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  await f.generation.execute({ memberId: f.memberId, requestId: 'reward-count-daily', input })
  const before = await f.membership.status(f.memberId)
  await f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay', eventId: 'consumed-on-other-device', proofId: rewardProof('consumed-on-other-device') })
  await f.generation.execute({ memberId: f.memberId, requestId: 'reward-count-other-device', input })
  const after = await f.membership.status(f.memberId)
  assert.equal(before.quota.rewardCredits, 0)
  assert.equal(after.quota.rewardCredits, 0)
  assert.equal(after.quota.rewardGrantCount, before.quota.rewardGrantCount + 1)
  await f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay', eventId: 'consumed-on-other-device', proofId: rewardProof('consumed-on-other-device') })
  assert.equal((await f.membership.status(f.memberId)).quota.rewardGrantCount, after.quota.rewardGrantCount)
})

test('one verified payload fingerprint cannot grant under multiple event IDs and missing proof is rejected', async () => {
  const f = await fixture()
  const common = { memberId: f.memberId, provider: 'levelplay', proofId: rewardProof('one-authenticated-payload') }
  const outcomes = await Promise.all([
    f.membership.creditVerifiedReward({ ...common, eventId: '123abc' }),
    f.membership.creditVerifiedReward({ ...common, eventId: 'abc' })
  ])
  assert.equal(outcomes.filter((result) => result.credited).length, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
  await assert.rejects(f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay',
    eventId: 'missing-proof' }), errorCode('invalid_verified_reward'))
})

test('lifetime and subscription share one daily generation; lifetime calendar survives subscription expiry', async () => {
  const f = await fixture()
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ productId: products.lifetime,
    originalTransactionId: 'lifetime-chain', transactionId: 'lifetime-1', expiresDate: null }))
  let state = await f.membership.status(f.memberId)
  assert.equal(state.quota.dailyRemaining, 1)
  assert.equal(state.entitlements.calendar, true)
  await f.generation.execute({ memberId: f.memberId, requestId: 'both-plans-daily', input })
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'both-plans-extra', input }), errorCode('quota_exhausted'))
  f.setTime(initialTime + 2 * 86_400_000)
  state = await f.membership.status(f.memberId)
  assert.equal(state.entitlements.calendar, true)
  assert.equal(state.entitlements.subscriptionActive, false)
  assert.equal(state.entitlements.lifetimeActive, true)
  assert.equal(state.entitlements.temporaryClosures, true, 'the one-time purchase keeps the day-off rule after the subscription lapses')
  assert.equal(state.entitlements.removeBanner, true)
  assert.equal(state.entitlements.dailyAI, true)
})

test('lifetime alone grants calendar until a verified refund and delayed restore cannot regrant it', async () => {
  const f = await fixture()
  const lifetime = f.purchase({ productId: products.lifetime, expiresDate: null })
  let state = await f.membership.applyVerifiedPurchase(f.memberId, lifetime)
  assert.equal(state.entitlements.calendar, true)
  assert.equal(state.entitlements.temporaryClosures, true, 'the one-time purchase alone includes the day-off rule')
  assert.equal(state.entitlements.subscriptionActive, false)
  assert.equal(state.entitlements.removeBanner, true)
  assert.equal(state.quota.dailyRemaining, 1)
  await f.membership.applyVerifiedNotification({ notificationId: 'lifetime-refund', purchase: {
    ...lifetime, signedDate: initialTime + 1000, revocationDate: initialTime + 1000 } })
  state = await f.membership.applyVerifiedPurchase(f.memberId, lifetime)
  assert.equal(state.entitlements.lifetimeActive, false)
  assert.equal(state.entitlements.calendar, false)
  assert.equal(state.entitlements.temporaryClosures, false, 'a refunded one-time purchase loses the day-off rule')
  assert.equal(state.entitlements.removeBanner, false)
  assert.equal(state.entitlements.dailyAI, false)
})

test('refunding either plan keeps calendar from the other verified paid plan', async () => {
  for (const refundLifetime of [false, true]) {
    const f = await fixture()
    const monthly = f.purchase()
    const lifetime = f.purchase({ productId: products.lifetime, originalTransactionId: 'lifetime-chain',
      transactionId: 'lifetime-1', expiresDate: null })
    await f.membership.applyVerifiedPurchase(f.memberId, monthly)
    await f.membership.applyVerifiedPurchase(f.memberId, lifetime)
    await f.membership.applyVerifiedNotification({ notificationId: 'one-plan-refund', purchase: {
      ...(refundLifetime ? lifetime : monthly), signedDate: initialTime + 1000, revocationDate: initialTime + 1000 } })
    const state = await f.membership.status(f.memberId)
    assert.equal(state.entitlements.calendar, true)
    assert.equal(state.entitlements.temporaryClosures, true)
    assert.equal(state.entitlements.removeBanner, true)
    assert.equal(state.entitlements.dailyAI, true)
    assert.equal(state.entitlements.lifetimeActive, !refundLifetime)
    assert.equal(state.entitlements.subscriptionActive, refundLifetime)
    assert.equal(state.quota.dailyRemaining, 1)
  }
})

test('the day-off rule comes with either paid plan and never with the free tier', async () => {
  const f = await fixture()
  assert.equal((await f.membership.status(f.memberId)).entitlements.temporaryClosures, false, 'free members do not get the day-off rule')
  const derive = (purchases) => deriveEntitlements(purchases, initialTime, products).temporaryClosures
  assert.equal(derive([]), false)
  assert.equal(derive([f.purchase()]), true, 'monthly subscription')
  assert.equal(derive([f.purchase({ productId: products.yearly })]), true, 'yearly subscription')
  assert.equal(derive([f.purchase({ productId: products.lifetime, expiresDate: null })]), true, 'one-time purchase')
  assert.equal(derive([f.purchase({ expiresDate: initialTime - 1 })]), false, 'expired subscription')
  assert.equal(derive([f.purchase({ productId: products.lifetime, expiresDate: null, revocationDate: initialTime - 1 })]), false, 'refunded one-time purchase')
})

test('duplicate notifications, delayed renewals, refunds and reconciliation preserve latest chain state', async () => {
  const f = await fixture()
  const old = f.purchase()
  await f.membership.applyVerifiedPurchase(f.memberId, old)
  const renewal = f.purchase({ transactionId: 'txn-2', purchaseDate: initialTime + 500, signedDate: initialTime + 1000,
    expiresDate: initialTime + 10 * 86_400_000 })
  const event = { notificationId: 'renewal-event', purchase: renewal }
  const results = await Promise.all([f.membership.applyVerifiedNotification(event), f.membership.applyVerifiedNotification(event)])
  assert.equal(results.filter((r) => r.duplicate).length, 1)
  await f.membership.reconcileVerifiedPurchases(f.memberId, [renewal, old])
  assert.equal((await f.membership.status(f.memberId)).subscriptionExpiresAt, renewal.expiresDate)
  await f.membership.applyVerifiedNotification({ notificationId: 'refund-old', purchase: {
    ...old, signedDate: initialTime + 2000, revocationDate: initialTime + 2000 } })
  assert.equal((await f.membership.status(f.memberId)).entitlements.removeBanner, true)
  await f.membership.applyVerifiedNotification({ notificationId: 'refund-current', purchase: {
    ...renewal, signedDate: initialTime + 3000, revocationDate: initialTime + 3000 } })
  assert.equal((await f.membership.status(f.memberId)).entitlements.removeBanner, false)
  await f.membership.applyVerifiedPurchase(f.memberId, renewal)
  assert.equal((await f.membership.status(f.memberId)).entitlements.removeBanner, false)
})

test('server-verified billing grace is honored only until grace expiry', async () => {
  const f = await fixture()
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ expiresDate: initialTime - 1, status: 3 }))
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ expiresDate: initialTime - 1,
    status: 4, statusVerifiedAt: initialTime + 1, gracePeriodExpiresDate: initialTime + 60_000 }))
  assert.equal((await f.membership.status(f.memberId)).entitlements.calendar, true)
  f.setTime(initialTime + 60_000)
  assert.equal((await f.membership.status(f.memberId)).entitlements.calendar, false)
})

test('subscription card exposes verified current product and renewal while preserving paid time after cancellation', async () => {
  const f = await fixture()
  assert.equal(f.state.entitlements.subscriptionProductId, null)
  assert.equal(f.state.entitlements.subscriptionAutoRenews, null)
  const purchase = f.purchase({ autoRenewStatus: 1, autoRenewProductId: products.monthly, renewalSignedAt: initialTime })
  let state = await f.membership.applyVerifiedPurchase(f.memberId, purchase)
  assert.equal(state.entitlements.subscriptionProductId, products.monthly)
  assert.equal(state.entitlements.subscriptionAutoRenews, true)
  assert.equal(state.entitlements.subscriptionRenewalProductId, products.monthly)
  await f.membership.applyVerifiedNotification({ notificationId: 'turn-off-renewal', purchase: {
    ...purchase, autoRenewStatus: 0, renewalSignedAt: initialTime + 1000 } })
  state = await f.membership.status(f.memberId)
  assert.equal(state.entitlements.subscriptionActive, true)
  assert.equal(state.entitlements.subscriptionAutoRenews, false)
  assert.equal(state.subscriptionExpiresAt, purchase.expiresDate)
  f.setTime(purchase.expiresDate)
  state = await f.membership.status(f.memberId)
  assert.equal(state.entitlements.subscriptionActive, false)
  assert.equal(state.entitlements.subscriptionProductId, null)
  assert.equal(state.entitlements.subscriptionAutoRenews, null)
  assert.equal(state.entitlements.subscriptionRenewalProductId, null)
})

test('fresh renewal preferences survive re-signed transactions, delayed events and reconciliation order', async () => {
  const f = await fixture()
  const purchase = f.purchase({ status: 1, statusVerifiedAt: initialTime, autoRenewStatus: 1,
    autoRenewProductId: products.monthly, renewalSignedAt: initialTime })
  await f.membership.applyVerifiedPurchase(f.memberId, purchase)
  const cancelled = { ...purchase, autoRenewStatus: 0, renewalSignedAt: initialTime + 2000 }
  const notification = { notificationId: 'cancel-latest', purchase: cancelled }
  await f.membership.applyVerifiedNotification(notification)
  assert.equal((await f.membership.applyVerifiedNotification(notification)).duplicate, true)
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ signedDate: initialTime + 3000 }))
  await f.membership.applyVerifiedNotification({ notificationId: 'outdated-renewal', purchase: {
    ...purchase, signedDate: initialTime + 4000, renewalSignedAt: initialTime + 1000 } })
  await f.membership.reconcileVerifiedPurchases(f.memberId, [cancelled, purchase])
  const state = await f.membership.status(f.memberId)
  assert.equal(state.entitlements.subscriptionAutoRenews, false)
  assert.equal(state.entitlements.subscriptionActive, true)
  const rows = await f.store.list(`members/${f.memberId}/purchases`)
  assert.equal(rows[0].data.status, 1)
  assert.equal(rows[0].data.renewalSignedAt, initialTime + 2000)
})

test('verified newer status survives fresh raw transaction and delayed status, refund clears active plan', async () => {
  const f = await fixture()
  const purchase = f.purchase({ status: 1, statusVerifiedAt: initialTime, autoRenewStatus: 1,
    autoRenewProductId: products.monthly, renewalSignedAt: initialTime })
  await f.membership.applyVerifiedPurchase(f.memberId, purchase)
  await f.membership.applyVerifiedNotification({ notificationId: 'expired-status', purchase: {
    ...purchase, status: 2, statusVerifiedAt: initialTime + 2000 } })
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ signedDate: initialTime + 3000 }))
  await f.membership.applyVerifiedNotification({ notificationId: 'late-active', purchase: {
    ...purchase, signedDate: initialTime + 4000, statusVerifiedAt: initialTime + 1000 } })
  assert.equal((await f.membership.status(f.memberId)).entitlements.subscriptionProductId, null)
  await f.membership.applyVerifiedNotification({ notificationId: 'refund-card', purchase: {
    ...purchase, signedDate: initialTime + 5000, status: 5, statusVerifiedAt: initialTime + 5000,
    revocationDate: initialTime + 5000 } })
  const state = await f.membership.status(f.memberId)
  assert.equal(state.entitlements.subscriptionActive, false)
  assert.equal(state.entitlements.subscriptionAutoRenews, null)
  assert.equal(state.entitlements.subscriptionRenewalProductId, null)
})

test('scheduled product changes keep the current plan until the replacement transaction arrives', async () => {
  const f = await fixture()
  const purchase = f.purchase({ autoRenewStatus: 1, autoRenewProductId: products.yearly, renewalSignedAt: initialTime })
  let state = await f.membership.applyVerifiedPurchase(f.memberId, purchase)
  assert.equal(state.entitlements.subscriptionProductId, products.monthly)
  assert.equal(state.entitlements.subscriptionRenewalProductId, products.yearly)
  state = await f.membership.applyVerifiedPurchase(f.memberId, { ...purchase, productId: products.yearly,
    transactionId: 'yearly-next', purchaseDate: initialTime + 1000, signedDate: initialTime + 1000,
    expiresDate: initialTime + 365 * 86_400_000 })
  assert.equal(state.entitlements.subscriptionProductId, products.yearly)
  assert.equal(state.entitlements.subscriptionRenewalProductId, products.yearly)
})

test('missing renewal proof stays unknown and cannot imply disabled or enabled auto-renewal', async () => {
  const f = await fixture()
  let state = await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  assert.equal(state.entitlements.subscriptionProductId, products.monthly)
  assert.equal(state.entitlements.subscriptionAutoRenews, null)
  assert.equal(state.entitlements.subscriptionRenewalProductId, null)
  state = await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ signedDate: initialTime + 1000,
    autoRenewStatus: 1, autoRenewProductId: products.yearly }))
  assert.equal(state.entitlements.subscriptionAutoRenews, null, 'unversioned preference cannot be presented as verified')
  assert.equal(state.entitlements.subscriptionRenewalProductId, null)
})

test('purchase identity, product, bundle and environment cannot be self-asserted across accounts', async () => {
  const f = await fixture()
  for (const change of [{ appTransactionId: 'another-account' }, { bundleId: 'another.bundle' }, { environment: 'Production' },
    { appTransactionId: null, appAccountToken: null }, { productId: 'unapproved.product' }]) {
    await assert.rejects(f.membership.applyVerifiedPurchase(f.memberId, f.purchase(change)))
  }
})

test('server midnight resets once; finishing yesterday reservation after midnight charges yesterday only', async () => {
  let complete
  const f = await fixture({ generate: async () => new Promise((resolve) => { complete = resolve }) })
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  const boundary = (await f.membership.status(f.memberId)).quota.nextResetAt
  f.setTime(boundary - 1000)
  const first = f.generation.execute({ memberId: f.memberId, requestId: 'before-midnight', input })
  while (!complete) await new Promise((resolve) => setImmediate(resolve))
  f.setTime(boundary + 1000)
  assert.equal((await f.membership.status(f.memberId)).quota.dailyRemaining, 1)
  complete(audio())
  await first
  assert.equal((await f.membership.status(f.memberId)).quota.dailyRemaining, 1)
})

test('timezone changes are deferred and cannot split or reset a shared member quota', async () => {
  const f = await fixture()
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  await f.generation.execute({ memberId: f.memberId, requestId: 'before-travel', input })
  const before = await f.membership.status(f.memberId)
  const changed = await f.membership.setTimeZone(f.memberId, 'America/Los_Angeles')
  assert.equal(changed.quota.timeZone, 'Asia/Taipei')
  assert.equal(changed.quota.nextResetAt, before.quota.nextResetAt)
  assert.equal(changed.quota.dailyRemaining, 0)
  f.setTime(before.quota.nextResetAt + 1)
  const delayed = await f.membership.status(f.memberId)
  assert.equal(delayed.quota.timeZone, 'Asia/Taipei', 'initial zone stays for at least 24h')
  assert.equal(delayed.quota.pendingTimeZone, 'America/Los_Angeles')
  f.setTime(delayed.quota.nextResetAt + 1)
  // Keep subscription active for the second boundary in this test.
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ transactionId: 'renewed-travel',
    purchaseDate: f.clock(), signedDate: f.clock(), expiresDate: f.clock() + 7 * 86_400_000 }))
  const after = await f.membership.status(f.memberId)
  assert.equal(after.quota.timeZone, 'America/Los_Angeles')
  assert.equal(after.quota.dailyRemaining, 1)
  await f.generation.execute({ memberId: f.memberId, requestId: 'after-zone-change', input })
  const flip = await f.membership.setTimeZone(f.memberId, 'Pacific/Kiritimati')
  assert.equal(flip.quota.dailyRemaining, 0)
  assert.equal(flip.quota.timeZone, 'America/Los_Angeles')
  f.setTime(after.quota.nextResetAt + 1)
  const next = await f.membership.status(f.memberId)
  assert.equal(next.quota.timeZone, 'America/Los_Angeles', 'rapid flip cannot apply another zone inside 24h')
  assert.equal(next.quota.pendingTimeZone, 'Pacific/Kiritimati')
  await assert.rejects(f.membership.setTimeZone(f.memberId, 'not/a-timezone'))
})

test('local midnight follows DST rather than assuming every day is 24 hours', () => {
  assert.equal(nextMidnight(Date.parse('2026-03-08T08:00:00Z'), 'America/Los_Angeles'), Date.parse('2026-03-09T07:00:00Z'))
  assert.equal(nextMidnight(Date.parse('2026-11-01T07:00:00Z'), 'America/Los_Angeles'), Date.parse('2026-11-02T08:00:00Z'))
})

test('crashed worker lease becomes terminal, restores quota, and cannot complete late or regenerate on retry', async () => {
  let complete
  let calls = 0
  const f = await fixture({ generate: async () => { calls++; return new Promise((resolve) => { complete = resolve }) } })
  const pending = f.generation.execute({ memberId: f.memberId, requestId: 'crashed-worker', input })
  // Attach a handler immediately because expiration intentionally rejects it.
  const outcome = pending.then((v) => ({ value: v }), (error) => ({ error }))
  while (!complete) await new Promise((resolve) => setImmediate(resolve))
  f.setTime(initialTime + 6 * 60_000)
  await assert.rejects(f.generation.getResult({ memberId: f.memberId, requestId: 'crashed-worker' }), errorCode('generation_interrupted'))
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 1)
  complete(audio())
  assert.equal((await outcome).error.code, 'generation_interrupted')
  await assert.rejects(f.generation.execute({ memberId: f.memberId, requestId: 'crashed-worker', input }), errorCode('generation_interrupted'))
  assert.equal(calls, 1)
})

test('legacy balances are quarantined once without trusting or wiping client credit claims', async () => {
  const f = await fixture({ user: identity({ originalPurchaseDate: cutoff - 1000 }) })
  assert.equal(f.state.quota.migrationPending, true)
  assert.equal(f.state.quota.freeRemaining, 1)
  const claim = { migrationId: 'legacy-device-migration', claimedFreeRemaining: 2, claimedRewardCredits: 40 }
  assert.equal((await f.membership.quarantineLegacyMigration(f.memberId, claim)).accepted, true)
  assert.equal((await f.membership.quarantineLegacyMigration(f.memberId, { ...claim, claimedRewardCredits: 80 })).accepted, false)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 0)
  const member = await f.store.get(`members/${f.memberId}`)
  assert.equal(member.legacyMigration.claimedRewardCredits, 40)
})

test('legacy welcome is usable once across concurrent devices and cannot be reclaimed after deletion', async () => {
  const user = identity({ originalPurchaseDate: cutoff - 1000 })
  const f = await fixture({ user })
  const devices = await Promise.all(Array.from({ length: 8 }, () => f.membership.recognizeMember(user)))
  assert.ok(devices.every((s) => s.memberId === f.memberId && s.quota.freeRemaining === 1))
  const attempts = await Promise.allSettled(Array.from({ length: 8 }, (_, i) =>
    f.generation.execute({ memberId: f.memberId, requestId: `legacy-welcome-${i}`, input })))
  assert.equal(attempts.filter((r) => r.status === 'fulfilled').length, 1)
  assert.equal((await f.membership.recognizeMember(user)).quota.freeRemaining, 0)
  await f.membership.deleteMember(f.memberId)
  assert.equal((await f.membership.recognizeMember(user)).quota.freeRemaining, 0)
})

test('pre-policy quarantined members receive the fixed grant once without spending their claimed ads', async () => {
  const f = await fixture({ user: identity({ originalPurchaseDate: cutoff - 1000 }) })
  const path = `members/${f.memberId}`
  const member = await f.store.get(path)
  await f.store.set(path, { ...member, freeGranted: 0, legacyWelcomeGranted: false,
    legacyMigration: { state: 'quarantined', claimedRewardCredits: 40 } })
  const states = await Promise.all(Array.from({ length: 8 }, () => f.membership.status(f.memberId)))
  assert.ok(states.every((s) => s.quota.freeRemaining === 1 && s.quota.rewardCredits === 0))
  await f.generation.execute({ memberId: f.memberId, requestId: 'legacy-upgrade', input })
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 0)
  assert.equal((await f.store.get(path)).legacyMigration.claimedRewardCredits, 40)
})

test('a new request recovers a crashed reservation even if reinstall lost the original request id', async () => {
  let complete
  let calls = 0
  const f = await fixture({ generate: async () => {
    calls++
    if (calls === 1) return new Promise((resolve) => { complete = resolve })
    return audio()
  } })
  await f.membership.applyVerifiedPurchase(f.memberId, f.purchase())
  const pending = f.generation.execute({ memberId: f.memberId, requestId: 'lost-old-request', input }).catch((e) => e)
  while (!complete) await new Promise((resolve) => setImmediate(resolve))
  f.setTime(initialTime + 6 * 60_000)
  const result = await f.generation.execute({ memberId: f.memberId, requestId: 'reinstalled-request', input })
  assert.equal(result.status, 'succeeded')
  assert.equal((await f.membership.status(f.memberId)).quota.dailyRemaining, 0)
  complete(audio())
  assert.equal((await pending).code, 'generation_interrupted')
  assert.equal(calls, 2)
})

test('deleting member removes audio and purchases but cannot create fresh free/daily quota or replay a reward', async () => {
  const f = await fixture()
  const purchase = f.purchase({ productId: products.lifetime, expiresDate: null })
  await f.membership.applyVerifiedPurchase(f.memberId, purchase)
  await f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay', eventId: 'before-delete', proofId: rewardProof('before-delete') })
  await f.generation.execute({ memberId: f.memberId, requestId: 'before-delete-job', input })
  assert.deepEqual(await f.membership.deleteMember(f.memberId), { deleted: true, subscriptionCancelled: false })
  assert.deepEqual(await f.membership.deleteMember(f.memberId), { deleted: true, subscriptionCancelled: false })
  assert.equal((await f.store.list(`members/${f.memberId}/generationResults`)).length, 0)
  assert.equal((await f.store.list(`members/${f.memberId}/purchases`)).length, 0)
  await assert.rejects(f.membership.status(f.memberId), errorCode('membership_not_found'))
  const recreated = await f.membership.recognizeMember(identity())
  assert.notEqual(recreated.memberId, f.memberId)
  assert.equal(recreated.quota.freeRemaining, 0)
  const restored = await f.membership.applyVerifiedPurchase(recreated.memberId, purchase)
  assert.equal(restored.entitlements.lifetimeActive, true)
  assert.equal(restored.quota.dailyRemaining, 0)
  assert.equal((await f.membership.creditVerifiedReward({ memberId: recreated.memberId, provider: 'levelplay', eventId: 'before-delete', proofId: rewardProof('before-delete') })).credited, false)
})

test('deleting a member during generation blocks late result persistence and new reward/purchase writes', async () => {
  let complete
  const f = await fixture({ generate: async () => new Promise((resolve) => { complete = resolve }) })
  const pending = f.generation.execute({ memberId: f.memberId, requestId: 'deleting-worker', input }).catch((e) => e)
  while (!complete) await new Promise((resolve) => setImmediate(resolve))
  await f.membership.deleteMember(f.memberId)
  complete(audio())
  assert.equal((await pending).code, 'membership_not_found')
  await assert.rejects(f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay', eventId: 'after-delete', proofId: rewardProof('after-delete') }), errorCode('membership_not_found'))
  await assert.rejects(f.membership.applyVerifiedPurchase(f.memberId, f.purchase()), errorCode('membership_not_found'))
  assert.equal((await f.store.list(`members/${f.memberId}/generationResults`)).length, 0)
})

test('failed transaction rolls back the entire memory state, enforcing Firestore read-before-write', async () => {
  const store = createMemoryStore()
  await assert.rejects(store.runTransaction(async (tx) => { tx.set('test/doc', { value: 1 }); await tx.get('test/doc') }), /read_after_write/)
  assert.equal(await store.get('test/doc'), null)
})

test('Firestore Emulator uses real transactions for concurrent allowance, result replay and event deduplication', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST ? 'Set FIRESTORE_EMULATOR_HOST to run real Firestore integration (no production fallback).' : false
}, async () => {
  // Requiring the SDK only in this test keeps pure domain tests portable.
  const { Firestore } = require('@google-cloud/firestore')
  const firestore = new Firestore({ projectId: 'rainyclock-membership-emulator', ssl: false })
  const namespace = `integration_${randomUUID().replaceAll('-', '')}`
  const store = createFirestoreStore({ firestore, namespace })
  try {
    let calls = 0
    const f = await fixture({ store, generate: async () => { calls++; return audio() } })
    await f.membership.applyVerifiedPurchase(f.memberId, f.purchase({ autoRenewStatus: 1,
      autoRenewProductId: products.monthly, renewalSignedAt: initialTime }))
    const preferenceEvents = [
      { notificationId: 'emulator-renewal-cancel', purchase: f.purchase({ autoRenewStatus: 0,
        autoRenewProductId: products.monthly, renewalSignedAt: initialTime + 2000 }) },
      { notificationId: 'emulator-renewal-delayed', purchase: f.purchase({ signedDate: initialTime + 3000,
        autoRenewStatus: 1, autoRenewProductId: products.monthly, renewalSignedAt: initialTime + 1000 }) }
    ]
    await Promise.all([...preferenceEvents, preferenceEvents[0]].map((event) => f.membership.applyVerifiedNotification(event)))
    const subscriptionState = await f.membership.status(f.memberId)
    assert.equal(subscriptionState.entitlements.subscriptionProductId, products.monthly)
    assert.equal(subscriptionState.entitlements.subscriptionAutoRenews, false)
    assert.equal(subscriptionState.entitlements.subscriptionActive, true)
    const results = await Promise.allSettled(Array.from({ length: 8 }, (_, n) =>
      f.generation.execute({ memberId: f.memberId, requestId: `emulator-${n}`, input })))
    assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1)
    assert.equal(calls, 1)
    const winner = results.findIndex((r) => r.status === 'fulfilled')
    const replay = await f.generation.execute({ memberId: f.memberId, requestId: `emulator-${winner}`, input })
    assert.deepEqual(replay.pcm, audio().pcm)
    await Promise.all(Array.from({ length: 5 }, () => f.membership.creditVerifiedReward({
      memberId: f.memberId, provider: 'levelplay', eventId: 'emulator-reward', proofId: rewardProof('emulator-reward') })))
    assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
    assert.equal((await f.membership.creditVerifiedReward({ memberId: f.memberId, provider: 'levelplay',
      eventId: 'reinterpreted-event', proofId: rewardProof('emulator-reward') })).credited, false)
    const refusing = createGenerationService({ membership: f.membership, generate: async () => { throw new Error('test upstream failure') } })
    await assert.rejects(refusing.execute({ memberId: f.memberId, requestId: 'emulator-failure', input }), errorCode('generation_failed'))
    assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
    const event = { notificationId: 'emulator-refund', purchase: f.purchase({ signedDate: initialTime + 4000, revocationDate: initialTime + 4000 }) }
    await Promise.all([f.membership.applyVerifiedNotification(event), f.membership.applyVerifiedNotification(event)])
    assert.equal((await f.membership.status(f.memberId)).entitlements.removeBanner, false)
    assert.equal((await f.membership.status(f.memberId)).entitlements.subscriptionProductId, null)
    f.setTime(initialTime + 86_400_000)
    const restoredDevice = await f.membership.recognizeMember(identity())
    assert.equal(restoredDevice.memberId, f.memberId)
    assert.equal(restoredDevice.quota.freeRemaining, 1)
    await f.membership.deleteMember(f.memberId)
    assert.equal((await store.list(`members/${f.memberId}/generationResults`)).length, 0)
    assert.equal((await store.list('notifications', { where: [{ field: 'memberId', op: '==', value: f.memberId }] })).length, 0)
  } finally {
    await firestore.recursiveDelete(firestore.doc(`membershipNamespaces/${namespace}`))
    await firestore.terminate()
  }
})
