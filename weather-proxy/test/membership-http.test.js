'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { createHash } = require('node:crypto')
const { createMemoryStore } = require('../membership/store')
const { createPolicy } = require('../membership/policy')
const { createMembershipService } = require('../membership/service')
const { createGenerationService } = require('../membership/generation')
const { createMembershipHandler, requestFailureLine } = require('../membership/http')
const { createLevelPlayVerifier } = require('../membership/rewards')
const { cleanupDeletedMembers } = require('../membership/maintenance')
const { products, validateInput } = require('../membership/runtime')

const clockValue = Date.parse('2026-09-16T04:00:00Z')
const privateKey = 'local-http-test-only-levelplay-secret'
const identity = { environment: 'Sandbox', appTransactionId: 'test-apple-user',
  bundleId: 'com.shukaihu.RainyClock', originalPurchaseDate: clockValue - 1000 }
const purchase = { ...identity, transactionId: 'test-tx', originalTransactionId: 'test-chain',
  productId: products.monthly, purchaseDate: clockValue - 500, signedDate: clockValue,
  expiresDate: clockValue + 86400000, revocationDate: null, appAccountToken: null }
const input = { text: 'Good morning.', persona: 'steady', language: 'en' }

async function fixture(t) {
  const store = createMemoryStore()
  const membership = createMembershipService({ store, products, clock: () => clockValue,
    policy: createPolicy({ migrationCutoverAt: clockValue - 86400000 }), identityHashSecret: 'local-http-test-identity-secret-not-live' })
  let calls = 0, currentMember, cleanupFails = false, syncFails = false, rawReceived
  let history = [], notification
  const auth = {
    async issueChallenge(body) { assert.equal(body.purpose, 'bootstrap'); return { id: 'test-challenge', challenge: 'test-random', expiresAt: clockValue + 300000 } },
    async bootstrapIdentityAndDevice({ rawBody, headers, method, path }) {
      assert.equal(method, 'POST'); assert.equal(path, '/v1/membership/session')
      if (headers['x-test-proof'] !== 'fixture-only') throw Object.assign(new Error(), { code: 'invalid_apple_proof', statusCode: 401 })
      rawReceived = rawBody
      const body = JSON.parse(rawBody)
      return { identity, timeZone: body.timeZone, signedTransactions: body.signedTransactions || [] }
    },
    async issueSession({ memberId }) { currentMember = memberId; return { token: 'local-test-token', expiresAt: clockValue + 86400000, memberId } },
    async authenticate({ token, rawBody, method, path }) {
      if (token !== 'local-test-token') throw Object.assign(new Error(), { code: 'invalid_session', statusCode: 401 })
      assert.equal(method, 'POST'); assert.ok(path.startsWith('/v1/membership/')); assert.ok(Buffer.isBuffer(rawBody))
      const member = await store.get(`members/${currentMember}`)
      if (!member || member.deletedAt) throw Object.assign(new Error(), { code: 'member_deleted', statusCode: 401 })
      return { memberId: currentMember, appTransactionId: identity.appTransactionId, environment: identity.environment }
    },
    async getRewardIdentity(memberId) { assert.equal(memberId, currentMember); return { userId: 'a'.repeat(48) } },
    async resolveRewardMember(userId) {
      if (userId !== 'a'.repeat(48)) throw Object.assign(new Error(), { code: 'unknown_reward_user', statusCode: 401 })
      return currentMember
    },
    async deleteMemberAuth(memberId) {
      if (cleanupFails) throw new Error('injected cleanup outage')
      await store.delete(`authSessions/${memberId}`)
    }
  }
  const apple = {
    async verifyTransaction(jws) {
      if (jws !== 'test-signed-purchase') throw Object.assign(new Error(), { code: 'invalid_apple_proof', statusCode: 401 })
      return purchase
    },
    async reconcile(appId) {
      assert.equal(appId, identity.appTransactionId)
      if (syncFails) throw new Error('injected Apple outage')
      return { transactions: history, checkedAt: clockValue }
    },
    async verifyNotification(jws) {
      if (jws !== 'test-signed-event') throw Object.assign(new Error(), { code: 'invalid_apple_proof', statusCode: 401 })
      return notification
    }
  }
  const generation = createGenerationService({ membership, generate: async () => {
    calls++; return { pcm: Buffer.from([1, 0, 2, 0]), sampleRate: 24000, emotions: ['neutral'] }
  } })
  const logged = []
  const handler = createMembershipHandler({ membership, auth, apple,
    rewards: createLevelPlayVerifier({ privateKey, now: () => clockValue }), generation, validateInput,
    log: (line) => logged.push(line) })
  const server = http.createServer(async (req, res) => {
    if (!await handler(req, res)) { res.writeHead(404); res.end('outside membership') }
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const base = `http://127.0.0.1:${server.address().port}`
  async function request(path, body = {}, { method = 'POST', raw, headers = {} } = {}) {
    const response = await fetch(base + path, { method, headers: { authorization: 'Bearer local-test-token',
      'content-type': 'application/json', ...headers }, body: method === 'GET' ? undefined : (raw ?? JSON.stringify(body)) })
    const text = await response.text()
    return { status: response.status, text, data: text.startsWith('{') ? JSON.parse(text) : null }
  }
  async function bootstrap() {
    const response = await request('/v1/membership/session', { timeZone: 'Asia/Taipei' }, { headers: { 'x-test-proof': 'fixture-only' } })
    assert.equal(response.status, 200)
    return response.data
  }
  function rewardURL(overrides = {}) {
    const query = new URLSearchParams({ timestamp: '202609160400', eventId: 'event-reward-1',
      userId: 'a'.repeat(48), rewards: '1', ...overrides })
    query.set('signature', createHash('md5').update(query.get('timestamp') + query.get('eventId') + query.get('userId') + query.get('rewards') + privateKey).digest('hex'))
    return '/v1/membership/levelplay/callback?' + query
  }
  return { request, bootstrap, membership, auth, store, rewardURL, logged, get memberId() { return currentMember },
    get calls() { return calls }, get rawReceived() { return rawReceived }, setHistory: (value) => { history = value },
    setNotification: (value) => { notification = value }, setCleanupFails: (value) => { cleanupFails = value },
    setSyncFails: (value) => { syncFails = value } }
}

test('HTTP contract recognizes member, reconciles purchase, shares quota and returns a durable replay', async (t) => {
  const f = await fixture(t)
  const session = await f.bootstrap()
  assert.equal(session.state.quota.freeRemaining, 1)
  f.setHistory([purchase])
  const paid = await f.request('/v1/membership/purchases', { signedTransactions: ['test-signed-purchase'] })
  assert.equal(paid.status, 200); assert.equal(paid.data.entitlements.calendar, true)
  const first = await f.request('/v1/membership/generations', { requestId: 'generation-http-1', input })
  assert.equal(first.status, 200); assert.equal(first.data.pcm, 'AQACAA==')
  assert.equal(first.data.state.quota.dailyRemaining, 0)
  const repeated = await f.request('/v1/membership/generations', { requestId: 'generation-http-1', input })
  assert.equal(repeated.data.replayed, true); assert.equal(f.calls, 1)
  const second = await f.request('/v1/membership/generations', { requestId: 'generation-http-2', input })
  assert.equal(second.status, 402); assert.equal(second.data.error, 'quota_exhausted')
  const restored = await f.bootstrap()
  assert.equal(restored.memberId, session.memberId)
  assert.equal(restored.state.quota.dailyRemaining, 0)
})

test('HTTP logs the route, status and error code of a failed request and nothing else', async (t) => {
  const f = await fixture(t)
  // A rejected bootstrap: the 2026-10-03 case (a phone's App Attest assertion refused on every
  // launch) left no trace beyond a 401 in the request log, because this line did not exist.
  const refused = await f.request('/v1/membership/session', { timeZone: 'Asia/Taipei', secret: 'JWS.not-for-logs' })
  assert.equal(refused.status, 401)
  assert.deepEqual(f.logged, [{ event: 'membership_request_failed', severity: 'NOTICE', path: '/v1/membership/session', status: 401, code: 'invalid_apple_proof' }])
  assert.ok(!JSON.stringify(f.logged).includes('not-for-logs'))
  // Successes log nothing here; an unknown route under the prefix logs its 404.
  await f.bootstrap()
  assert.equal(f.logged.length, 1)
  const missing = await f.request('/v1/membership/does-not-exist')
  assert.equal(missing.status, 404)
  assert.deepEqual(f.logged[1], { event: 'membership_request_failed', severity: 'NOTICE', path: '/v1/membership/does-not-exist', status: 404, code: 'not_found' })
  // The line only ever carries a route shape and an identifier shape.
  assert.deepEqual(requestFailureLine('/v1/membership/session?token=abc', 401, 'invalid_assertion'),
    { event: 'membership_request_failed', severity: 'NOTICE', path: 'invalid_path', status: 401, code: 'invalid_assertion' })
  assert.deepEqual(requestFailureLine('/v1/membership/session', 503, 'Bearer eyJhbGciOi'),
    { event: 'membership_request_failed', severity: 'ERROR', path: '/v1/membership/session', status: 503, code: 'unrecognized_code' })
  assert.deepEqual(requestFailureLine('/v1/membership/session', 503, 'x'.repeat(65)).code, 'unrecognized_code')
  // A numeric gRPC status or an object is never echoed as the code; nor is a non-string path.
  assert.deepEqual(requestFailureLine('/v1/membership/status', 503, 14).code, 'unrecognized_code')
  assert.deepEqual(requestFailureLine('/v1/membership/status', 503, { toString: () => 'x' }).code, 'unrecognized_code')
  assert.deepEqual(requestFailureLine(undefined, 503, undefined), { event: 'membership_request_failed', severity: 'ERROR', path: 'invalid_path', status: 503, code: 'unrecognized_code' })
})

test('HTTP passes original body bytes to proof verifier and rejects method/body/auth violations', async (t) => {
  const f = await fixture(t)
  const raw = '{  "timeZone" : "Asia/Taipei", "signedTransactions": [] }'
  const good = await f.request('/v1/membership/session', {}, { raw, headers: { 'x-test-proof': 'fixture-only' } })
  assert.equal(good.status, 200); assert.equal(f.rawReceived.toString(), raw)
  assert.equal((await f.request('/v1/membership/status', {}, { method: 'GET' })).status, 405)
  assert.equal((await f.request('/v1/membership/status', {}, { raw: '{broken' })).status, 400)
  assert.equal((await f.request('/v1/membership/status', {}, { raw: '[]' })).status, 400)
  assert.equal((await f.request('/v1/membership/status', {}, { headers: { authorization: 'Bearer wrong' } })).status, 401)
  assert.equal((await f.request('/v1/membership/session', {})).status, 401)
  assert.equal((await f.request('/v1/membership/not-found', {})).status, 404)
  assert.equal((await f.request('/outside', {})).status, 404)
  assert.equal((await f.request('/v1/membership/status', {}, { raw: JSON.stringify({ text: 'a'.repeat(384001) }) })).status, 413)
})

test('HTTP callback verifies actual LevelPlay signature, credits once and refuses another user or client claim', async (t) => {
  const f = await fixture(t)
  await f.bootstrap()
  const signedURL = f.rewardURL()
  for (let i = 0; i < 2; i++) {
    const response = await f.request(signedURL, {}, { method: 'GET' })
    assert.equal(response.status, 200); assert.equal(response.text, 'event-reward-1:OK')
  }
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
  assert.equal((await f.request(f.rewardURL({ userId: 'b'.repeat(48) }), {}, { method: 'GET' })).status, 401)
  assert.equal((await f.request(signedURL.replace('rewards=1', 'rewards=999'), {}, { method: 'GET' })).status, 401)
  assert.equal((await f.request('/v1/membership/rewards/grant', { completed: true })).status, 404)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
})

test('HTTP LevelPlay timestamp/eventId boundary reinterpretation cannot mint a second reward', async (t) => {
  const f = await fixture(t)
  await f.bootstrap()
  const signedURL = f.rewardURL({ eventId: '123abc' })
  const altered = new URL(signedURL, 'http://localhost')
  altered.searchParams.set('timestamp', altered.searchParams.get('timestamp') + '123')
  altered.searchParams.set('eventId', 'abc')
  // The signed bytes are unchanged, but the alternate timestamp width must
  // be rejected before it can reinterpret the provider's event identity.
  const outcomes = await Promise.all([
    f.request(signedURL, {}, { method: 'GET' }),
    f.request(altered.pathname + altered.search, {}, { method: 'GET' })
  ])
  assert.deepEqual(outcomes.map((result) => result.status), [200, 401])
  const state = await f.membership.status(f.memberId)
  assert.equal(state.quota.rewardCredits, 1)
  assert.equal(state.quota.rewardGrantCount, 1)
  assert.equal((await f.store.list('rewardEvents')).length, 1)
  assert.equal((await f.store.list('rewardProofs')).length, 1)
})

test('HTTP LevelPlay retry with a newly signed timestamp still grants the same event only once', async (t) => {
  const f = await fixture(t)
  await f.bootstrap()
  const original = f.rewardURL({ timestamp: '202609160359' })
  const retry = f.rewardURL({ timestamp: '202609160400' })
  assert.notEqual(new URL(original, 'http://localhost').searchParams.get('signature'),
    new URL(retry, 'http://localhost').searchParams.get('signature'))
  const outcomes = await Promise.all([
    f.request(original, {}, { method: 'GET' }),
    f.request(retry, {}, { method: 'GET' })
  ])
  for (const result of outcomes) {
    assert.equal(result.status, 200)
    assert.equal(result.text, 'event-reward-1:OK')
  }
  assert.equal((await f.membership.status(f.memberId)).quota.rewardGrantCount, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.rewardCredits, 1)
  assert.equal((await f.store.list('rewardEvents')).length, 1)
  assert.equal((await f.store.list('rewardProofs')).length, 1)
})

test('HTTP notifications preserve fresh status evidence, deduplicate, revoke and reject fake signatures', async (t) => {
  const f = await fixture(t)
  await f.bootstrap()
  f.setNotification({ notificationUUID: 'event-subscription', signedDate: clockValue + 1, status: 1,
    transaction: { ...purchase, autoRenewStatus: 0, autoRenewProductId: purchase.productId,
      renewalSignedAt: clockValue + 1 }, renewal: { gracePeriodExpiresDate: null } })
  for (let i = 0; i < 2; i++) assert.equal((await f.request('/v1/membership/apple/notifications', { signedPayload: 'test-signed-event' })).status, 200)
  assert.equal((await f.membership.status(f.memberId)).entitlements.calendar, true)
  assert.equal((await f.membership.status(f.memberId)).entitlements.temporaryClosures, true)
  assert.equal((await f.membership.status(f.memberId)).entitlements.subscriptionProductId, purchase.productId)
  assert.equal((await f.membership.status(f.memberId)).entitlements.subscriptionAutoRenews, false)
  f.setNotification({ notificationUUID: 'event-refund', signedDate: clockValue + 2, status: 5,
    transaction: { ...purchase, signedDate: clockValue + 2, revocationDate: clockValue }, renewal: null })
  assert.equal((await f.request('/v1/membership/apple/notifications', { signedPayload: 'test-signed-event' })).status, 200)
  assert.equal((await f.membership.status(f.memberId)).entitlements.calendar, false)
  assert.equal((await f.membership.status(f.memberId)).entitlements.temporaryClosures, false)
  assert.equal((await f.membership.status(f.memberId)).entitlements.subscriptionProductId, null)
  assert.equal((await f.membership.status(f.memberId)).entitlements.subscriptionAutoRenews, null)
  assert.equal((await f.request('/v1/membership/apple/notifications', { signedPayload: 'forged' })).status, 401)
})

test('HTTP Apple outage cannot generate or debit; durable results remain downloadable', async (t) => {
  const f = await fixture(t)
  await f.bootstrap()
  await f.request('/v1/membership/generations', { requestId: 'before-outage', input })
  f.setSyncFails(true)
  assert.equal((await f.request('/v1/membership/generations', { requestId: 'during-outage', input })).status, 503)
  const download = await f.request('/v1/membership/generations/result', { requestId: 'before-outage' })
  assert.equal(download.status, 200); assert.equal(download.data.pcm, 'AQACAA==')
  assert.equal(f.calls, 1)
  assert.equal((await f.membership.status(f.memberId)).quota.freeRemaining, 0)
})

test('HTTP deletion revokes immediately and durable maintenance resumes interrupted cleanup', async (t) => {
  const f = await fixture(t)
  await f.bootstrap()
  await f.store.set(`authSessions/${f.memberId}`, { memberId: f.memberId })
  f.setCleanupFails(true)
  const response = await f.request('/v1/membership/delete')
  assert.equal(response.status, 202)
  assert.deepEqual(response.data, { deleted: true, subscriptionCancelled: false, cleanupPending: true })
  assert.equal((await f.request('/v1/membership/status')).status, 401)
  assert.equal((await f.store.get(`members/${f.memberId}`)).deletionCleanupState, 'pending')
  assert.equal((await cleanupDeletedMembers({ membership: f.membership, auth: f.auth })).failed, 1)
  f.setCleanupFails(false)
  assert.equal((await cleanupDeletedMembers({ membership: f.membership, auth: f.auth })).completed, 1)
  assert.equal(await f.store.get(`authSessions/${f.memberId}`), null)
  assert.equal((await f.store.get(`members/${f.memberId}`)).deletionCleanupState, 'complete')
  assert.equal((await cleanupDeletedMembers({ membership: f.membership, auth: f.auth })).examined, 0)
})

test('HTTP membership bootstrap challenge is bounded by rate limit', async (t) => {
  const f = await fixture(t)
  let status
  for (let i = 0; i < 121; i++) {
    status = (await f.request('/v1/membership/challenge', { purpose: 'bootstrap' })).status
  }
  assert.equal(status, 429)
})
