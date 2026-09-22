'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { synthesize, normalizeSynthesisOptions, BYTES_PER_SECOND } = require('../tts')
const { resetTokenCache } = require('../google-auth')

const input = { persona: 'steady', segments: [{ text: 'Good morning.', emotion: 'neutral' }],
  language: 'en', maximumSeconds: 10 }
const membershipOptions = { endpointRegion: 'us', timeoutMs: 35_000,
  maxAttempts: 1, retryNetworkErrors: false }
let savedToken

test.beforeEach((t) => {
  savedToken = process.env.GOOGLE_ACCESS_TOKEN
  process.env.GOOGLE_ACCESS_TOKEN = 'offline-test-token'
  resetTokenCache()
  t.mock.method(globalThis, 'fetch', async () => assert.fail('unexpected network request'))
})

test.afterEach(() => {
  if (savedToken === undefined) delete process.env.GOOGLE_ACCESS_TOKEN
  else process.env.GOOGLE_ACCESS_TOKEN = savedToken
  resetTokenCache()
})

test('membership timeout does not start another potentially billable synthesis', async (t) => {
  let calls = 0
  t.mock.method(globalThis, 'fetch', async () => {
    calls += 1
    throw new DOMException('The operation was aborted due to timeout', 'TimeoutError')
  })
  await assert.rejects(synthesize(input, membershipOptions), (error) => error.status === 502)
  assert.equal(calls, 1)
})

test('network retries can be disabled independently of the HTTP attempt limit', async (t) => {
  let calls = 0
  t.mock.method(globalThis, 'fetch', async () => { calls += 1; throw new TypeError('fetch failed') })
  await assert.rejects(synthesize(input, { ...membershipOptions, maxAttempts: 3 }),
    (error) => error.status === 502)
  assert.equal(calls, 1)
})

test('membership also limits explicit upstream errors to one request', async (t) => {
  for (const [status, message, expectedStatus] of [[500, 'unavailable', 502],
    [429, 'rate limited', 429], [400, 'blocked by safety', 422]]) {
    let calls = 0
    t.mock.method(globalThis, 'fetch', async () => {
      calls += 1
      return new Response(message, { status })
    })
    await assert.rejects(synthesize(input, membershipOptions), (error) => error.status === expectedStatus)
    assert.equal(calls, 1, `status ${status} must not cause an extra provider call`)
  }
})

test('the legacy caller retains its global endpoint and three network attempts', async (t) => {
  const urls = []
  t.mock.method(globalThis, 'fetch', async (url) => {
    urls.push(url)
    if (urls.length < 3) throw new TypeError('fetch failed')
    return Response.json({ audioContent: Buffer.alloc(200, 7).toString('base64') })
  })
  assert.equal((await synthesize(input)).length, 200)
  assert.deepEqual(urls, Array(3).fill('https://texttospeech.googleapis.com/v1/text:synthesize'))
})

test('the US membership request strips WAV and caps returned PCM at ten seconds', async (t) => {
  const pcm = Buffer.alloc(BYTES_PER_SECOND * 11, 7)
  const header = Buffer.alloc(44)
  header.write('RIFF', 0); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8)
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22)
  header.writeUInt32LE(24_000, 24); header.writeUInt32LE(BYTES_PER_SECOND, 28)
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34)
  header.write('data', 36); header.writeUInt32LE(pcm.length, 40)
  let calls = 0
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls += 1
    assert.equal(url, 'https://us-texttospeech.googleapis.com/v1/text:synthesize')
    assert.equal(JSON.parse(options.body).voice.model_name, 'gemini-2.5-flash-tts')
    assert.ok(options.signal instanceof AbortSignal)
    return Response.json({ audioContent: Buffer.concat([header, pcm]).toString('base64') })
  })
  const result = await synthesize(input, membershipOptions)
  assert.equal(calls, 1)
  assert.equal(result.length, BYTES_PER_SECOND * 10)
  assert.deepEqual(result, pcm.subarray(0, BYTES_PER_SECOND * 10))
})

test('invalid provider configuration fails before acquiring credentials or making HTTP requests', async () => {
  for (const options of [{ endpointRegion: 'https://untrusted.invalid' }, { endpointRegion: '__proto__' },
    { timeoutMs: 0 }, { timeoutMs: 120_001 }, { timeoutMs: NaN }, { maxAttempts: 0 },
    { maxAttempts: 4 }, { retryNetworkErrors: 'false' }]) {
    assert.throws(() => normalizeSynthesisOptions(options), /invalid_tts_request_options/)
    await assert.rejects(synthesize(input, options), /invalid_tts_request_options/)
  }
})
