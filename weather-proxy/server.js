'use strict'

const http = require('node:http')
const { createTokenCache } = require('./token')
const {
  cacheKey,
  clientAddress,
  createCache,
  createDailyBudget,
  createRateLimiter
} = require('./guards')
const { PERSONA_IDS, EMOTION_IDS, styleLanguage } = require('./personas')
const { synthesize, SAMPLE_RATE } = require('./tts')
const { annotate, splitSentences } = require('./annotate')
const { createMembershipRuntime } = require('./membership/runtime')
// Opt-in only. Missing production verification configuration fails startup.
const membershipHandler = createMembershipRuntime()

/**
 * How much speech a clip may contain. The app pads the rest of its 28-second
 * alarm with the user's chosen tone, so this bounds cost without shortening the
 * ring. Kept in step with `GeneratedVoiceStore.maximumSpeechDuration`.
 */
const MAX_SPEECH_SECONDS = 10

// A stateless signing proxy in front of Apple's WeatherKit REST API. It exists
// for one reason: the ES256 private key that authenticates a WeatherKit request
// cannot ship inside an APK, and Apple's own guidance is to put the signing
// behind a service. Everything else about it is deliberately boring — no
// storage, no user data, no dependencies beyond Node's standard library.

const {
  WEATHERKIT_TEAM_ID: teamId,
  WEATHERKIT_SERVICE_ID: serviceId,
  WEATHERKIT_KEY_ID: keyId,
  WEATHERKIT_PRIVATE_KEY: privateKey,
  PROXY_SHARED_SECRET: sharedSecret,
  // Speech no longer needs a credential of its own: Cloud Text-to-Speech and
  // Vertex AI both authenticate with the service account this already runs as.
  // `TTS_DISABLED=1` is the off switch a missing key used to be.
  TTS_DISABLED: ttsDisabled,
  PORT = '8080'
} = process.env

for (const [name, value] of Object.entries({
  WEATHERKIT_TEAM_ID: teamId,
  WEATHERKIT_SERVICE_ID: serviceId,
  WEATHERKIT_KEY_ID: keyId,
  WEATHERKIT_PRIVATE_KEY: privateKey
})) {
  if (!value) {
    console.error(`Missing required environment variable ${name}`)
    process.exit(1)
  }
}

const currentToken = createTokenCache({ teamId, serviceId, keyId, privateKey })

// 5,000 a day is roughly 150,000 a month against an allowance of 500,000, so
// there is headroom for real growth while a scraped URL still cannot drain the
// month in an afternoon.
const responseCache = createCache()
const dailyBudget = createDailyBudget({ limit: Number(process.env.DAILY_UPSTREAM_LIMIT ?? 5_000) })
const rateLimiter = createRateLimiter()

// TTS gets its own three guards rather than sharing the weather ones, because
// what they protect is different in kind. WeatherKit's allowance is a monthly
// call count that resets; Gemini bills per token, so a scraped key is an
// unbounded bill and the only real defence is that the key never leaves here
// and this ceiling is enforced before the call.
//
// 2,000 clips a day is about US$6.40 at 10 s each on 2.5-flash — two orders of
// magnitude above honest load, since a user generates a handful of clips in the
// lifetime of an alarm, not daily.
const ttsBudget = createDailyBudget({ limit: Number(process.env.DAILY_TTS_LIMIT ?? 2_000) })
const ttsRateLimiter = createRateLimiter({ limit: 30, windowMs: 5 * 60_000 })
// Far smaller than the weather cache: one clip is ~480 kB of PCM against a few
// hundred bytes of forecast, and this runs in 256 MiB.
const ttsCache = createCache({ ttlMs: 60 * 60_000, maxEntries: 40 })

const UPSTREAM_TIMEOUT_MS = 10_000

/** Cost guard, not a UX rule — the app enforces the real per-language limits. */
const MAX_TTS_CHARACTERS = 200
const MAX_TTS_BODY_BYTES = 4_096
/** One per sentence of a wake-up line; more than this is not a wake-up line. */
const MAX_TTS_SEGMENTS = 8

/** Reads a JSON body, refusing anything larger than a sentence could justify. */
async function readJsonBody(request) {
  let size = 0
  const chunks = []
  for await (const chunk of request) {
    size += chunk.length
    if (size > MAX_TTS_BODY_BYTES) return null
    chunks.push(chunk)
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch {
    return null
  }
}

const sendJson = (response, status, body) => {
  const payload = JSON.stringify(body)
  response.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store'
  })
  response.end(payload)
}

const finiteNumber = (raw, min, max) => {
  const value = Number(raw)
  return Number.isFinite(value) && value >= min && value <= max ? value : null
}

/**
 * Only the three fields the app actually reads are passed through. Forwarding
 * Apple's full payload would ship temperature, pressure and wind to a client
 * that ignores them, and would make any future response change a client problem.
 */
const projectHours = (weather) =>
  (weather?.forecastHourly?.hours ?? []).map((hour) => ({
    forecastStart: hour.forecastStart,
    precipitationChance: hour.precipitationChance,
    conditionCode: hour.conditionCode
  }))

async function fetchWeather({ latitude, longitude, timezone, language, start, end }) {
  const url = new URL(
    `https://weatherkit.apple.com/api/v1/weather/${encodeURIComponent(language)}/${latitude}/${longitude}`
  )
  url.searchParams.set('dataSets', 'forecastHourly')
  // Apple documents `timezone` as required, and silently reshapes the forecast
  // roll-up without it.
  url.searchParams.set('timezone', timezone)
  if (start) url.searchParams.set('hourlyStart', start)
  if (end) url.searchParams.set('hourlyEnd', end)

  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${currentToken()}` },
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS)
  })

  if (!response.ok) {
    const detail = await response.text().catch(() => '')
    const error = new Error(`WeatherKit responded ${response.status}: ${detail.slice(0, 200)}`)
    error.status = response.status
    throw error
  }

  return response.json()
}

/**
 * Synthesizes one alarm clip and returns raw 24 kHz mono 16-bit PCM.
 *
 * Headerless on purpose: the app has to assemble the clip anyway — speech first,
 * then its chosen tone padded out to a fixed length so the alarm works whether or
 * not the system repeats it — so a WAV header written here would only be thrown
 * away. `X-Sample-Rate` says what the bytes are.
 */
async function handleTTS(request, response) {
  if (request.method !== 'POST') {
    return sendJson(response, 405, { error: 'method_not_allowed' })
  }

  if (sharedSecret && request.headers['x-rainyclock-key'] !== sharedSecret) {
    return sendJson(response, 401, { error: 'unauthorized' })
  }

  if (ttsDisabled === '1') {
    return sendJson(response, 503, { error: 'tts_not_configured' })
  }

  const body = await readJsonBody(request)
  if (!body) {
    return sendJson(response, 400, { error: 'invalid_body' })
  }

  const { persona, language } = body
  if (!PERSONA_IDS.includes(persona)) {
    return sendJson(response, 400, { error: 'unknown_persona', allowed: PERSONA_IDS })
  }

  // The words are the user's own; the delivery is the app's. Segments carry an
  // emotion *id* rather than a tag, because the tag a given feeling should
  // become is a moving target — Google reads adjective-form tags aloud as words
  // — and this way correcting one is a redeploy instead of an app release.
  // Two ways in. `segments` lets the caller direct the line itself; `text` hands
  // that job to the model, which is the normal path — the user types words, not
  // stage directions.
  let segments = Array.isArray(body.segments) ? body.segments : null
  let annotateFrom = null

  if (!segments && typeof body.text === 'string') {
    const sentences = splitSentences(body.text, MAX_TTS_SEGMENTS)
    segments = sentences.map((text) => ({ text, emotion: 'neutral' }))
    annotateFrom = sentences
  }

  if (!segments || segments.length === 0 || segments.length > MAX_TTS_SEGMENTS) {
    return sendJson(response, 400, { error: 'segments_required', limit: MAX_TTS_SEGMENTS })
  }

  let characters = 0
  for (const segment of segments) {
    if (!segment || typeof segment.text !== 'string') {
      return sendJson(response, 400, { error: 'segment_text_required' })
    }
    if (segment.emotion !== undefined && !EMOTION_IDS.includes(segment.emotion)) {
      return sendJson(response, 400, { error: 'unknown_emotion', allowed: EMOTION_IDS })
    }
    characters += segment.text.length
  }

  if (characters === 0) {
    return sendJson(response, 400, { error: 'text_required' })
  }
  if (characters > MAX_TTS_CHARACTERS) {
    return sendJson(response, 400, { error: 'text_too_long', limit: MAX_TTS_CHARACTERS })
  }

  // Labelling happens before the cache key is built, so the key covers the
  // delivery that will actually be synthesized. A failed annotation degrades to
  // neutral rather than blocking the clip.
  if (annotateFrom) {
    const emotions = await annotate({
      sentences: annotateFrom,
      persona,
      language
    })
    segments = segments.map((segment, i) => ({ ...segment, emotion: emotions[i] ?? 'neutral' }))
  }

  // Same words, same delivery, same voice is the same audio — so a retry after a
  // dropped connection, or two people asking for the same line, costs one call.
  const key = [
    persona,
    styleLanguage(language),
    ...segments.map((s) => `${s.emotion ?? 'neutral'}:${s.text.trim()}`)
  ].join('|')
  const cached = ttsCache.get(key)
  if (cached) {
    return sendAudio(response, cached, segments)
  }

  if (!ttsRateLimiter.tryConsume(clientAddress(request))) {
    return sendJson(response, 429, { error: 'rate_limited' })
  }

  if (!ttsBudget.tryConsume()) {
    console.error(`Daily TTS limit reached after ${ttsBudget.spent} clips`)
    return sendJson(response, 503, { error: 'daily_limit_reached' })
  }

  try {
    const pcm = await synthesize({
      persona,
      segments,
      language,
      maximumSeconds: MAX_SPEECH_SECONDS
    })
    ttsCache.set(key, pcm)
    sendAudio(response, pcm, segments)
  } catch (error) {
    console.error(`TTS request failed: ${error.message}`)
    // Three outcomes the app treats differently: the words were refused every
    // time and are worth reporting, the project is momentarily out of quota and
    // trying later will work, or something is broken and it should fall back to
    // a bundled tone.
    const status = [422, 429].includes(error.status) ? error.status : 502
    const body = { 422: 'rejected', 429: 'busy' }[status] ?? 'upstream_unavailable'
    sendJson(response, status, { error: body })
  }
}

const sendAudio = (response, pcm, segments) => {
  const headers = {
    'Content-Type': 'audio/L16',
    'Content-Length': pcm.length,
    'X-Sample-Rate': String(SAMPLE_RATE),
    'Cache-Control': 'no-store'
  }
  // What the line was actually performed as, in order. The app has no other way
  // to see what a model chose, and neither does anyone debugging a clip that
  // came out wrong.
  if (segments) headers['X-Emotions'] = segments.map((s) => s.emotion ?? 'neutral').join(',')
  response.writeHead(200, headers)
  response.end(pcm)
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost')

  if (url.pathname === '/healthz') {
    return sendJson(response, 200, { ok: true })
  }

  if (url.pathname === '/v1/tts') {
    if (process.env.LEGACY_TTS_DISABLED === '1') {
      return sendJson(response, 410, { error: 'membership_generation_required' })
    }
    return handleTTS(request, response)
  }

  if (url.pathname.startsWith('/v1/membership/')) {
    if (!membershipHandler) return sendJson(response, 503, { error: 'membership_not_configured' })
    return membershipHandler(request, response)
  }

  if (request.method !== 'GET' || url.pathname !== '/v1/weather') {
    return sendJson(response, 404, { error: 'not_found' })
  }

  // Raises the bar against casual scraping of the quota. It is not real
  // authentication — the secret ships in the APK too — so the daily cap and
  // Cloud Run's own limits stay the actual backstop.
  if (sharedSecret && request.headers['x-rainyclock-key'] !== sharedSecret) {
    return sendJson(response, 401, { error: 'unauthorized' })
  }

  const latitude = finiteNumber(url.searchParams.get('lat'), -90, 90)
  const longitude = finiteNumber(url.searchParams.get('lon'), -180, 180)
  const timezone = url.searchParams.get('tz')

  if (latitude === null || longitude === null || !timezone) {
    return sendJson(response, 400, { error: 'lat, lon and tz are required' })
  }

  const query = {
    latitude,
    longitude,
    timezone,
    language: url.searchParams.get('lang') || 'en',
    start: url.searchParams.get('start'),
    end: url.searchParams.get('end')
  }

  // Served from memory, so it costs no allowance and no caller can be throttled
  // out of an answer somebody else already paid for.
  const key = cacheKey(query)
  const cached = responseCache.get(key)
  if (cached) {
    return sendJson(response, 200, cached)
  }

  if (!rateLimiter.tryConsume(clientAddress(request))) {
    return sendJson(response, 429, { error: 'rate_limited' })
  }

  if (!dailyBudget.tryConsume()) {
    // Loud, because reaching this on real traffic means the limit is wrong,
    // and reaching it otherwise means the URL is being abused.
    console.error(`Daily upstream limit reached after ${dailyBudget.spent} calls`)
    return sendJson(response, 503, { error: 'daily_limit_reached' })
  }

  try {
    const weather = await fetchWeather(query)
    const body = { hours: projectHours(weather) }
    responseCache.set(key, body)
    sendJson(response, 200, body)
  } catch (error) {
    // 401 from Apple means the token is wrong — a configuration fault, not a
    // client one. Say so in the log; the client only ever needs "try later".
    console.error(`Weather request failed: ${error.message}`)
    sendJson(response, 502, { error: 'upstream_unavailable' })
  }
})

server.listen(Number(PORT), () => {
  console.log(`weather-proxy listening on ${PORT}`)
})
