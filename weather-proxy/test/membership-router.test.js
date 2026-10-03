'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { createHash } = require('node:crypto')
const { createMembershipServer } = require('../membership/server')
const { runtimeEnvironments } = require('../membership/router')
const { createMembershipHandler } = require('../membership/http')
const { createMembershipAuth, sha256 } = require('../membership/auth')
const { createMemoryStore } = require('../membership/store')
const { createLevelPlayVerifier } = require('../membership/rewards')
const { createVerifiedRewardResolver, withSandboxNotificationForwarding, LEGACY_SANDBOX_NOTIFICATION_URL } = require('../membership/runtime')

const fixtureEnv = { MEMBERSHIP_ENABLED: '1', MEMBERSHIP_SERVER_MODE: 'dual',
  MEMBERSHIP_APPLE_KEY_PATH: '/fixture/not-a-key', MEMBERSHIP_APPLE_KEY_ID: 'fixture',
  MEMBERSHIP_APPLE_ISSUER_ID: 'fixture', MEMBERSHIP_MIGRATION_CUTOVER: '2026-09-21T00:00:00Z',
  MEMBERSHIP_PRODUCTION_IDENTITY_HASH_SECRET: 'fixture-production-identity-secret-only',
  MEMBERSHIP_SANDBOX_IDENTITY_HASH_SECRET: 'fixture-sandbox-identity-secret-only' }

async function fixture(t, createRuntime, env = fixtureEnv) {
  const server = createMembershipServer({ env, createRuntime })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections() }))
  const base = `http://127.0.0.1:${server.address().port}`
  return async (path, { headers = {}, method = 'POST', raw = '{}' } = {}) => {
    const response = await fetch(base + path, { method, headers, body: ['GET', 'HEAD'].includes(method) ? undefined : raw })
    const text = await response.text()
    return { status: response.status, text, data: text.startsWith('{') ? JSON.parse(text) : null }
  }
}

test('dual runtime isolates member databases and namespaces while sharing production App Attest and cost ceiling', () => {
  const configurations = runtimeEnvironments(fixtureEnv)
  const production = configurations.Production, sandbox = configurations.Sandbox
  assert.equal(production.MEMBERSHIP_FIRESTORE_DATABASE, 'membership-production')
  assert.equal(sandbox.MEMBERSHIP_FIRESTORE_DATABASE, 'membership-testflight')
  assert.notEqual(production.MEMBERSHIP_NAMESPACE, sandbox.MEMBERSHIP_NAMESPACE)
  assert.equal(production.MEMBERSHIP_IDENTITY_HASH_SECRET, fixtureEnv.MEMBERSHIP_PRODUCTION_IDENTITY_HASH_SECRET)
  assert.equal(sandbox.MEMBERSHIP_IDENTITY_HASH_SECRET, fixtureEnv.MEMBERSHIP_SANDBOX_IDENTITY_HASH_SECRET)
  assert.notEqual(production.MEMBERSHIP_IDENTITY_HASH_SECRET, sandbox.MEMBERSHIP_IDENTITY_HASH_SECRET)
  for (const [environment, config] of Object.entries(configurations)) {
    assert.equal(config.MEMBERSHIP_APPLE_ENVIRONMENT, environment)
    assert.equal(config.MEMBERSHIP_ATTEST_ENVIRONMENT, 'production')
    assert.equal(config.MEMBERSHIP_TTS_BUDGET_DATABASE, 'membership-production')
  }
  assert.equal(fixtureEnv.MEMBERSHIP_FIRESTORE_DATABASE, undefined, 'caller configuration is not mutated')
  const overrides = runtimeEnvironments({ ...fixtureEnv, MEMBERSHIP_PRODUCTION_FIRESTORE_DATABASE: 'member-live',
    MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE: 'member-beta', MEMBERSHIP_TTS_BUDGET_DATABASE: 'member-cost',
    MEMBERSHIP_PRODUCTION_MIGRATION_CUTOVER: '2026-10-01T00:00:00Z', MEMBERSHIP_SANDBOX_MIGRATION_CUTOVER: '2010-01-01T00:00:00Z' })
  assert.equal(overrides.Production.MEMBERSHIP_TTS_BUDGET_DATABASE, 'member-cost')
  assert.equal(overrides.Sandbox.MEMBERSHIP_TTS_BUDGET_DATABASE, 'member-cost')
  assert.equal(overrides.Production.MEMBERSHIP_MIGRATION_CUTOVER, '2026-10-01T00:00:00Z')
  assert.equal(overrides.Sandbox.MEMBERSHIP_MIGRATION_CUTOVER, '2010-01-01T00:00:00Z')
})

test('invalid dual configuration fails before any listener or partly enabled runtime is returned', () => {
  for (const changes of [
    { MEMBERSHIP_ATTEST_ENVIRONMENT: 'development' },
    { MEMBERSHIP_PRODUCTION_IDENTITY_HASH_SECRET: undefined },
    { MEMBERSHIP_SANDBOX_IDENTITY_HASH_SECRET: undefined },
    { MEMBERSHIP_PRODUCTION_IDENTITY_HASH_SECRET: 'short' },
    { MEMBERSHIP_SANDBOX_IDENTITY_HASH_SECRET: fixtureEnv.MEMBERSHIP_PRODUCTION_IDENTITY_HASH_SECRET },
    { MEMBERSHIP_SERVER_MODE: 'production-typo' },
    { MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE: 'membership-production' },
    { MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE: '(default)' },
    { MEMBERSHIP_SANDBOX_NAMESPACE: 'membership_production_v1' },
    { MEMBERSHIP_TTS_BUDGET_DATABASE: '../invalid' }
  ]) assert.throws(() => createMembershipServer({ env: { ...fixtureEnv, ...changes }, createRuntime: () => async () => true }))
  let created = 0
  assert.throws(() => createMembershipServer({ env: fixtureEnv, createRuntime: () => {
    if (++created === 2) throw new Error('sandbox_configuration_failure')
    return async () => true
  } }), /sandbox_configuration_failure/)
  assert.equal(created, 2)
})

test('dual client requests fail closed without an exact environment hint and do not invoke either runtime', async (t) => {
  let calls = 0
  const request = await fixture(t, () => async () => { calls++; return false })
  for (const value of [undefined, '', 'sandbox', 'Xcode', 'LocalTesting', 'Production, Sandbox', ['Production', 'Sandbox']]) {
    const headers = value === undefined ? {} : { 'X-RC-Apple-Environment': value }
    const response = await request('/v1/membership/session', { headers })
    assert.equal(response.status, 400)
    assert.equal(response.data.error, 'invalid_apple_environment')
  }
  assert.equal(calls, 0)
  assert.deepEqual((await request('/health', { method: 'GET' })).data, { ok: true, membershipEnabled: true })
})

test('raw client bytes and signed path are preserved when dispatching to either runtime', async (t) => {
  const seen = []
  const request = await fixture(t, (config) => createMembershipHandler({ auth: {
    async bootstrapIdentityAndDevice(input) {
      seen.push({ environment: config.MEMBERSHIP_APPLE_ENVIRONMENT, ...input })
      throw Object.assign(new Error(), { code: 'invalid_apple_proof', status: 401 })
    }
  } }))
  const raw = '{ "signedAppTransaction" : "deliberately-invalid-fixture" }'
  for (const environment of ['Sandbox', 'Production']) {
    const response = await request('/v1/membership/session', { raw, headers: {
      'X-RC-Apple-Environment': environment, 'X-RC-Assertion': 'fixture-assertion'
    } })
    assert.equal(response.status, 401)
  }
  assert.deepEqual(seen.map((value) => value.environment), ['Sandbox', 'Production'])
  for (const value of seen) {
    assert.equal(value.rawBody.toString(), raw)
    assert.equal(value.path, '/v1/membership/session')
    assert.equal(value.method, 'POST')
    assert.equal(value.headers['x-rc-assertion'], 'fixture-assertion')
  }
})

test('changing the routing hint cannot use a valid Sandbox session against Production storage', async (t) => {
  const stores = { Sandbox: createMemoryStore(), Production: createMemoryStore() }
  const token = 'a'.repeat(43), keyID = Buffer.alloc(32, 1).toString('base64')
  const keyHash = sha256(keyID), now = Date.now()
  await stores.Sandbox.set(`authSessions/${sha256(token)}`, { memberId: 'test-member', deviceKeyHash: keyHash,
    bootstrapId: 'test-bootstrap', appTransactionId: 'test-app', appleEnvironment: 'Sandbox', expiresAt: now + 60000 })
  await stores.Sandbox.set(`authDevices/${keyHash}`, { keyID, memberId: 'test-member', publicKey: 'fixture-public-key',
    bootstrapId: 'test-bootstrap', appTransactionId: 'test-app', appleEnvironment: 'Sandbox', signCount: 0 })
  await stores.Sandbox.set('members/test-member', { id: 'test-member' })
  const request = await fixture(t, (config) => {
    const environment = config.MEMBERSHIP_APPLE_ENVIRONMENT
    const auth = createMembershipAuth({ store: stores[environment],
      appleVerifier: {}, attestationVerifier: { async verifyAssertion() { return { signCount: 1 } } } })
    return createMembershipHandler({ auth, apple: { async reconcile() { return { transactions: [] } } },
      generation: { async recoverAbandoned() {} }, membership: { async reconcileVerifiedPurchases() { return { environment } } } })
  })
  const headers = { 'X-RC-Apple-Environment': 'Sandbox', 'X-RC-Key-ID': keyID, authorization: `Bearer ${token}` }
  const challenge = await request('/v1/membership/challenge', { headers,
    raw: JSON.stringify({ purpose: 'request', keyID, sessionToken: token }) })
  assert.equal(challenge.status, 200)
  headers['X-RC-Challenge'] = challenge.data.id
  headers['X-RC-Assertion'] = 'fixture-assertion'
  const crossed = await request('/v1/membership/status', { headers: { ...headers, 'X-RC-Apple-Environment': 'Production' } })
  assert.equal(crossed.status, 401)
  assert.equal(crossed.data.error, 'invalid_session')
  const valid = await request('/v1/membership/status', { headers })
  assert.equal(valid.status, 200)
  assert.equal(valid.data.environment, 'Sandbox')
  assert.equal((await stores.Production.list('members')).length, 0)
  assert.equal((await request('/v1/membership/status', { headers })).status, 401, 'original assertion remains single-use')
})

test('notification suffix selects a strict verifier; header spoofing and unsuffixed callback do not change it', async (t) => {
  const accepted = []
  const request = await fixture(t, (config) => createMembershipHandler({ apple: {
    async verifyNotification(proof) {
      // Router integration uses test-only proof labels. Cryptographic JWS and
      // signed environment validation are exercised in membership-security.test.
      if (proof !== `fixture-proof-${config.MEMBERSHIP_APPLE_ENVIRONMENT}`) {
        throw Object.assign(new Error(), { status: 401, code: 'invalid_apple_proof' })
      }
      accepted.push(config.MEMBERSHIP_APPLE_ENVIRONMENT)
      return { notificationUUID: 'test-notification', transaction: null }
    }
  } }))
  const base = '/v1/membership/apple/notifications'
  const raw = JSON.stringify({ signedPayload: 'fixture-proof-Sandbox' })
  assert.equal((await request(base + '/sandbox', { raw, headers: { 'X-RC-Apple-Environment': 'Production' } })).status, 200)
  assert.equal((await request(base + '/production', { raw, headers: { 'X-RC-Apple-Environment': 'Sandbox' } })).status, 401)
  for (const suffix of ['', '/Sandbox', '/xcode', '/sandbox/extra', '/%73andbox', '/constructor', '/__proto__']) {
    assert.equal((await request(base + suffix, { raw, headers: { 'X-RC-Apple-Environment': 'Sandbox' } })).status, 404)
  }
  assert.deepEqual(accepted, ['Sandbox'])
})

test('LevelPlay callback keeps signed query intact and cannot credit the other environment member', async (t) => {
  const privateKey = 'router-fixture-only-levelplay-secret', now = Date.now(), userId = 'a'.repeat(48)
  const stores = { Production: createMemoryStore(), Sandbox: createMemoryStore() }
  await stores.Sandbox.set(`authRewardUsers/${userId}`, { memberId: 'reward-test-member' })
  await stores.Sandbox.set('members/reward-test-member', { id: 'reward-test-member' })
  const credited = []
  const request = await fixture(t, (config) => {
    const environment = config.MEMBERSHIP_APPLE_ENVIRONMENT
    const auth = createMembershipAuth({ store: stores[environment], appleVerifier: {}, attestationVerifier: {} })
    const rewards = createLevelPlayVerifier({ privateKey, now: () => now })
    const handler = createMembershipHandler({ auth, rewards,
      membership: { async creditVerifiedReward(reward) { credited.push({ environment, ...reward }) } } })
    handler.resolveVerifiedReward = createVerifiedRewardResolver({ auth, rewards })
    return handler
  })
  const query = new URLSearchParams({ timestamp: new Date(now).toISOString().slice(0, 16).replace(/\D/g, ''), eventId: 'router-test-event', userId, rewards: '1' })
  query.set('signature', createHash('md5').update(query.get('timestamp') + query.get('eventId') + userId + '1' + privateKey).digest('hex'))
  const base = '/v1/membership/levelplay/callback'
  assert.equal((await request(base + '/production?' + query, { method: 'GET' })).status, 401)
  const valid = await request(base + '/sandbox?' + query, { method: 'GET' })
  assert.equal(valid.status, 200)
  assert.equal(valid.text, 'router-test-event:OK')
  assert.equal(credited.length, 1)
  assert.equal(credited[0].environment, 'Sandbox')
  query.set('userId', 'b'.repeat(48))
  assert.equal((await request(base + '/sandbox?' + query, { method: 'GET' })).status, 401)
  assert.equal(credited.length, 1)
})

test('challenge write cap is shared across environment hints rather than doubled', async (t) => {
  let calls = 0
  const request = await fixture(t, () => createMembershipHandler({ auth: {
    async issueChallenge() { calls++; return { id: 'fixture-challenge' } }
  } }))
  for (let index = 0; index < 60; index++) {
    assert.equal((await request('/v1/membership/challenge', { headers: {
      'X-RC-Apple-Environment': index % 2 ? 'Sandbox' : 'Production'
    } })).status, 200)
  }
  for (const environment of ['Sandbox', 'Production']) {
    assert.equal((await request('/v1/membership/challenge', { headers: { 'X-RC-Apple-Environment': environment } })).status, 429)
  }
  assert.equal(calls, 60)
})

test('single LevelPlay URL resolves only a signed userId with exactly one environment owner', async (t) => {
  const privateKey = 'canonical-router-test-only-secret', now = Date.now(), userId = 'c'.repeat(48)
  const stores = { Sandbox: createMemoryStore(), Production: createMemoryStore() }, credited = []
  const register = async (environment) => {
    await stores[environment].set(`authRewardUsers/${userId}`, { memberId: 'canonical-reward-member' })
    await stores[environment].set('members/canonical-reward-member', { id: 'canonical-reward-member' })
  }
  const request = await fixture(t, (config) => {
    const environment = config.MEMBERSHIP_APPLE_ENVIRONMENT
    const auth = createMembershipAuth({ store: stores[environment], appleVerifier: {}, attestationVerifier: {} })
    const rewards = createLevelPlayVerifier({ privateKey, now: () => now })
    const handler = createMembershipHandler({ auth, rewards,
      membership: { async creditVerifiedReward() { credited.push(environment) } } })
    handler.resolveVerifiedReward = createVerifiedRewardResolver({ auth, rewards })
    return handler
  })
  const query = new URLSearchParams({ timestamp: new Date(now).toISOString().slice(0, 16).replace(/\D/g, ''), eventId: 'canonical-event', userId, rewards: '1',
    custom_environment: 'Production' })
  query.set('signature', createHash('md5').update(query.get('timestamp') + 'canonical-event' + userId + '1' + privateKey).digest('hex'))
  const url = '/v1/membership/levelplay/callback?' + query
  assert.equal((await request(url, { method: 'GET' })).status, 401, 'unknown signed user gets no credit')
  await register('Sandbox')
  assert.equal((await request(url, { method: 'GET', headers: { 'X-RC-Apple-Environment': 'Production' } })).status, 200)
  assert.deepEqual(credited, ['Sandbox'], 'neither header nor unsigned query can promote a reward')
  await register('Production')
  const ambiguous = await request(url, { method: 'GET' })
  assert.equal(ambiguous.status, 401)
  assert.equal(ambiguous.data.error, 'ambiguous_reward_user')
  for (const suffix of ['production', 'sandbox']) {
    assert.equal((await request('/v1/membership/levelplay/callback/' + suffix + '?' + query, { method: 'GET' })).status, 401,
      'a suffixed URL must not bypass collision detection')
  }
  assert.deepEqual(credited, ['Sandbox'])
  query.set('signature', '0'.repeat(32))
  assert.equal((await request('/v1/membership/levelplay/callback?' + query, { method: 'GET' })).status, 401)
  assert.equal((await request(url)).status, 405)
  assert.deepEqual(credited, ['Sandbox'])
})

test('callback resolution fails retryably on storage outages instead of assuming the other environment owns it', async (t) => {
  let creditCalls = 0
  const request = await fixture(t, (config) => {
    const handler = async () => { creditCalls++; return false }
    handler.resolveVerifiedReward = async () => {
      if (config.MEMBERSHIP_APPLE_ENVIRONMENT === 'Production') throw new Error('private-database-error')
      return true
    }
    return handler
  })
  const result = await request('/v1/membership/levelplay/callback', { method: 'GET' })
  assert.equal(result.status, 503)
  assert.equal(result.data.error, 'reward_verification_unavailable')
  assert.doesNotMatch(result.text, /private-database/)
  assert.equal(creditCalls, 0)
})

test('verified Sandbox notifications forward unchanged only to the exact legacy allowlist', async () => {
  const env = { MEMBERSHIP_APPLE_ENVIRONMENT: 'Sandbox', MEMBERSHIP_SANDBOX_NOTIFICATION_FORWARD_URL: LEGACY_SANDBOX_NOTIFICATION_URL }
  const order = [], event = { environment: 'Sandbox', notificationUUID: 'test-event' }
  const apple = { async verifyNotification(proof) { order.push('verified'); assert.equal(proof, 'test.signed.payload'); return event } }
  const wrapped = withSandboxNotificationForwarding(apple, env, async (url, options) => {
    order.push('forwarded')
    assert.equal(url, LEGACY_SANDBOX_NOTIFICATION_URL)
    assert.equal(options.method, 'POST')
    assert.equal(options.redirect, 'error')
    assert.equal(options.body, JSON.stringify({ signedPayload: 'test.signed.payload' }))
    assert.ok(options.signal instanceof AbortSignal)
    return { ok: true }
  })
  assert.equal(await wrapped.verifyNotification('test.signed.payload'), event)
  assert.deepEqual(order, ['verified', 'forwarded'])
  for (const url of ['https://other.example/notifications', LEGACY_SANDBOX_NOTIFICATION_URL + '?redirect=1',
    LEGACY_SANDBOX_NOTIFICATION_URL.replace('https:', 'http:')]) {
    assert.throws(() => withSandboxNotificationForwarding(apple, { ...env, MEMBERSHIP_SANDBOX_NOTIFICATION_FORWARD_URL: url }), /invalid_sandbox_notification_forward_url/)
  }
  let forwarded = false
  const invalid = withSandboxNotificationForwarding({ async verifyNotification() { throw new Error('invalid_apple_proof') } }, env,
    async () => { forwarded = true; return { ok: true } })
  await assert.rejects(invalid.verifyNotification('invalid'), /invalid_apple_proof/)
  assert.equal(forwarded, false)
  const production = withSandboxNotificationForwarding(apple, { ...env, MEMBERSHIP_APPLE_ENVIRONMENT: 'Production' },
    async () => { throw new Error('production must never forward') })
  assert.equal(production, apple)
})

test('failed Sandbox forwarding is retryable and does not acknowledge or apply the local notification early', async (t) => {
  let attempts = 0, applied = 0
  const env = { MEMBERSHIP_APPLE_ENVIRONMENT: 'Sandbox', MEMBERSHIP_SANDBOX_NOTIFICATION_FORWARD_URL: LEGACY_SANDBOX_NOTIFICATION_URL }
  const apple = withSandboxNotificationForwarding({ async verifyNotification() {
    return { environment: 'Sandbox', notificationUUID: 'retry-test-event', transaction: { transactionId: 'retry-test-transaction' } }
  } }, env, async () => {
    attempts++
    if (attempts === 1) throw new Error('timeout or network error with sensitive details')
    if (attempts === 2) return { ok: false, status: 503 }
    return { ok: true }
  })
  const request = await fixture(t, () => createMembershipHandler({ apple,
    membership: { async applyVerifiedNotification() { applied++ } } }))
  for (let i = 0; i < 2; i++) {
    const failed = await request('/v1/membership/apple/notifications/sandbox', { raw: '{"signedPayload":"fixture"}' })
    assert.equal(failed.status, 503)
    assert.equal(failed.data.error, 'sandbox_notification_forward_unavailable')
    assert.equal(applied, 0)
  }
  assert.equal((await request('/v1/membership/apple/notifications/sandbox', { raw: '{"signedPayload":"fixture"}' })).status, 200)
  assert.equal(applied, 1)
})
