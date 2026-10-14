'use strict'

const { randomUUID } = require('node:crypto')
const { MembershipError, requireMember } = require('./service')

function canonicalJSON(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value)
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (value && Object.getPrototypeOf(value) === Object.prototype) {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonicalJSON(value[k])}`).join(',')}}`
  }
  throw new MembershipError('invalid_generation_input', 400)
}

function createGenerationService({ membership, generate, clock = membership?.clock ?? Date.now }) {
  if (!membership || typeof generate !== 'function') throw new Error('invalid_generation_config')
  const { store, policy } = membership
  const keyFor = (requestId) => {
    if (typeof requestId !== 'string' || !/^[a-zA-Z0-9_-]{8,128}$/.test(requestId)) throw new MembershipError('invalid_request_id', 400)
    return membership.hash(`generation:${requestId}`)
  }
  const paths = (memberId, key) => ({ member: membership.memberPath(memberId),
    job: `${membership.memberPath(memberId)}/generations/${key}`,
    result: `${membership.memberPath(memberId)}/generationResults/${key}` })
  async function reserve(memberId, requestId, input) {
    const key = keyFor(requestId)
    const path = paths(memberId, key)
    const encoded = canonicalJSON(input)
    if (Buffer.byteLength(encoded) > 8_192) throw new MembershipError('generation_input_too_large', 400)
    const inputHash = membership.hash(`generation-input:${encoded}`)
    const now = clock()
    const workerToken = randomUUID()
    return store.runTransaction(async (tx) => {
      const context = await membership.readContext(tx, memberId, now)
      const existing = await tx.get(path.job)
      if (existing) {
        if (existing.inputHash !== inputHash) throw new MembershipError('idempotency_conflict', 409)
        return { key, ...existing, owned: false }
      }
      const member = context.member
      let funding
      if (context.entitlements.dailyAI && context.day.used + context.day.reserved < 1) {
        funding = { kind: 'daily', dayPath: context.dayPath }
      } else if (!context.entitlements.dailyAI && member.freeUsed + member.freeReserved < member.freeGranted) {
        // Paid users use only their daily allowance or a verified reward. An
        // old free balance is preserved for a later return to the free tier.
        funding = { kind: 'free' }
      } else if (member.rewardUsed + member.rewardReserved < member.rewardGranted) {
        funding = { kind: 'reward' }
      } else {
        throw new MembershipError(member.migrationPending && !context.entitlements.dailyAI
          ? 'legacy_migration_pending' : 'quota_exhausted', 402)
      }
      const job = { inputHash, workerToken, state: 'processing', createdAt: now,
        leaseUntil: now + policy.generationLeaseMs, funding, error: null }
      if (funding.kind === 'daily') tx.set(context.dayPath, { ...context.day, reserved: context.day.reserved + 1 })
      if (funding.kind === 'free') member.freeReserved += 1
      if (funding.kind === 'reward') member.rewardReserved += 1
      tx.set(path.member, member)
      tx.set(path.job, job)
      return { key, ...job, owned: true }
    })
  }
  function updateFunding(tx, member, job, day, succeeded) {
    if (job.funding.kind === 'daily') {
      if (!day || day.reserved < 1) throw new MembershipError('quota_invariant_failed', 500)
      tx.set(job.funding.dayPath, { ...day, reserved: day.reserved - 1, used: day.used + (succeeded ? 1 : 0) })
    } else {
      const prefix = job.funding.kind === 'free' ? 'free' : 'reward'
      if (member[`${prefix}Reserved`] < 1) throw new MembershipError('quota_invariant_failed', 500)
      member[`${prefix}Reserved`] -= 1
      if (succeeded) member[`${prefix}Used`] += 1
    }
  }
  async function finish(memberId, key, workerToken, result, errorCode = null, expiredOnly = false) {
    const path = paths(memberId, key)
    const now = clock()
    return store.runTransaction(async (tx) => {
      const member = requireMember(await tx.get(path.member))
      const job = await tx.get(path.job)
      if (!job) throw new MembershipError('generation_not_found', 404)
      if (job.state !== 'processing') return job
      if (job.workerToken !== workerToken) throw new MembershipError('generation_worker_mismatch', 409)
      if (expiredOnly && now < job.leaseUntil) return job
      // Once an uncertain/crashed attempt times out it is terminal. No worker
      // takeover repeats the upstream request under this idempotency key.
      if (now >= job.leaseUntil) { result = null; errorCode = 'generation_interrupted' }
      const day = job.funding.kind === 'daily' ? await tx.get(job.funding.dayPath) : null
      updateFunding(tx, member, job, day, Boolean(result))
      const completed = { ...job, state: result ? 'succeeded' : 'failed', completedAt: now,
        error: result ? null : (errorCode || 'generation_failed'),
        resultExpiresAt: result ? now + policy.resultRetentionMs : null }
      if (result) tx.set(path.result, { pcm: result.pcm, sampleRate: result.sampleRate, emotions: result.emotions,
        expiresAt: new Date(completed.resultExpiresAt) })
      tx.set(path.member, member)
      tx.set(path.job, completed)
      return completed
    })
  }
  async function readOutcome(memberId, key, replayed = true) {
    const path = paths(memberId, key)
    let job = await store.runTransaction(async (tx) => {
      requireMember(await tx.get(path.member))
      return tx.get(path.job)
    })
    if (!job) throw new MembershipError('generation_not_found', 404)
    if (job.state === 'processing' && clock() >= job.leaseUntil) {
      job = await finish(memberId, key, job.workerToken, null, 'generation_interrupted', true)
    }
    if (job.state === 'processing') return { status: 'processing', retryAfterMs: 1500 }
    if (job.state === 'failed') throw new MembershipError(job.error,
      job.error === 'rejected' ? 422 : job.error === 'daily_upstream_limit_reached' ? 503 : 502)
    if (clock() >= job.resultExpiresAt) throw new MembershipError('generation_result_expired', 410)
    const result = await store.get(path.result)
    if (!result) throw new MembershipError('generation_result_expired', 410)
    return { status: 'succeeded', pcm: Buffer.from(result.pcm), sampleRate: result.sampleRate,
      emotions: result.emotions, replayed }
  }
  function normalizeResult(raw) {
    const result = Buffer.isBuffer(raw) ? { pcm: raw, sampleRate: 24_000, emotions: [] } : raw
    if (!result || !Buffer.isBuffer(result.pcm) || result.pcm.length === 0 ||
        result.pcm.length > policy.maximumResultBytes || result.pcm.length % 2 !== 0 ||
        result.sampleRate !== 24_000 || !Array.isArray(result.emotions) || result.emotions.length > 8 ||
        result.emotions.some((e) => typeof e !== 'string' || e.length > 40)) {
      throw new MembershipError('invalid_generation_result', 502)
    }
    return { pcm: result.pcm, sampleRate: result.sampleRate, emotions: result.emotions }
  }
  async function execute({ memberId, requestId, input }) {
    await recoverAbandoned(memberId)
    const reserved = await reserve(memberId, requestId, input)
    if (!reserved.owned) return readOutcome(memberId, reserved.key)
    let result
    try {
      result = normalizeResult(await generate(input))
    } catch (error) {
      // A failure produced no durable usable result. Release the *same* funding
      // source, including an ad credit. The failed request itself never reruns.
      const code = error?.code === 'daily_upstream_limit_reached' ? 'daily_upstream_limit_reached'
        : error?.status === 422 ? 'rejected' : 'generation_failed'
      await finish(memberId, reserved.key, reserved.workerToken, null, code)
      throw new MembershipError(code, code === 'rejected' ? 422 : code === 'daily_upstream_limit_reached' ? 503 : 502)
    }
    // Result persistence and debit are the SAME Firestore transaction. An
    // uncertain commit is retried by reading the record, never by synthesizing.
    try {
      await finish(memberId, reserved.key, reserved.workerToken, result)
    } catch (error) {
      if (error instanceof MembershipError) throw error
      return { status: 'uncertain', retryAfterMs: 1500 }
    }
    return readOutcome(memberId, reserved.key, false)
  }
  async function recoverAbandoned(memberId) {
    const jobs = await store.list(`${membership.memberPath(memberId)}/generations`, {
      where: [{ field: 'state', op: '==', value: 'processing' }], limit: 100
    })
    for (const row of jobs) {
      if (clock() >= row.data.leaseUntil) {
        await finish(memberId, row.id, row.data.workerToken, null, 'generation_interrupted', true)
      }
    }
  }
  return { execute, recoverAbandoned, getResult: ({ memberId, requestId }) => readOutcome(memberId, keyFor(requestId)),
    // Exposed for deterministic recovery tests and maintenance workers; this
    // does not allow a client to release another worker's reservation.
    recoverExpired: async ({ memberId, requestId }) => readOutcome(memberId, keyFor(requestId)) }
}

module.exports = { createGenerationService, canonicalJSON }
