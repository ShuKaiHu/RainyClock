'use strict'

// Isolated membership entrypoint. Start with `node membership/server.js`; the
// existing weather/anonymous speech server is deliberately never imported.
const http = require('node:http')
const { createMembershipRuntime } = require('./runtime')
const { createMembershipRouter } = require('./router')
const { createRateLimiter } = require('../guards')

// Keep the body limit aligned with membership/http.js, including Apple proofs.
const MAX_BODY_BYTES = 384_000
const MAX_HEADER_BYTES = 16_384
const HEADERS_TIMEOUT_MS = 15_000
const REQUEST_TIMEOUT_MS = 30_000
// Speech may retry its 30-second upstream call. This closes an idle connection,
// not a running transaction; a retry still uses the existing idempotency ledger.
const SOCKET_TIMEOUT_MS = 120_000

function json(req, res, status, value, headers = {}) {
  if (res.destroyed || res.writableEnded) return
  const bytes = Buffer.from(JSON.stringify(value))
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': bytes.length,
    'Cache-Control': 'no-store', ...(!req.complete ? { Connection: 'close' } : {}), ...headers })
  res.end(req.method === 'HEAD' ? undefined : bytes)
}

function createMembershipServer({ env = process.env, createRuntime = createMembershipRuntime } = {}) {
  const enabled = env.MEMBERSHIP_ENABLED === '1'
  // Construct before opening any listener. Invalid Apple/App Attest/Firestore
  // configuration must never turn into a partially enabled HTTP service.
  const handler = enabled ? createMembershipRouter(env, createRuntime) : null
  if (enabled && typeof handler !== 'function') throw new Error('membership_not_configured')
  // Basic write protection shared by every caller and environment on this instance.
  // A constant key prevents rotated device keys or forwarded IPs bypassing it.
  // This resets on restart and is not a distributed production cost ceiling.
  const challengeLimiter = createRateLimiter({ limit: 60, windowMs: 60_000 })

  const server = http.createServer({ maxHeaderSize: MAX_HEADER_BYTES,
    headersTimeout: HEADERS_TIMEOUT_MS, requestTimeout: REQUEST_TIMEOUT_MS,
    keepAliveTimeout: 5_000 }, async (req, res) => {
    let pathname
    try {
      // Only origin-form targets are accepted; this is not a forwarding proxy.
      if (!req.url?.startsWith('/') || req.url.startsWith('//')) throw new Error('invalid_target')
      pathname = new URL(req.url, 'http://localhost').pathname
    } catch {
      return json(req, res, 400, { error: 'invalid_request' })
    }
    if (pathname === '/health') {
      if (!['GET', 'HEAD'].includes(req.method)) return json(req, res, 405, { error: 'method_not_allowed' }, { Allow: 'GET, HEAD' })
      // Liveness only: no external probes, credentials, project IDs or tokens.
      return json(req, res, 200, { ok: true, membershipEnabled: enabled })
    }
    if (!pathname.startsWith('/v1/membership/')) return json(req, res, 404, { error: 'not_found' })
    if (!handler) return json(req, res, 503, { error: 'membership_not_configured' })
    if (Number(req.headers['content-length']) > MAX_BODY_BYTES) return json(req, res, 413, { error: 'body_too_large' })
    if (req.method === 'POST' && pathname === '/v1/membership/challenge' &&
        !challengeLimiter.tryConsume('all-challenges')) {
      return json(req, res, 429, { error: 'challenge_rate_limited' }, { 'Retry-After': '60' })
    }
    try {
      // Pass raw request bytes through: App Attest assertions bind those bytes.
      // The existing handler bounds streamed bodies and performs all proofs,
      // per-client throttling, reconciliation, quota and persistent cost checks.
      if (!await handler(req, res)) json(req, res, 404, { error: 'not_found' })
    } catch {
      // Never expose arbitrary errors containing a JWS, token or upstream body.
      if (res.headersSent) res.destroy()
      else json(req, res, 503, { error: 'membership_unavailable' })
    }
  })
  server.setTimeout(SOCKET_TIMEOUT_MS)
  server.maxRequestsPerSocket = 100
  return server
}

async function startMembershipServer({ env = process.env, ...options } = {}) {
  const rawPort = env.PORT ?? '8080'
  if (!/^\d+$/.test(rawPort) || Number(rawPort) < 1 || Number(rawPort) > 65_535) throw new Error('invalid_port')
  const server = createMembershipServer({ env, ...options })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(Number(rawPort), '0.0.0.0', () => {
      server.removeListener('error', reject)
      resolve()
    })
  })
  return server
}

if (require.main === module) {
  startMembershipServer().then((server) => {
    console.log(JSON.stringify({ event: 'membership_server_listening', port: server.address().port,
      membershipEnabled: process.env.MEMBERSHIP_ENABLED === '1' }))
    let stopping = false
    const stop = () => {
      if (stopping) return
      stopping = true
      const deadline = setTimeout(() => process.exit(0), 8_000)
      deadline.unref()
      server.close(() => process.exit(0))
    }
    process.on('SIGTERM', stop)
    process.on('SIGINT', stop)
  }).catch(() => {
    console.error(JSON.stringify({ event: 'membership_server_start_failed' }))
    process.exitCode = 1
  })
}

module.exports = { createMembershipServer, startMembershipServer }
