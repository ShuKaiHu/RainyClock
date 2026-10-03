'use strict'

const { randomBytes, createHash } = require('node:crypto')
const { deleteMemberAuthData } = require('./maintenance')

const sha256 = (data) => createHash('sha256').update(data).digest('hex')
const randomToken = () => randomBytes(32).toString('base64url')
function fail(code, status = 401) { const error = new Error(code); error.code = code; error.statusCode = status; throw error }
function safeKey(keyID) {
  if (!/^[A-Za-z0-9+/]{43}=$/.test(keyID || '')) fail('invalid_device_key')
  return sha256(keyID)
}
function tokenHash(token) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token || '')) fail('invalid_session')
  return sha256(token)
}
function header(headers, name) {
  const value = headers?.[name.toLowerCase()] ?? headers?.[name]
  if (typeof value !== 'string' || value.length > 32_000) return null
  return value
}

// UTF-8, literal LF separators, no trailing LF. Raw body bytes, including JSON
// whitespace/key order, are hashed, so neither side needs a JSON canonicalizer.
function requestPayload({ purpose, challenge, method, path, rawBody = Buffer.alloc(0) }) {
  if (!['bootstrap', 'request'].includes(purpose) || !/^[A-Z]+$/.test(method || '') ||
      !/^\/v1\/membership\/[A-Za-z0-9/_-]+$/.test(path || '') || !Buffer.isBuffer(rawBody)) fail('invalid_request_binding')
  return Buffer.from(['RainyClockMembershipV1', purpose, challenge.id, challenge.challenge,
    method, path, sha256(rawBody)].join('\n'), 'utf8')
}

function createMembershipAuth({ store, appleVerifier, attestationVerifier, now = Date.now,
  challengeLifetimeMs = 5 * 60_000, sessionLifetimeMs = 24 * 60 * 60_000 }) {
  if (!store || !appleVerifier || !attestationVerifier) fail('membership_auth_not_configured', 503)
  const bootstrapCapabilities = new WeakSet()
  async function issueChallenge({ purpose, keyID, sessionToken }) {
    if (!['bootstrap', 'request'].includes(purpose)) fail('invalid_challenge_purpose', 400)
    const deviceKeyHash = safeKey(keyID)
    const sessionHash = purpose === 'request' ? tokenHash(sessionToken) : null
    const challenge = { id: randomToken(), challenge: randomToken(), expiresAt: now() + challengeLifetimeMs }
    await store.runTransaction(async (tx) => {
      let session
      if (sessionHash) {
        session = await tx.get(`authSessions/${sessionHash}`)
        const device = await tx.get(`authDevices/${deviceKeyHash}`)
        const member = session ? await tx.get(`members/${session.memberId}`) : null
        if (!session || !device || !member || member.deletedAt || member.deleted || session.expiresAt <= now() ||
            session.deviceKeyHash !== deviceKeyHash || device.bootstrapId !== session.bootstrapId ||
            device.memberId !== session.memberId) fail('invalid_session')
      }
      // A short per-key throttle limits challenge amplification. Cloud Run edge
      // rate limits must also cap unauthenticated bootstrap traffic by source.
      const throttlePath = `authChallengeLimits/${deviceKeyHash}`
      const prior = await tx.get(throttlePath)
      const windowAt = Math.floor(now() / 60_000)
      const count = prior?.windowAt === windowAt ? prior.count + 1 : 1
      if (count > 30) fail('challenge_rate_limited', 429)
      tx.set(throttlePath, { windowAt, count, expiresAt: new Date(now() + 10 * 60_000) })
      tx.set(`authChallenges/${challenge.id}`, { ...challenge, purpose, deviceKeyHash, sessionHash,
        memberId: session?.memberId || null, ttlAt: new Date(challenge.expiresAt) })
    })
    return challenge
  }
  async function loadChallenge(headers, purpose, deviceKeyHash, sessionHash = null) {
    const id = header(headers, 'X-RC-Challenge')
    if (!/^[A-Za-z0-9_-]{43}$/.test(id || '')) fail('invalid_challenge')
    const challenge = await store.get(`authChallenges/${id}`)
    if (!challenge || challenge.purpose !== purpose || challenge.deviceKeyHash !== deviceKeyHash ||
        challenge.sessionHash !== sessionHash || challenge.expiresAt <= now()) fail('invalid_challenge')
    return challenge
  }
  async function bootstrapIdentityAndDevice({ rawBody, headers, method = 'POST', path = '/v1/membership/session' }) {
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { fail('invalid_json', 400) }
    const keyID = header(headers, 'X-RC-Key-ID')
    if (body.keyID !== keyID) fail('device_key_mismatch')
    const deviceKeyHash = safeKey(keyID)
    const challenge = await loadChallenge(headers, 'bootstrap', deviceKeyHash)
    const payload = requestPayload({ purpose: 'bootstrap', challenge, method, path, rawBody })
    const attestation = header(headers, 'X-RC-Attestation')
    const assertion = header(headers, 'X-RC-Assertion')
    if (!!attestation === !!assertion) fail('device_proof_required')
    const priorDevice = await store.get(`authDevices/${deviceKeyHash}`)
    let verifiedDevice
    if (attestation) {
      if (priorDevice) fail('device_key_already_registered')
      verifiedDevice = await attestationVerifier.verifyAttestation({ keyID, attestation, payload })
    } else {
      if (!priorDevice) fail('key_not_registered')
      const result = await attestationVerifier.verifyAssertion({ assertion, payload, device: priorDevice })
      verifiedDevice = { ...priorDevice, signCount: result.signCount }
    }
    const identity = await appleVerifier.verifyAppTransaction(body.signedAppTransaction, body.deviceVerificationID)
    const proofHash = identity.proofId
    if (!/^[a-f0-9]{64}$/.test(proofHash || '')) fail('verified_proof_fingerprint_required')
    const bootstrapId = randomToken()
    await store.runTransaction(async (tx) => {
      const currentChallenge = await tx.get(`authChallenges/${challenge.id}`)
      const currentDevice = await tx.get(`authDevices/${deviceKeyHash}`)
      const usedProof = await tx.get(`authAppleProofs/${proofHash}`)
      if (!currentChallenge || currentChallenge.expiresAt <= now()) fail('challenge_replayed')
      if (usedProof && usedProof.deviceKeyHash !== deviceKeyHash) fail('apple_proof_replayed_on_other_device')
      if (attestation && currentDevice) fail('device_key_already_registered')
      if (assertion && (!currentDevice || verifiedDevice.signCount <= currentDevice.signCount ||
          currentDevice.publicKey !== priorDevice.publicKey)) fail('assertion_replayed')
      tx.delete(`authChallenges/${challenge.id}`)
      tx.set(`authAppleProofs/${proofHash}`, { deviceKeyHash,
        ttlAt: new Date(now() + challengeLifetimeMs) })
      tx.set(`authDevices/${deviceKeyHash}`, { ...verifiedDevice, keyID, deviceKeyHash, bootstrapId,
        // Keep a previous owner until rebinding so deletion can find this key
        // during a failed/in-flight bootstrap. The changed bootstrapId revokes
        // every old session immediately, even on A -> B -> A account switches.
        memberId: currentDevice?.memberId || null, appTransactionId: identity.appTransactionId,
        environment: verifiedDevice.environment, appleEnvironment: identity.environment, verifiedAt: now(),
        ttlAt: new Date(now() + 60 * 60_000) })
    })
    const result = { identity, deviceKeyHash, bootstrapId, timeZone: body.timeZone,
      signedTransactions: body.signedTransactions || [] }
    bootstrapCapabilities.add(result)
    return result
  }
  async function issueSession({ memberId, bootstrap }) {
    if (!bootstrapCapabilities.has(bootstrap) || !/^[A-Za-z0-9_-]{1,128}$/.test(memberId || '')) fail('invalid_bootstrap')
    bootstrapCapabilities.delete(bootstrap)
    const token = randomToken()
    const expiresAt = now() + sessionLifetimeMs
    await store.runTransaction(async (tx) => {
      const device = await tx.get(`authDevices/${bootstrap.deviceKeyHash}`)
      const member = await tx.get(`members/${memberId}`)
      if (!member || member.deletedAt || member.deleted) fail('member_deleted')
      if (!device || device.bootstrapId !== bootstrap.bootstrapId) fail('bootstrap_superseded')
      tx.set(`authDevices/${bootstrap.deviceKeyHash}`, { ...device, memberId, ttlAt: null })
      tx.set(`authSessions/${sha256(token)}`, { memberId, deviceKeyHash: bootstrap.deviceKeyHash,
        bootstrapId: bootstrap.bootstrapId,
        appTransactionId: bootstrap.identity.appTransactionId, appleEnvironment: bootstrap.identity.environment,
        createdAt: now(), expiresAt, ttlAt: new Date(expiresAt) })
    })
    return { token, expiresAt, memberId }
  }
  async function authenticate({ token, headers, rawBody = Buffer.alloc(0), method, path }) {
    const sessionHash = tokenHash(token)
    const keyID = header(headers, 'X-RC-Key-ID')
    const deviceKeyHash = safeKey(keyID)
    const session = await store.get(`authSessions/${sessionHash}`)
    const device = await store.get(`authDevices/${deviceKeyHash}`)
    if (!session || !device || session.expiresAt <= now() || session.deviceKeyHash !== deviceKeyHash ||
        device.bootstrapId !== session.bootstrapId ||
        device.memberId !== session.memberId || device.appTransactionId !== session.appTransactionId ||
        device.appleEnvironment !== session.appleEnvironment) fail('invalid_session')
    const challenge = await loadChallenge(headers, 'request', deviceKeyHash, sessionHash)
    const payload = requestPayload({ purpose: 'request', challenge, method, path, rawBody })
    const result = await attestationVerifier.verifyAssertion({ assertion: header(headers, 'X-RC-Assertion'), payload, device })
    await store.runTransaction(async (tx) => {
      const currentChallenge = await tx.get(`authChallenges/${challenge.id}`)
      const currentSession = await tx.get(`authSessions/${sessionHash}`)
      const currentDevice = await tx.get(`authDevices/${deviceKeyHash}`)
      const member = await tx.get(`members/${session.memberId}`)
      if (!member || member.deletedAt || member.deleted) fail('member_deleted')
      if (!currentChallenge || currentChallenge.expiresAt <= now()) fail('challenge_replayed')
      if (!currentSession || currentSession.expiresAt <= now() || !currentDevice ||
          currentDevice.bootstrapId !== session.bootstrapId || currentSession.bootstrapId !== session.bootstrapId ||
          currentDevice.memberId !== session.memberId || currentDevice.appTransactionId !== session.appTransactionId ||
          currentDevice.publicKey !== device.publicKey || result.signCount <= currentDevice.signCount) fail('assertion_replayed')
      tx.delete(`authChallenges/${challenge.id}`)
      tx.set(`authDevices/${deviceKeyHash}`, { ...currentDevice, signCount: result.signCount, lastUsedAt: now() })
    })
    return { memberId: session.memberId, deviceKeyHash, appTransactionId: session.appTransactionId,
      environment: session.appleEnvironment }
  }
  async function deleteMemberAuth(memberId) {
    return deleteMemberAuthData({ store, memberId })
  }
  async function getRewardIdentity(memberId) {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(memberId || '')) fail('invalid_member')
    return store.runTransaction(async (tx) => {
      const member = await tx.get(`members/${memberId}`)
      const existing = await tx.get(`authMemberRewards/${memberId}`)
      if (!member || member.deletedAt || member.deleted) fail('member_deleted')
      if (existing) return { userId: existing.userId }
      const userId = randomBytes(24).toString('hex')
      tx.set(`authMemberRewards/${memberId}`, { userId, memberId, createdAt: now() })
      tx.set(`authRewardUsers/${userId}`, { memberId, createdAt: now() })
      return { userId }
    })
  }
  async function resolveRewardMember(userId) {
    if (!/^[A-Za-z0-9]{16,64}$/.test(userId || '')) fail('invalid_reward_user')
    const owner = await store.get(`authRewardUsers/${userId}`)
    const member = owner ? await store.get(`members/${owner.memberId}`) : null
    if (!owner || !member || member.deletedAt || member.deleted) fail('unknown_reward_user')
    return owner.memberId
  }
  return { issueChallenge, bootstrapIdentityAndDevice, issueSession, authenticate, deleteMemberAuth,
    getRewardIdentity, resolveRewardMember }
}

module.exports = { createMembershipAuth, requestPayload, sha256 }
