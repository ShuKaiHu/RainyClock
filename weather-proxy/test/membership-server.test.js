'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { spawnSync } = require('node:child_process')
const { createMembershipServer, startMembershipServer } = require('../membership/server')
const { createMembershipHandler } = require('../membership/http')

// These values only satisfy entrypoint presence checks for injected handlers.
// They are never passed to an Apple verifier or used as platform credentials.
const fixtureEnv = { MEMBERSHIP_ENABLED: '1', MEMBERSHIP_APPLE_ENVIRONMENT: 'Sandbox',
  MEMBERSHIP_APPLE_KEY_PATH: '/fixture-only/not-a-key', MEMBERSHIP_APPLE_KEY_ID: 'fixture-only',
  MEMBERSHIP_APPLE_ISSUER_ID: 'fixture-only' }

async function fixture(t, options = {}) {
  const server = createMembershipServer({ env: {}, ...options })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => {
    server.close(resolve)
    server.closeAllConnections()
  }))
  const port = server.address().port
  async function request(path, { method = 'GET', body, headers = {}, chunks } = {}) {
    return new Promise((resolve, reject) => {
      const req = http.request({ hostname: '127.0.0.1', port, path, method, headers, agent: false }, (res) => {
        const parts = []
        res.on('data', (part) => parts.push(part))
        res.on('error', reject)
        res.on('end', () => {
          const text = Buffer.concat(parts).toString('utf8')
          resolve({ status: res.statusCode, headers: res.headers, text, data: text.startsWith('{') ? JSON.parse(text) : null })
        })
      })
      req.on('error', reject)
      for (const chunk of chunks || []) req.write(chunk)
      req.end(body)
    })
  }
  return { request, server }
}

test('isolated disabled server boots without WeatherKit or Apple configuration and exposes liveness', async (t) => {
  const f = await fixture(t)
  const health = await f.request('/health')
  assert.equal(health.status, 200)
  assert.deepEqual(health.data, { ok: true, membershipEnabled: false })
  assert.equal(health.headers['cache-control'], 'no-store')
  assert.equal(Number(health.headers['content-length']), Buffer.byteLength(health.text))
  const head = await f.request('/health', { method: 'HEAD' })
  assert.equal(head.status, 200)
  assert.equal(head.text, '')
  assert.equal(head.headers['content-length'], health.headers['content-length'])
  assert.equal((await f.request('/health', { method: 'POST' })).status, 405)
  assert.equal((await f.request('/healthz')).status, 404)
  const membership = await f.request('/v1/membership/challenge', { method: 'POST', body: '{}' })
  assert.equal(membership.status, 503)
  assert.deepEqual(membership.data, { error: 'membership_not_configured' })
})

test('only exact opt-in enables membership and disabled deployments do not initialize runtime', async (t) => {
  for (const setting of [undefined, '0', 'true']) {
    const f = await fixture(t, { env: { MEMBERSHIP_ENABLED: setting }, createRuntime: () => { throw new Error('must not run') } })
    assert.equal((await f.request('/v1/membership/status', { method: 'POST' })).status, 503)
  }
})

test('weather, anonymous TTS and maintenance routes are absent even when membership is enabled', async (t) => {
  let calls = 0
  const f = await fixture(t, { env: fixtureEnv, createRuntime: () => async () => { calls++; return false } })
  for (const path of ['/v1/tts', '/v1/weather', '/weather', '/', '/v1/membership', '/maintenance', '/v1/membership-other/status']) {
    const response = await f.request(path, { method: 'POST', body: '{}' })
    assert.equal(response.status, 404, path)
    assert.deepEqual(response.data, { error: 'not_found' })
  }
  assert.equal(calls, 0)
  assert.deepEqual((await f.request('/health')).data, { ok: true, membershipEnabled: true })
  assert.equal((await f.request('/healthz')).status, 404)
  assert.equal((await f.request('/v1/membership/unknown', { method: 'POST', body: '{}' })).status, 404)
  assert.equal(calls, 1)
})

test('configuration failure never returns a serving instance or silently disables an enabled runtime', async () => {
  assert.throws(() => createMembershipServer({ env: { MEMBERSHIP_ENABLED: '1' } }), /requires_sandbox/)
  for (const environment of ['Production', 'Xcode', 'LocalTesting']) {
    assert.throws(() => createMembershipServer({ env: { ...fixtureEnv, MEMBERSHIP_APPLE_ENVIRONMENT: environment } }), /requires_sandbox/)
  }
  for (const name of ['MEMBERSHIP_APPLE_KEY_PATH', 'MEMBERSHIP_APPLE_KEY_ID', 'MEMBERSHIP_APPLE_ISSUER_ID']) {
    assert.throws(() => createMembershipServer({ env: { ...fixtureEnv, [name]: '' } }), /apple_server_api_not_configured/)
  }
  assert.throws(() => createMembershipServer({ env: fixtureEnv, createRuntime: () => { throw new Error('invalid_config') } }), /invalid_config/)
  assert.throws(() => createMembershipServer({ env: fixtureEnv, createRuntime: () => null }), /membership_not_configured/)
  // This uses the actual runtime and stops on its project guard, before any I/O.
  assert.throws(() => createMembershipServer({ env: fixtureEnv }), /unsafe_firestore_project/)
  for (const port of ['0', '-1', '65536', '8080suffix', '']) {
    await assert.rejects(startMembershipServer({ env: { PORT: port } }), /invalid_port/)
  }
})

test('CLI configuration failure exits nonzero and emits no raw configuration or error detail', () => {
  const result = spawnSync(process.execPath, [require.resolve('../membership/server')], {
    env: { PATH: process.env.PATH, MEMBERSHIP_ENABLED: '1', MEMBERSHIP_APPLE_ENVIRONMENT: 'private-do-not-log' },
    encoding: 'utf8', timeout: 5_000
  })
  assert.equal(result.status, 1)
  assert.equal(result.stdout, '')
  assert.deepEqual(JSON.parse(result.stderr.trim()), { event: 'membership_server_start_failed' })
  assert.doesNotMatch(result.stderr, /private-do-not-log|stack|WeatherKit/)
})

test('existing HTTP handler receives original signed bytes and rejects unauthenticated operations', async (t) => {
  const raw = '{ "signedAppTransaction" : "fixture-proof", "timeZone": "Asia/Taipei" }'
  let seen
  const auth = {
    async issueChallenge(body) { return { purpose: body.purpose, id: 'fixture-challenge' } },
    async bootstrapIdentityAndDevice(input) {
      seen = input
      throw Object.assign(new Error('proof intentionally rejected'), { statusCode: 401, code: 'invalid_apple_proof' })
    },
    async authenticate({ token }) {
      assert.equal(token, undefined)
      throw Object.assign(new Error('session required'), { statusCode: 401, code: 'invalid_session' })
    }
  }
  const f = await fixture(t, { env: fixtureEnv, createRuntime: () => createMembershipHandler({ auth }) })
  const challenge = await f.request('/v1/membership/challenge', { method: 'POST', body: '{"purpose":"bootstrap"}' })
  assert.deepEqual(challenge.data, { purpose: 'bootstrap', id: 'fixture-challenge' })
  const session = await f.request('/v1/membership/session', { method: 'POST', body: raw,
    headers: { 'x-app-attest-assertion': 'fixture-assertion' } })
  assert.equal(session.status, 401)
  assert.deepEqual(session.data, { error: 'invalid_apple_proof' })
  assert.equal(seen.rawBody.toString('utf8'), raw)
  assert.equal(seen.headers['x-app-attest-assertion'], 'fixture-assertion')
  assert.equal(seen.method, 'POST')
  assert.equal(seen.path, '/v1/membership/session')
  for (const path of ['/v1/membership/status', '/v1/membership/generations']) {
    const response = await f.request(path, { method: 'POST', body: '{}' })
    assert.equal(response.status, 401)
    assert.deepEqual(response.data, { error: 'invalid_session' })
  }
  assert.equal((await f.request('/v1/membership/challenge')).status, 405)
})

test('declared and streamed oversized bodies are rejected before authentication or challenge work', async (t) => {
  let calls = 0
  const f = await fixture(t, { env: fixtureEnv, createRuntime: () => createMembershipHandler({ auth: {
    async issueChallenge() { calls++; throw new Error('must not run') }
  } }) })
  const declared = await f.request('/v1/membership/challenge', { method: 'POST',
    headers: { 'content-length': '384001' } })
  assert.equal(declared.status, 413)
  assert.deepEqual(declared.data, { error: 'body_too_large' })
  const streamed = await f.request('/v1/membership/challenge', { method: 'POST',
    chunks: [Buffer.alloc(192_000, ' '), Buffer.alloc(192_001, ' ')] })
  assert.equal(streamed.status, 413)
  assert.deepEqual(streamed.data, { error: 'body_too_large' })
  assert.equal(calls, 0)
})

test('oversized headers are refused by HTTP parser without dispatching to the runtime', async (t) => {
  let calls = 0
  const f = await fixture(t, { env: fixtureEnv, createRuntime: () => async () => { calls++; return false } })
  const response = await f.request('/v1/membership/challenge', { method: 'POST', headers: { 'x-oversized': 'a'.repeat(17_000) } })
  assert.equal(response.status, 431)
  assert.equal(calls, 0)
})

test('unexpected handler rejection is contained and does not expose proofs or crash later requests', async (t) => {
  const f = await fixture(t, { env: fixtureEnv, createRuntime: () => async () => { throw new Error('private-proof-token-upstream') } })
  const response = await f.request('/v1/membership/challenge', { method: 'POST', body: '{}' })
  assert.equal(response.status, 503)
  assert.deepEqual(response.data, { error: 'membership_unavailable' })
  assert.doesNotMatch(response.text, /private-proof/)
  assert.equal((await f.request('/health')).status, 200)
})

test('Sandbox challenge cap applies across rotated device keys and IPs without blocking other routes', async (t) => {
  let calls = 0
  const auth = {
    async issueChallenge() { calls++; return { id: 'fixture-challenge' } },
    async authenticate() { throw Object.assign(new Error('session required'), { statusCode: 401, code: 'invalid_session' }) }
  }
  const f = await fixture(t, { env: fixtureEnv, createRuntime: () => createMembershipHandler({ auth }) })
  const challenge = (index) => f.request('/v1/membership/challenge', { method: 'POST',
    body: JSON.stringify({ purpose: 'bootstrap', keyID: Buffer.alloc(32, index).toString('base64') }),
    headers: { 'x-forwarded-for': `192.0.2.${index + 1}` } })
  for (let index = 0; index < 60; index++) assert.equal((await challenge(index)).status, 200)
  for (const index of [60, 0, 61]) {
    const limited = await challenge(index)
    assert.equal(limited.status, 429)
    assert.deepEqual(limited.data, { error: 'challenge_rate_limited' })
    assert.equal(limited.headers['retry-after'], '60')
  }
  assert.equal(calls, 60, 'refused requests never reach challenge storage')
  assert.equal((await f.request('/health')).status, 200)
  assert.equal((await f.request('/v1/membership/challenge')).status, 405)
  assert.equal((await f.request('/v1/membership/status', { method: 'POST', body: '{}' })).status, 401)
})
