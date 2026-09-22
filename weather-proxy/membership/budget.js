'use strict'

const { MembershipError } = require('./service')

// Operational spending ceiling, independent of a member's local-day benefit.
// All replicas and both Apple environments should share the SAME store namespace.
function createPersistentTTSBudget({ store, limit = 2_000, clock = Date.now }) {
  if (!store || !Number.isSafeInteger(limit) || limit < 1 || limit > 1_000_000) {
    throw new Error('invalid_tts_budget_config')
  }
  async function consume() {
    const now = clock()
    const day = new Date(now).toISOString().slice(0, 10)
    return store.runTransaction(async (tx) => {
      const path = `costBudgets/tts_${day}`
      const previous = await tx.get(path)
      const spent = previous?.attempts ?? 0
      if (spent >= limit) throw new MembershipError('daily_upstream_limit_reached', 503)
      tx.set(path, { serviceDate: day, attempts: spent + 1, updatedAt: now,
        expiresAt: new Date(now + 90 * 24 * 60 * 60_000) })
      return { serviceDate: day, attempts: spent + 1, limit }
    })
  }
  // No refund method: an upstream error or lost response may still incur cost.
  return { consume }
}

module.exports = { createPersistentTTSBudget }
