'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')

const { EMOTION_IDS } = require('../personas')
const { resetTokenCache } = require('../google-auth')

const ANNOTATE_PATH = require.resolve('../annotate')
const ENV_KEYS = ['GOOGLE_CLOUD_PROJECT', 'VERTEX_LOCATION', 'VERTEX_ANNOTATE_MODEL', 'GOOGLE_ACCESS_TOKEN']
const PRIVATE_TOKEN = 'private-test-access-token-do-not-log'
const PRIVATE_TEXT = '我的私人鬧鐘句子。'
const PRIVATE_ERROR = 'private-upstream-response-do-not-log'
let savedEnv
let annotator
let warnings

function reloadAnnotator() {
  delete require.cache[ANNOTATE_PATH]
  return require('../annotate')
}

function response(parts) {
  return {
    ok: true,
    status: 200,
    json: async () => ({ candidates: [{ content: { parts } }] })
  }
}

function idsResponse(ids) {
  return response([{ text: JSON.stringify(ids) }])
}

function run(sentences = [PRIVATE_TEXT, 'Leave early.']) {
  return annotator.annotate({ sentences, persona: 'steady', language: 'zh-Hant' })
}

function assertFallback(sentenceCount, extra = {}) {
  assert.equal(warnings.length, 1, 'one structured warning should describe a fallback')
  assert.equal(warnings[0].length, 1, 'do not append raw errors or response bodies')
  assert.equal(typeof warnings[0][0], 'string')
  const entry = JSON.parse(warnings[0][0])
  assert.equal(entry.event, 'annotation_fallback')
  assert.equal(typeof entry.reason, 'string')
  assert.ok(entry.reason.length > 0)
  assert.equal(entry.model, 'gemini-3.1-flash-lite')
  assert.equal(entry.location, 'us')
  assert.equal(entry.sentenceCount, sentenceCount)
  const allowed = new Set(['event', 'reason', 'model', 'location', 'sentenceCount', 'status', 'fallbackCount'])
  for (const key of Object.keys(entry)) assert.ok(allowed.has(key), `unexpected log field: ${key}`)
  for (const [key, value] of Object.entries(extra)) assert.equal(entry[key], value)
  for (const secret of [PRIVATE_TOKEN, PRIVATE_TEXT, PRIVATE_ERROR]) {
    assert.ok(!warnings[0][0].includes(secret), 'fallback logs must not contain private input or upstream content')
  }
  return entry
}

test.beforeEach((t) => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((key) => [key, process.env[key]]))
  for (const key of ENV_KEYS) delete process.env[key]
  process.env.GOOGLE_ACCESS_TOKEN = PRIVATE_TOKEN
  resetTokenCache()
  annotator = reloadAnnotator()
  warnings = []
  t.mock.method(console, 'warn', (...args) => warnings.push(args))
  // Every test is offline, including tests that accidentally miss a fetch stub.
  t.mock.method(globalThis, 'fetch', async () => {
    assert.fail('unexpected network request')
  })
})

test.afterEach(() => {
  for (const key of ENV_KEYS) {
    if (savedEnv[key] === undefined) delete process.env[key]
    else process.env[key] = savedEnv[key]
  }
  resetTokenCache()
  delete require.cache[ANNOTATE_PATH]
})

test('annotation defaults to Gemini 3.1 Flash-Lite at the US multi-region endpoint', () => {
  assert.equal(annotator.MODEL, 'gemini-3.1-flash-lite')
  assert.equal(annotator.LOCATION, 'us')
  assert.equal(annotator.endpoint(),
    'https://aiplatform.us.rep.googleapis.com/v1/projects/rainyclock/locations/us/publishers/google/models/gemini-3.1-flash-lite:generateContent')
})

test('endpoint supports US, EU, global, and legacy regional locations', () => {
  const hosts = {
    us: 'aiplatform.us.rep.googleapis.com',
    eu: 'aiplatform.eu.rep.googleapis.com',
    global: 'aiplatform.googleapis.com',
    'us-central1': 'us-central1-aiplatform.googleapis.com',
    'asia-east1': 'asia-east1-aiplatform.googleapis.com'
  }
  for (const [location, host] of Object.entries(hosts)) {
    assert.equal(annotator.endpoint({ project: 'test-project', location, model: 'test-model' }),
      `https://${host}/v1/projects/test-project/locations/${location}/publishers/google/models/test-model:generateContent`)
  }
})

test('deployment environment overrides model, project, and endpoint region together', () => {
  process.env.GOOGLE_CLOUD_PROJECT = 'custom-project'
  process.env.VERTEX_LOCATION = 'eu'
  process.env.VERTEX_ANNOTATE_MODEL = 'gemini-3.5-flash-lite'
  annotator = reloadAnnotator()
  assert.equal(annotator.endpoint(),
    'https://aiplatform.eu.rep.googleapis.com/v1/projects/custom-project/locations/eu/publishers/google/models/gemini-3.5-flash-lite:generateContent')
})

test('request uses bearer auth, a closed JSON emotion schema, and minimal thinking', async (t) => {
  const sentences = Object.freeze([PRIVATE_TEXT, 'Leave at 7.30.'])
  let seen
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    seen = { url: String(url), options, body: JSON.parse(options.body) }
    return idsResponse(['neutral', 'urgent'])
  })
  assert.deepEqual(await run(sentences), ['neutral', 'urgent'])
  assert.equal(seen.url, annotator.endpoint())
  assert.equal(seen.options.method, 'POST')
  assert.equal(seen.options.headers.Authorization, `Bearer ${PRIVATE_TOKEN}`)
  assert.equal(seen.options.headers['x-goog-user-project'], 'rainyclock')
  assert.equal(seen.options.headers['Content-Type'], 'application/json')
  assert.ok(!Object.keys(seen.options.headers).some((key) => key.toLowerCase() === 'x-goog-api-key'))
  assert.ok(!seen.url.includes('key='))
  assert.ok(seen.options.signal instanceof AbortSignal)
  assert.deepEqual(seen.body.generationConfig, {
    responseMimeType: 'application/json',
    responseSchema: {
      type: 'ARRAY', items: { type: 'STRING', enum: EMOTION_IDS }, minItems: 2, maxItems: 2
    },
    thinkingConfig: { thinkingLevel: 'MINIMAL' }
  })
  const prompt = seen.body.contents[0].parts[0].text
  assert.ok(prompt.includes(`1. ${PRIVATE_TEXT}\n2. Leave at 7.30.`))
  assert.ok(prompt.includes('Traditional Chinese'))
  assert.deepEqual(sentences, [PRIVATE_TEXT, 'Leave at 7.30.'])
  assert.equal(warnings.length, 0)
})

test('a Gemini 2.5 override omits unsupported thinkingLevel and uses its configured endpoint', async (t) => {
  process.env.VERTEX_LOCATION = 'us-central1'
  process.env.VERTEX_ANNOTATE_MODEL = 'gemini-2.5-flash'
  annotator = reloadAnnotator()
  let seen
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    seen = { url: String(url), body: JSON.parse(options.body) }
    return idsResponse(['neutral', 'urgent'])
  })
  assert.deepEqual(await run(), ['neutral', 'urgent'])
  assert.equal(seen.body.generationConfig.thinkingConfig, undefined)
  assert.equal(seen.url,
    'https://us-central1-aiplatform.googleapis.com/v1/projects/rainyclock/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent')
})

test('Gemini 3.5 Flash-Lite retains its supported minimal thinking configuration', async (t) => {
  process.env.VERTEX_ANNOTATE_MODEL = 'gemini-3.5-flash-lite'
  annotator = reloadAnnotator()
  let config
  t.mock.method(globalThis, 'fetch', async (_, options) => {
    config = JSON.parse(options.body).generationConfig
    return idsResponse(['neutral', 'urgent'])
  })
  assert.deepEqual(await run(), ['neutral', 'urgent'])
  assert.deepEqual(config.thinkingConfig, { thinkingLevel: 'MINIMAL' })
})

test('Gemini 3.7 Flash does not inherit the unsupported MINIMAL level from Flash-Lite', async (t) => {
  process.env.VERTEX_ANNOTATE_MODEL = 'gemini-3.7-flash'
  annotator = reloadAnnotator()
  let config
  t.mock.method(globalThis, 'fetch', async (_, options) => {
    config = JSON.parse(options.body).generationConfig
    return idsResponse(['neutral', 'urgent'])
  })
  assert.deepEqual(await run(), ['neutral', 'urgent'])
  assert.equal(config.thinkingConfig, undefined)
})

test('response joins output text parts and ignores thought text', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => response([
    { thought: true, text: 'This is private reasoning, not JSON.' },
    { text: '["cheerful",' },
    { thought: true, text: '["stern", "stern"]' },
    { text: '"urgent"]' }
  ]))
  assert.deepEqual(await run(), ['cheerful', 'urgent'])
  assert.equal(warnings.length, 0)
})

test('all supported emotion IDs survive without rewriting the input', async (t) => {
  const sentences = Object.freeze(EMOTION_IDS.map((_, i) => `Private original sentence ${i}.`))
  const original = [...sentences]
  t.mock.method(globalThis, 'fetch', async () => idsResponse(EMOTION_IDS))
  assert.deepEqual(await run(sentences), EMOTION_IDS)
  assert.deepEqual(sentences, original)
  assert.equal(warnings.length, 0)
})

test('empty input skips token lookup and annotation requests', async () => {
  delete process.env.GOOGLE_ACCESS_TOKEN
  assert.deepEqual(await run([]), [])
  assert.equal(globalThis.fetch.mock.callCount(), 0)
  assert.equal(warnings.length, 0)
})

test('invalid emotion IDs degrade only the affected sentences and log a count', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => idsResponse(['urgent', 'invented-emotion', null, 'cheerful']))
  assert.deepEqual(await run(Object.freeze([PRIVATE_TEXT, 'b', 'c', 'd'])),
    ['urgent', 'neutral', 'neutral', 'cheerful'])
  assertFallback(4, { fallbackCount: 2 })
})

test('a short list retains valid IDs and fills missing sentences with neutral', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => idsResponse(['cheerful']))
  assert.deepEqual(await run(), ['cheerful', 'neutral'])
  assertFallback(2, { fallbackCount: 1 })
})

test('extra IDs never add spoken segments', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => idsResponse(['urgent', 'cheerful', 'stern']))
  assert.deepEqual(await run(), ['urgent', 'cheerful'])
})

for (const [name, body] of [
  ['missing candidates', {}],
  ['missing content', { candidates: [{}] }],
  ['empty parts', { candidates: [{ content: { parts: [] } }] }],
  ['thought-only response', { candidates: [{ content: { parts: [{ thought: true, text: '["urgent","urgent"]' }] } }] }],
  ['malformed output JSON', { candidates: [{ content: { parts: [{ text: PRIVATE_ERROR }] } }] }],
  ['non-array JSON', { candidates: [{ content: { parts: [{ text: '{"emotion":"urgent"}' }] } }] }]
]) {
  test(`${name} falls back without logging response contents`, async (t) => {
    t.mock.method(globalThis, 'fetch', async () => ({ ok: true, status: 200, json: async () => body }))
    assert.deepEqual(await run(), ['neutral', 'neutral'])
    assertFallback(2)
  })
}

test('malformed HTTP JSON falls back without logging the parser error', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => ({
    ok: true, status: 200, json: async () => { throw new SyntaxError(PRIVATE_ERROR) }
  }))
  assert.deepEqual(await run(), ['neutral', 'neutral'])
  assertFallback(2)
})

for (const status of [401, 403, 429, 500]) {
  test(`HTTP ${status} falls back and logs only structured status metadata`, async (t) => {
    t.mock.method(globalThis, 'fetch', async () => ({
      ok: false, status,
      text: async () => PRIVATE_ERROR,
      json: async () => ({ error: { message: PRIVATE_ERROR } })
    }))
    assert.deepEqual(await run(), ['neutral', 'neutral'])
    assertFallback(2, { status })
    assert.equal(globalThis.fetch.mock.callCount(), 1)
  })
}

test('network errors remain neutral and never log error.message', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => { throw new Error(PRIVATE_ERROR) })
  assert.deepEqual(await run(), ['neutral', 'neutral'])
  assertFallback(2)
})

test('credential lookup failure stays neutral and never calls Vertex', async (t) => {
  delete process.env.GOOGLE_ACCESS_TOKEN
  const urls = []
  t.mock.method(globalThis, 'fetch', async (url) => {
    urls.push(String(url))
    throw new Error(PRIVATE_ERROR)
  })
  assert.deepEqual(await run(), ['neutral', 'neutral'])
  assert.equal(urls.length, 1)
  assert.match(urls[0], /^http:\/\/metadata\.google\.internal\//)
  assertFallback(2)
})

test('annotation timeout is bounded and returns neutral without exposing its error', async (t) => {
  let deadline
  t.mock.method(AbortSignal, 'timeout', (milliseconds) => {
    deadline = milliseconds
    return AbortSignal.abort(new DOMException(PRIVATE_ERROR, 'TimeoutError'))
  })
  t.mock.method(globalThis, 'fetch', async (_, options) => {
    options.signal.throwIfAborted()
    assert.fail('the simulated deadline should have expired')
  })
  assert.deepEqual(await run(), ['neutral', 'neutral'])
  assert.equal(deadline, 8_000)
  assertFallback(2)
})
