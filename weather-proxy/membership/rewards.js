'use strict'

const { createHash, timingSafeEqual } = require('node:crypto')

function fail(code, status = 401) { const error = new Error(code); error.code = code; error.statusCode = status; throw error }

function parseLevelPlayTimestamp(timestamp) {
  // LevelPlay sends YYYYMMDDHHMM, not Unix seconds/milliseconds. The official
  // dashboard callback's minute matches UTC. Reject date rollover and never
  // reinterpret malformed calendar timestamps as a different numeric format.
  const year = Number(timestamp.slice(0, 4)), month = Number(timestamp.slice(4, 6))
  const day = Number(timestamp.slice(6, 8)), hour = Number(timestamp.slice(8, 10))
  const minute = Number(timestamp.slice(10, 12))
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute))
  if (date.getUTCFullYear() !== year || date.getUTCMonth() + 1 !== month ||
      date.getUTCDate() !== day || date.getUTCHours() !== hour || date.getUTCMinutes() !== minute) {
    fail('invalid_reward_callback')
  }
  return date.getTime()
}

// LevelPlay (ironSource mediation), NOT Unity Ads' different HMAC protocol.
// https://docs.unity.com/en-us/grow/levelplay/platform/settings/server-to-server-callback
// Timestamp/signature: https://docs.unity.com/en-us/grow/levelplay/platform/settings/event-handlers
// Configure literal URL fields: userId=[USER_ID]&rewards=[REWARDS]&eventId=[EVENT_ID].
// timestamp and signature are attached by LevelPlay when a private key is set.
function createLevelPlayVerifier({ privateKey, now = Date.now, maximumAgeMs = 9 * 24 * 60 * 60_000 }) {
  // LevelPlay does not impose a documented minimum key length. Accept the
  // configured key exactly as supplied, but never enable unsigned callbacks.
  if (typeof privateKey !== 'string' || !privateKey.trim()) fail('levelplay_s2s_not_configured', 503)
  function verify(input) {
    const query = input instanceof URLSearchParams ? input : new URLSearchParams(input)
    for (const name of ['userId', 'rewards', 'eventId', 'timestamp', 'signature']) {
      if (query.getAll(name).length !== 1) fail('invalid_reward_callback')
    }
    const userId = query.get('userId'), rewards = query.get('rewards'), eventId = query.get('eventId')
    const timestamp = query.get('timestamp'), signature = query.get('signature')
    // A fixed-width server-issued USER_ID also prevents ambiguous boundaries
    // between eventId and userId in LevelPlay's unseparated signature input.
    if (!/^[a-f0-9]{48}$/.test(userId) || !/^[A-Za-z0-9_-]{1,128}$/.test(eventId) ||
        rewards !== '1' || !/^[0-9]{12}$/.test(timestamp) || !/^[a-f0-9]{32}$/i.test(signature)) {
      fail('invalid_reward_callback')
    }
    // Keep the exact platform timestamp representation in its signature input.
    const issuedAt = parseLevelPlayTimestamp(timestamp), verifiedAt = now()
    if (issuedAt > verifiedAt + 5 * 60_000 || issuedAt < verifiedAt - maximumAgeMs) fail('expired_reward_callback')
    const signedPayload = timestamp + eventId + userId + rewards
    const expected = createHash('md5').update(signedPayload + privateKey, 'utf8').digest()
    const actual = Buffer.from(signature, 'hex')
    if (!timingSafeEqual(expected, actual)) fail('invalid_reward_signature')
    // dynamicUserId, custom_*, APP_KEY/placement are not included in LevelPlay's
    // signature formula. Never use any of them to choose a member or grant amount.
    // Persist both the provider event and exact signed-payload fingerprint as
    // atomic replay guards, in addition to the fixed-width timestamp/user ID.
    const proofId = createHash('sha256').update(signedPayload, 'utf8').digest('hex')
    return { provider: 'levelplay', eventId, proofId, rewardUserId: userId, amount: 1, issuedAt,
      verifiedAt, acknowledgement: `${eventId}:OK` }
  }
  return { verify }
}

module.exports = { createLevelPlayVerifier }
