'use strict'

// Daily/free rules were approved on 2026-09-16; on 2026-09-21 the owner
// approved one fixed welcome generation for legacy members. Client-only
// balances remain unverified claims and cannot increase the grant.
const APPROVED_POLICY = Object.freeze({
  version: '2026-09-21-legacy-welcome-one-v3',
  approved: true,
  dailyReset: 'member_local_midnight',
  rollover: false,
  overlappingPurchases: 'shared_one',
  debit: 'durable_server_result',
  expiration: 'preserve_existing_alarms_then_basic_replan',
  dailyAllowance: 1,
  initialFreeAllowance: 1,
  legacyWelcomeAllowance: 1,
  generationLeaseMs: 5 * 60_000,
  resultRetentionMs: 24 * 60 * 60_000,
  maximumResultBytes: 480_000
})

function createPolicy(overrides = {}) {
  const policy = { ...APPROVED_POLICY, ...overrides }
  if (policy.approved !== true || policy.dailyReset !== 'member_local_midnight' || policy.rollover !== false ||
      policy.overlappingPurchases !== 'shared_one' || policy.debit !== 'durable_server_result' ||
      policy.expiration !== 'preserve_existing_alarms_then_basic_replan' || policy.dailyAllowance !== 1 ||
      policy.initialFreeAllowance !== 1 || policy.legacyWelcomeAllowance !== 1) throw new Error('unsupported_or_unapproved_membership_policy')
  if (!Number.isFinite(policy.migrationCutoverAt)) throw new Error('migration_cutover_required')
  return Object.freeze(policy)
}

function validTimeZone(value) {
  if (typeof value !== 'string' || value.length > 100) throw new Error('invalid_time_zone')
  try { return new Intl.DateTimeFormat('en', { timeZone: value }).resolvedOptions().timeZone } catch {
    throw new Error('invalid_time_zone')
  }
}

function serviceDate(at, timeZone) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
    .formatToParts(new Date(at))
  return ['year', 'month', 'day'].map((type) => parts.find((p) => p.type === type).value).join('-')
}

// Uses real zone transitions (including DST) rather than adding a fixed 24h.
function nextMidnight(at, timeZone) {
  const today = serviceDate(at, timeZone)
  let low = Math.floor(at)
  let high = low + 30 * 60 * 60_000
  while (high - low > 1) {
    const mid = Math.floor((low + high) / 2)
    if (serviceDate(mid, timeZone) === today) low = mid
    else high = mid
  }
  return high
}

function quotaWindow(member, now) {
  if (member.dailyWindow && now < member.dailyWindow.endsAt) return member.dailyWindow
  const zoneChangeAllowed = now >= (member.timeZoneActivatedAt ?? member.createdAt) + 24 * 60 * 60_000
  const timeZone = zoneChangeAllowed ? (member.pendingTimeZone || member.timeZone) : member.timeZone
  // A timezone change is deferred to the already promised boundary. Devices
  // share this stored window; their own dates cannot select different buckets.
  const startsAt = member.dailyWindow?.endsAt ?? now
  return { id: String(startsAt), startsAt, endsAt: nextMidnight(now, timeZone), timeZone,
    serviceDate: serviceDate(now, timeZone) }
}

module.exports = { APPROVED_POLICY, createPolicy, validTimeZone, serviceDate, nextMidnight, quotaWindow }
