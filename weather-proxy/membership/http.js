'use strict'

const { createRateLimiter, clientAddress } = require('../guards')
const { completeMemberDeletion } = require('./maintenance')

function error(code, status = 400) { return Object.assign(new Error(code), { code, status }) }
const json = (res, status, value) => {
  const bytes = Buffer.from(JSON.stringify(value))
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': bytes.length, 'Cache-Control': 'no-store' })
  res.end(bytes)
}
async function readBody(req, maximum = 384_000) {
  const parts = []; let length = 0
  for await (const part of req) {
    length += part.length
    if (length > maximum) throw error('body_too_large', 413)
    parts.push(part)
  }
  const raw = Buffer.concat(parts)
  let body
  try { body = JSON.parse(raw.toString('utf8')) } catch { throw error('invalid_json') }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw error('invalid_body')
  return { raw, body }
}

// Only the fixed vocabulary of error codes and the route reach the log: never a
// JWS, assertion, token, body, header or provider text. The 2026-10-03 incident
// (a phone's App Attest assertion rejected on every launch) could only be
// diagnosed from latency and response size because nothing logged the code.
const LOGGED_PATH = /^\/v1\/membership\/[A-Za-z0-9/_-]{1,64}$/
const LOGGED_CODE = /^[a-z0-9_]{1,64}$/
function requestFailureLine(path, status, code) {
  return { event: 'membership_request_failed', severity: status >= 500 ? 'ERROR' : 'NOTICE',
    path: typeof path === 'string' && LOGGED_PATH.test(path) ? path : 'invalid_path',
    status, code: typeof code === 'string' && LOGGED_CODE.test(code) ? code : 'unrecognized_code' }
}

// Dependency injection is intentional: HTTP contracts can be tested without
// issuing a real Apple purchase, ad impression, speech request or cloud write.
function createMembershipHandler({ membership, auth, apple, rewards, generation, validateInput,
  log = (line) => console.log(JSON.stringify(line)) }) {
  const limiter = createRateLimiter({ limit: 120, windowMs: 60_000 })
  const sync = async (memberId, appTransactionId) => {
    await generation.recoverAbandoned(memberId)
    const latest = await apple.reconcile(appTransactionId)
    return membership.reconcileVerifiedPurchases(memberId, latest.transactions)
  }
  async function transactions(memberId, signed) {
    if (!Array.isArray(signed) || signed.length > 30) throw error('invalid_transactions')
    const verified = await Promise.all(signed.map((value) => apple.verifyTransaction(value)))
    return membership.reconcileVerifiedPurchases(memberId, verified)
  }
  return async (req, res) => {
    const url = new URL(req.url, 'http://localhost')
    if (!url.pathname.startsWith('/v1/membership/')) return false
    try {
      if (url.pathname === '/v1/membership/levelplay/callback') {
        if (req.method !== 'GET') throw error('method_not_allowed', 405)
        if (!rewards) throw error('levelplay_s2s_not_configured', 503)
        const reward = rewards.verify(url.searchParams)
        const memberId = await auth.resolveRewardMember(reward.rewardUserId)
        if (!memberId) throw error('reward_member_unavailable', 410)
        await membership.creditVerifiedReward({ provider: 'levelplay', eventId: reward.eventId,
          proofId: reward.proofId, memberId })
        res.writeHead(200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' })
        res.end(reward.acknowledgement)
        return true
      }
      if (req.method !== 'POST') throw error('method_not_allowed', 405)
      // Notification verification must not be throttled by client spoofable IPs.
      if (url.pathname !== '/v1/membership/apple/notifications' && !limiter.tryConsume(clientAddress(req))) {
        throw error('rate_limited', 429)
      }
      const { raw, body } = await readBody(req)
      if (url.pathname === '/v1/membership/apple/notifications') {
        const event = await apple.verifyNotification(body.signedPayload)
        if (event.transaction) {
          const purchase = { ...event.transaction }
          if (event.status !== null && event.status !== undefined) {
            purchase.status = event.status
            purchase.statusVerifiedAt = event.signedDate
            purchase.gracePeriodExpiresDate = event.renewal?.gracePeriodExpiresDate ?? null
          }
          await membership.applyVerifiedNotification({ notificationId: event.notificationUUID, purchase })
        }
        json(res, 200, { received: true })
      } else if (url.pathname === '/v1/membership/challenge') {
        json(res, 200, await auth.issueChallenge(body))
      } else if (url.pathname === '/v1/membership/session') {
        const bootstrap = await auth.bootstrapIdentityAndDevice({ rawBody: raw, headers: req.headers, method: req.method, path: url.pathname })
        const state = await membership.recognizeMember({ ...bootstrap.identity, timeZone: bootstrap.timeZone })
        await transactions(state.memberId, bootstrap.signedTransactions || [])
        const refreshed = await sync(state.memberId, bootstrap.identity.appTransactionId)
        const session = await auth.issueSession({ memberId: state.memberId, bootstrap })
        json(res, 200, { ...session, state: refreshed })
      } else {
        const token = /^Bearer (\S+)$/.exec(req.headers.authorization || '')?.[1]
        const identity = await auth.authenticate({ token, headers: req.headers, rawBody: raw, method: req.method, path: url.pathname })
        let result
        let responseStatus = 200
        switch (url.pathname) {
        case '/v1/membership/status':
          result = await sync(identity.memberId, identity.appTransactionId)
          break
        case '/v1/membership/purchases':
          await transactions(identity.memberId, body.signedTransactions)
          result = await sync(identity.memberId, identity.appTransactionId)
          break
        case '/v1/membership/time-zone':
          result = await membership.setTimeZone(identity.memberId, body.timeZone)
          break
        case '/v1/membership/rewards/identity':
          if (!rewards) throw error('levelplay_s2s_not_configured', 503)
          result = await auth.getRewardIdentity(identity.memberId)
          break
        case '/v1/membership/migration':
          result = await membership.quarantineLegacyMigration(identity.memberId, body)
          break
        case '/v1/membership/generations': {
          validateInput(body.input)
          // Reconcile before consuming paid benefits; an outage cannot spend or
          // invent quota, and never falls back to the legacy anonymous endpoint.
          await sync(identity.memberId, identity.appTransactionId)
          const output = await generation.execute({ memberId: identity.memberId, requestId: body.requestId, input: body.input })
          result = { ...output, pcm: output.pcm?.toString('base64'), state: await membership.status(identity.memberId) }
          break
        }
        case '/v1/membership/generations/result': {
          await generation.recoverAbandoned(identity.memberId)
          const output = await generation.getResult({ memberId: identity.memberId, requestId: body.requestId })
          result = { ...output, pcm: output.pcm?.toString('base64'), state: await membership.status(identity.memberId) }
          break
        }
        case '/v1/membership/delete':
          try {
            result = await membership.deleteMember(identity.memberId)
            await completeMemberDeletion({ membership, auth, memberId: identity.memberId })
          } catch (failure) {
            const marker = await membership.store.get(membership.memberPath(identity.memberId))
            if (!marker?.deletedAt) throw failure
            // Access was already revoked durably. The maintenance outbox will
            // complete erasure even though this session can no longer retry it.
            result = { deleted: true, subscriptionCancelled: false, cleanupPending: true }
            responseStatus = 202
          }
          break
        default: throw error('not_found', 404)
        }
        json(res, responseStatus, result)
      }
    } catch (failure) {
      const status = failure.statusCode || failure.status || 503
      const responseStatus = status >= 400 && status <= 599 ? status : 503
      // Firestore/gRPC errors carry a numeric code; only the server's own string codes are answered.
      const code = typeof failure.code === 'string' && failure.code ? failure.code : 'membership_unavailable'
      // No JWS, assertion, token, user text or provider raw response in logs.
      try { log(requestFailureLine(url.pathname, responseStatus, code)) } catch { /* Logging never changes the response. */ }
      json(res, responseStatus, { error: code })
    }
    return true
  }
}

module.exports = { createMembershipHandler, requestFailureLine }
