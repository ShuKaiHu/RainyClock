'use strict'

const { buildPrompt } = require('./personas')
const { accessToken } = require('./google-auth')

// Speech synthesis through **Cloud Text-to-Speech**, not the Gemini Developer
// API, for three reasons that all point the same way.
//
// The contract: the Gemini API's terms say a developer "will not use the
// Services as part of a website, application, or other service ... that is
// directed towards or is likely to be accessed by individuals under the age of
// 18". An alarm clock cannot honestly promise that. Those same terms state, for
// clarity, that they "do not govern your direct use of any Google Cloud Platform
// service", and Cloud Text-to-Speech is one — governed instead by the Cloud
// Platform terms, which carry no such clause.
//
// The limits: `gemini-2.5-flash-tts` on the Developer API is capped at 100
// requests per *day* on a paid Tier 1 project — the whole app's budget, not one
// user's. The same model through Cloud TTS runs at 150 queries per *minute*,
// raisable on request.
//
// The credential: there isn't one. Cloud Run's service account authenticates
// this, so no key is created, stored, rotated, or leaked.

const ENDPOINTS = Object.freeze({
  global: 'https://texttospeech.googleapis.com/v1/text:synthesize',
  us: 'https://us-texttospeech.googleapis.com/v1/text:synthesize',
  eu: 'https://eu-texttospeech.googleapis.com/v1/text:synthesize'
})

/**
 * Which project the call is billed and quota-counted against. Implicit for a
 * service account on Cloud Run, but required when a developer runs this against
 * their own Application Default Credentials — without it the API answers 403
 * asking for a quota project, which reads as a permission problem and is not one.
 */
const PROJECT = process.env.GOOGLE_CLOUD_PROJECT ?? 'rainyclock'

// The cheap model, which the Developer API's daily cap had forced us off.
const MODEL = process.env.GEMINI_TTS_MODEL ?? 'gemini-2.5-flash-tts'

// Cloud TTS takes an explicit locale, which the Developer API had no field for.
const LANGUAGE_CODES = { 'zh-Hant': 'cmn-TW', en: 'en-US' }

const UPSTREAM_TIMEOUT_MS = 30_000

// Callers may bound provider work without changing the legacy weather service.
// Use a closed region list: a configuration typo must never send credentials to
// an arbitrary host. These are server options, not fields accepted from an app.
function normalizeSynthesisOptions(options = {}) {
  const { endpointRegion = 'global', timeoutMs = UPSTREAM_TIMEOUT_MS,
    maxAttempts = 3, retryNetworkErrors = true } = options
  if (!Object.hasOwn(ENDPOINTS, endpointRegion) || !Number.isInteger(timeoutMs) ||
      timeoutMs < 1 || timeoutMs > 120_000 || !Number.isInteger(maxAttempts) ||
      maxAttempts < 1 || maxAttempts > 3 || typeof retryNetworkErrors !== 'boolean') {
    throw new Error('invalid_tts_request_options')
  }
  return Object.freeze({ endpointRegion, timeoutMs, maxAttempts, retryNetworkErrors })
}

/** 16-bit mono PCM at this rate, matching what the app assembles against. */
const SAMPLE_RATE = 24_000
const BYTES_PER_SECOND = SAMPLE_RATE * 2

/**
 * A hard ceiling on returned audio, enforced here rather than trusted from the
 * client. The model has no duration parameter — you send words and it decides
 * how long to talk — so this is the only place the length is actually bounded.
 * Cut on an even byte so a sample is never split in half.
 */
function truncateToSeconds(pcm, seconds) {
  const limit = Math.floor(seconds * BYTES_PER_SECOND / 2) * 2
  return pcm.length > limit ? pcm.subarray(0, limit) : pcm
}

/**
 * Strips the RIFF container Cloud TTS wraps LINEAR16 in, since the app is handed
 * bare samples and builds its own header.
 *
 * The `data` chunk is located rather than assumed to start at byte 44: a WAV may
 * legally carry `LIST` or other chunks before it, and a fixed offset would ship
 * a few milliseconds of metadata as audio.
 */
function pcmFromWav(buffer) {
  if (buffer.length < 12 || buffer.toString('ascii', 0, 4) !== 'RIFF') {
    return buffer
  }
  let offset = 12
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString('ascii', offset, offset + 4)
    const size = buffer.readUInt32LE(offset + 4)
    if (id === 'data') {
      return buffer.subarray(offset + 8, Math.min(offset + 8 + size, buffer.length))
    }
    offset += 8 + size + (size % 2)
  }
  return buffer
}

/**
 * Synthesizes one clip. Throws with `.status` set so the caller can tell a bad
 * request from an upstream fault.
 *
 * Retries are short and few, because a caller is waiting and the app's fallback
 * to a bundled tone beats a long stall. Three things are retried:
 *
 * - 5xx, which this model produces intermittently.
 * - 429. The quota is per project, not per caller, so two users generating at
 *   the same moment can trip it even though neither did anything wrong. It gets
 *   a real backoff rather than the immediate retry the others get, and if it
 *   survives that it is reported as 429 — "busy, try again" is actionable, where
 *   the 502 it used to collapse into was not.
 * - A refusal by the safety filter, which measurement showed is *noise rather
 *   than judgement*: "早安，該起床囉" — good morning, time to get up — was refused
 *   on roughly one call in six while identical requests either side succeeded.
 *
 * A refusal that survives every attempt is passed on as 422, because at that
 * point it probably is about the words.
 */
async function synthesize({ persona, segments, language, maximumSeconds }, options = {}) {
  const { endpointRegion, timeoutMs, maxAttempts, retryNetworkErrors } = normalizeSynthesisOptions(options)
  const built = buildPrompt({ persona, segments, language })
  if (!built) {
    const error = new Error('unknown persona or empty text')
    error.status = 400
    throw error
  }

  const body = JSON.stringify({
    input: { text: built.spoken, prompt: built.style },
    voice: {
      languageCode: LANGUAGE_CODES[built.language] ?? 'en-US',
      name: built.voice,
      model_name: MODEL
    },
    audioConfig: { audioEncoding: 'LINEAR16', sampleRateHertz: SAMPLE_RATE }
  })

  let lastError = null
  let blockedEveryTime = true
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    let response
    try {
      const token = await accessToken()
      response = await fetch(ENDPOINTS[endpointRegion], {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'x-goog-user-project': PROJECT
        },
        body,
        signal: AbortSignal.timeout(timeoutMs)
      })
    } catch (cause) {
      lastError = new Error(`text-to-speech unreachable: ${cause.message}`)
      // An aborted HTTP request can still finish (and incur cost) at Google.
      // Membership uses one attempt; never quietly synthesize the same request
      // again just because the first response did not reach this process.
      if (!retryNetworkErrors) break
      continue
    }

    if (response.status === 429) {
      lastError = new Error('text-to-speech rate limited')
      lastError.rateLimited = true
      if (maxAttempts === 1) break
      await new Promise((resolve) => setTimeout(resolve, 1_000 * (attempt + 1)))
      continue
    }

    if (response.status >= 500) {
      lastError = new Error(`text-to-speech responded ${response.status}`)
      continue
    }

    if (!response.ok) {
      const detail = await response.text().catch(() => '')
      if (/blocked|safety|prohibited/i.test(detail)) {
        lastError = new Error('text-to-speech blocked the content')
        lastError.blocked = true
        continue
      }
      blockedEveryTime = false
      const error = new Error(`text-to-speech rejected the request: ${detail.slice(0, 300)}`)
      error.status = response.status === 400 || response.status === 403 ? 422 : 502
      throw error
    }

    blockedEveryTime = false
    const payload = await response.json().catch(() => null)
    if (!payload?.audioContent) {
      lastError = new Error('text-to-speech returned no audio')
      continue
    }

    const pcm = pcmFromWav(Buffer.from(payload.audioContent, 'base64'))
    if (pcm.length === 0) {
      lastError = new Error('text-to-speech returned an empty clip')
      continue
    }

    return truncateToSeconds(pcm, maximumSeconds)
  }

  const error = lastError ?? new Error('text-to-speech failed')
  if (lastError?.rateLimited) {
    error.status = 429
  } else {
    error.status = blockedEveryTime && lastError?.blocked ? 422 : 502
  }
  throw error
}

module.exports = { synthesize, normalizeSynthesisOptions, pcmFromWav, truncateToSeconds,
  SAMPLE_RATE, BYTES_PER_SECOND, MODEL }
