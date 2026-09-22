'use strict'

const { createHmac, randomUUID } = require('node:crypto')
const { validTimeZone, quotaWindow } = require('./policy')
const { purgeDeletedMemberData } = require('./maintenance')

class MembershipError extends Error {
  constructor(code, status = 400, detail = undefined) {
    super(code); this.code = code; this.status = status; this.statusCode = status; this.detail = detail
  }
}
const fail = (code, status, detail) => { throw new MembershipError(code, status, detail) }
const stringID = (value) => typeof value === 'string' && value.length > 0 && value.length <= 256
const safeDate = (value) => Number.isFinite(value) && value >= 0
const memberPath = (id) => {
  if (!/^[a-zA-Z0-9_-]{1,100}$/.test(id)) fail('invalid_member_id', 400)
  return `members/${id}`
}
const requireMember = (member) => {
  if (!member || member.deletedAt) fail('membership_not_found', 401)
  return member
}

function deriveEntitlements(purchases, now, products) {
  let lifetimeActive = false
  let subscriptionExpiresAt = null
  let subscription = null
  for (const purchase of purchases) {
    if (purchase.revocationDate !== null && purchase.revocationDate !== undefined) continue
    if (purchase.status === 5) continue
    if (purchase.productId === products.lifetime) lifetimeActive = true
    if ([products.monthly, products.yearly].includes(purchase.productId) && purchase.status !== 2) {
      const end = purchase.status === 4 ? purchase.gracePeriodExpiresDate : purchase.expiresDate
      if (Number.isFinite(end) && end > now && (!subscription || purchase.purchaseDate > subscription.purchaseDate ||
          (purchase.purchaseDate === subscription.purchaseDate && end > subscriptionExpiresAt))) {
        subscription = purchase
        subscriptionExpiresAt = end
      }
    }
  }
  const subscriptionActive = subscriptionExpiresAt !== null
  return { removeBanner: lifetimeActive || subscriptionActive, calendar: lifetimeActive || subscriptionActive,
    temporaryClosures: subscriptionActive, dailyAI: lifetimeActive || subscriptionActive,
    lifetimeActive, subscriptionActive, subscriptionExpiresAt,
    subscriptionProductId: subscription?.productId ?? null,
    subscriptionAutoRenews: subscription && safeDate(subscription.renewalSignedAt) && [0, 1].includes(subscription.autoRenewStatus)
      ? subscription.autoRenewStatus === 1 : null,
    subscriptionRenewalProductId: subscription && safeDate(subscription.renewalSignedAt) &&
      [products.monthly, products.yearly].includes(subscription.autoRenewProductId) ? subscription.autoRenewProductId : null }
}

function createMembershipService({ store, policy, identityHashSecret, products, clock = Date.now }) {
  if (!store || !policy?.approved || typeof identityHashSecret !== 'string' || identityHashSecret.length < 32 ||
      !products || ![products.monthly, products.yearly, products.lifetime].every(stringID)) {
    throw new Error('invalid_membership_config')
  }
  const hash = (value) => createHmac('sha256', identityHashSecret).update(value).digest('hex')
  const identityHash = ({ appTransactionId, environment, bundleId }) => {
    if (!stringID(appTransactionId) || !stringID(bundleId) || !['Production', 'Sandbox', 'Xcode', 'LocalTesting'].includes(environment)) {
      fail('invalid_verified_identity', 400)
    }
    return hash(JSON.stringify(['apple-app', environment, bundleId, appTransactionId]))
  }
  const purchaseKey = (purchase) => hash(JSON.stringify(['purchase', purchase.environment, purchase.bundleId, purchase.originalTransactionId]))
  // Backfill members created before the fixed legacy welcome policy. This is
  // a server policy grant, never the number supplied in a migration claim.
  // Deleted identities have a consumed grant tombstone and are not legacy again.
  const applyLegacyWelcome = (member) => member.migrationPending && !member.legacyWelcomeGranted
    ? { ...member, freeGranted: Math.max(member.freeGranted, policy.legacyWelcomeAllowance),
      legacyWelcomeGranted: true } : member
  const windowState = (member, now) => {
    const window = quotaWindow(member, now)
    return { window, updatedMember: { ...member, dailyWindow: window, timeZone: window.timeZone,
      timeZoneActivatedAt: window.timeZone !== member.timeZone ? now : (member.timeZoneActivatedAt ?? member.createdAt),
      pendingTimeZone: member.pendingTimeZone === window.timeZone ? null : (member.pendingTimeZone ?? null) } }
  }
  async function readContext(tx, id, now = clock()) {
    const path = memberPath(id)
    const member = applyLegacyWelcome(requireMember(await tx.get(path)))
    const { window, updatedMember } = windowState(member, now)
    const dayPath = `${path}/days/${window.id}`
    const [day, rows] = await Promise.all([tx.get(dayPath), tx.list(`${path}/purchases`)])
    return { member: updatedMember, path, window, dayPath, day: day ?? { used: 0, reserved: 0 },
      entitlements: deriveEntitlements(rows.map((r) => r.data), now, products) }
  }
  function publicState(context) {
    const { member, window, day, entitlements } = context
    return { memberId: member.id, appAccountToken: member.appAccountToken, supportCode: member.supportCode,
      environment: member.environment, verifiedAt: member.verifiedAt, subscriptionExpiresAt: entitlements.subscriptionExpiresAt,
      entitlements, quota: {
        serviceDate: window.serviceDate, dailyRemaining: entitlements.dailyAI ? Math.max(0, 1 - day.used - day.reserved) : 0,
        freeRemaining: entitlements.dailyAI ? 0 : Math.max(0, member.freeGranted - member.freeUsed - member.freeReserved),
        rewardCredits: Math.max(0, member.rewardGranted - member.rewardUsed - member.rewardReserved),
        rewardGrantCount: member.rewardGranted,
        nextResetAt: window.endsAt, timeZone: window.timeZone, pendingTimeZone: member.pendingTimeZone,
        timeZoneChangeNotBefore: member.pendingTimeZone
          ? Math.max(window.endsAt, member.timeZoneActivatedAt + 24 * 60 * 60_000) : null,
        reserved: day.reserved + member.freeReserved + member.rewardReserved,
        migrationPending: member.migrationPending
      }, policy: { version: policy.version, approved: policy.approved } }
  }
  async function status(id) {
    return store.runTransaction(async (tx) => {
      const context = await readContext(tx, id)
      tx.set(context.path, context.member)
      return publicState(context)
    })
  }
  async function recognizeMember(identity) {
    const key = identityHash(identity)
    const zone = validTimeZone(identity.timeZone || 'UTC')
    const now = clock()
    const id = randomUUID()
    const accountToken = randomUUID()
    const resolved = await store.runTransaction(async (tx) => {
      const identityPath = `identities/${key}`
      const existing = await tx.get(identityPath)
      if (existing?.memberId) {
        const member = applyLegacyWelcome(requireMember(await tx.get(memberPath(existing.memberId))))
        const { window, updatedMember } = windowState(member, now)
        tx.set(memberPath(member.id), { ...updatedMember,
          pendingTimeZone: zone === window.timeZone ? null : zone })
        return member.id
      }
      const restoredGuard = existing?.quotaGuard
      const legacy = !existing?.freeGrantConsumed && (!safeDate(identity.originalPurchaseDate) ||
        identity.originalPurchaseDate < policy.migrationCutoverAt)
      const member = { id, appAccountToken: accountToken, supportCode: id.slice(0, 8).toUpperCase(),
        identityHash: key, environment: identity.environment, bundleId: identity.bundleId,
        createdAt: now, verifiedAt: now, timeZone: zone, timeZoneActivatedAt: now, pendingTimeZone: null,
        freeGranted: existing?.freeGrantConsumed ? 0 : legacy ? policy.legacyWelcomeAllowance : policy.initialFreeAllowance,
        legacyWelcomeGranted: legacy,
        freeUsed: 0, freeReserved: 0, rewardGranted: 0, rewardUsed: 0, rewardReserved: 0,
        migrationPending: legacy, legacyMigration: null, deletedAt: null }
      member.dailyWindow = restoredGuard && restoredGuard.window.endsAt > now
        ? restoredGuard.window : quotaWindow(member, now)
      tx.set(identityPath, { memberId: id, freeGrantConsumed: true })
      tx.set(memberPath(id), member)
      if (restoredGuard && restoredGuard.window.endsAt > now) {
        tx.set(`${memberPath(id)}/days/${member.dailyWindow.id}`, { used: restoredGuard.used, reserved: 0 })
      }
      return id
    })
    return status(resolved)
  }
  async function setTimeZone(id, timeZone) {
    const zone = validTimeZone(timeZone)
    await store.runTransaction(async (tx) => {
      const context = await readContext(tx, id)
      tx.set(context.path, { ...context.member, pendingTimeZone: zone === context.window.timeZone ? null : zone })
    })
    return status(id)
  }
  function normalizePurchase(raw) {
    for (const field of ['transactionId', 'originalTransactionId', 'productId', 'environment', 'bundleId']) {
      if (!stringID(raw[field])) fail('invalid_verified_purchase', 400)
    }
    if (!Object.values(products).includes(raw.productId)) fail('unknown_product', 400)
    if (!safeDate(raw.purchaseDate) || !safeDate(raw.signedDate)) fail('invalid_purchase_dates', 400)
    for (const field of ['expiresDate', 'revocationDate', 'gracePeriodExpiresDate', 'statusVerifiedAt', 'renewalSignedAt']) {
      if (raw[field] !== undefined && raw[field] !== null && !safeDate(raw[field])) fail('invalid_purchase_dates', 400)
    }
    return Object.fromEntries(['transactionId', 'originalTransactionId', 'productId', 'environment', 'bundleId',
      'purchaseDate', 'expiresDate', 'revocationDate', 'signedDate', 'appAccountToken', 'appTransactionId',
      'status', 'statusVerifiedAt', 'gracePeriodExpiresDate', 'autoRenewStatus', 'autoRenewProductId',
      'renewalSignedAt'].map((key) => [key, raw[key] ?? null]))
  }
  function assertPurchaseOwner(member, purchase, owner) {
    if (purchase.environment !== member.environment || purchase.bundleId !== member.bundleId) fail('purchase_app_mismatch', 403)
    const verifiedIdentityMatches = purchase.appTransactionId && identityHash(purchase) === member.identityHash
    const tokenMatches = purchase.appAccountToken && purchase.appAccountToken.toLowerCase() === member.appAccountToken.toLowerCase()
    if (purchase.appTransactionId && !verifiedIdentityMatches) fail('purchase_identity_mismatch', 403)
    if (!verifiedIdentityMatches && !tokenMatches) fail('purchase_identity_required', 403)
    if (owner && owner.identityHash !== member.identityHash) fail('purchase_already_linked', 409)
  }
  function newerPurchase(candidate, prior) {
    if (!prior) return true
    if (candidate.purchaseDate !== prior.purchaseDate) return candidate.purchaseDate > prior.purchaseDate
    if (candidate.signedDate !== prior.signedDate) return candidate.signedDate > prior.signedDate
    // Same-time refund/revocation wins over the original active payload.
    return candidate.revocationDate !== null && prior.revocationDate === null
  }
  function mergePurchase(candidate, prior) {
    if (!prior) return candidate
    const newest = newerPurchase(candidate, prior) ? candidate : prior
    const merged = { ...newest }
    // Apple status and renewal preference are independently verified. Re-signing
    // a transaction must neither erase that evidence nor revive an old status.
    // A refund for a previous period must not revoke the current transaction.
    if (candidate.transactionId === prior.transactionId) {
      const statusTime = (purchase) => purchase.status === null || purchase.status === undefined ? -1
        : (purchase.statusVerifiedAt ?? purchase.signedDate)
      const statusSource = statusTime(candidate) > statusTime(prior) ? candidate : prior
      for (const field of ['status', 'statusVerifiedAt', 'gracePeriodExpiresDate']) merged[field] = statusSource[field] ?? null
    }
    // Renewal preferences belong to the subscription chain, not one billing
    // transaction. Stale or missing renewal data cannot overwrite newer proof.
    const renewalSource = (candidate.renewalSignedAt ?? -1) > (prior.renewalSignedAt ?? -1) ? candidate : prior
    for (const field of ['autoRenewStatus', 'autoRenewProductId', 'renewalSignedAt']) merged[field] = renewalSource[field] ?? null
    return merged
  }
  async function ingestPurchases(id, raws, notificationId = null) {
    const purchases = raws.map(normalizePurchase)
    if (purchases.length > 100) fail('too_many_transactions', 400)
    const now = clock()
    return store.runTransaction(async (tx) => {
      const path = memberPath(id)
      const member = requireMember(await tx.get(path))
      const eventPath = notificationId ? `notifications/${hash(`apple:${notificationId}`)}` : null
      const previousEvent = eventPath ? await tx.get(eventPath) : null
      if (previousEvent) return { duplicate: true }
      const reads = await Promise.all(purchases.map(async (purchase) => {
        const key = purchaseKey(purchase)
        const [owner, prior] = await Promise.all([tx.get(`purchaseOwners/${key}`), tx.get(`${path}/purchases/${key}`)])
        assertPurchaseOwner(member, purchase, owner)
        return { purchase, key, prior }
      }))
      // Grouping avoids an older payload later in one reconciliation overwriting
      // the newer payload earlier in that same batch.
      const latest = new Map()
      for (const row of reads) {
        const prior = latest.get(row.key)?.purchase ?? row.prior
        latest.set(row.key, { ...row, purchase: mergePurchase(row.purchase, prior) })
      }
      for (const { key, purchase } of latest.values()) {
        tx.set(`${path}/purchases/${key}`, purchase)
        tx.set(`purchaseOwners/${key}`, { memberId: id, identityHash: member.identityHash })
      }
      tx.set(path, { ...member, verifiedAt: now })
      if (eventPath) tx.set(eventPath, { memberId: id, appliedAt: now })
      return { duplicate: false }
    })
  }
  async function applyVerifiedPurchase(id, purchase) {
    await ingestPurchases(id, [purchase])
    return status(id)
  }
  async function reconcileVerifiedPurchases(id, purchases) {
    // Apple history can be arbitrarily long. Each page/batch retains latest
    // chain state monotonically; a partial outage never invents revocations.
    for (let index = 0; index < purchases.length; index += 100) {
      await ingestPurchases(id, purchases.slice(index, index + 100))
    }
    if (purchases.length === 0) await ingestPurchases(id, [])
    return status(id)
  }
  async function applyVerifiedNotification({ notificationId, memberId: id, purchase: raw }) {
    if (!stringID(notificationId)) fail('invalid_notification_id', 400)
    const purchase = normalizePurchase(raw)
    if (!id) {
      const owner = await store.get(`purchaseOwners/${purchaseKey(purchase)}`)
      id = owner?.memberId
      if (!id && purchase.appTransactionId) id = (await store.get(`identities/${identityHash(purchase)}`))?.memberId
    }
    if (!id) return { applied: false, reason: 'member_not_linked' }
    const result = await ingestPurchases(id, [purchase], notificationId)
    return { applied: true, ...result }
  }
  async function creditVerifiedReward({ provider, eventId, proofId, memberId: id }) {
    if (provider !== 'levelplay' || !stringID(eventId) || !/^[a-f0-9]{64}$/.test(proofId || '')) {
      fail('invalid_verified_reward', 400)
    }
    const eventPath = `rewardEvents/${hash(`${provider}:${eventId}`)}`
    const proofPath = `rewardProofs/${hash(`${provider}:${proofId}`)}`
    return store.runTransaction(async (tx) => {
      const member = requireMember(await tx.get(memberPath(id)))
      const [previousEvent, previousProof] = await Promise.all([tx.get(eventPath), tx.get(proofPath)])
      if (previousEvent || previousProof) {
        if ([previousEvent, previousProof].some((previous) => previous && previous.identityHash !== member.identityHash)) {
          fail('reward_already_linked', 409)
        }
        return { credited: false, duplicate: true }
      }
      // LevelPlay concatenates signature fields without separators. Keep BOTH
      // event ID and authenticated payload deduplication so shifting a numeric
      // prefix between timestamp and event ID cannot create another reward.
      tx.set(proofPath, { identityHash: member.identityHash, receivedAt: clock() })
      // Platform amount is deliberately not a credit multiplier: one verified
      // completed impression is exactly one generation.
      tx.set(eventPath, { identityHash: member.identityHash, receivedAt: clock() })
      tx.set(memberPath(id), { ...member, rewardGranted: member.rewardGranted + 1 })
      return { credited: true, duplicate: false }
    })
  }
  async function quarantineLegacyMigration(id, { migrationId, claimedFreeRemaining, claimedRewardCredits }) {
    if (!stringID(migrationId) || ![claimedFreeRemaining, claimedRewardCredits].every((v) => Number.isInteger(v) && v >= 0 && v <= 100_000)) {
      fail('invalid_migration_claim', 400)
    }
    return store.runTransaction(async (tx) => {
      const member = requireMember(await tx.get(memberPath(id)))
      if (member.legacyMigration) return { accepted: false, state: member.legacyMigration.state }
      if (!member.migrationPending) return { accepted: false, state: 'not_required' }
      tx.set(memberPath(id), { ...member, legacyMigration: { state: 'quarantined', migrationId: hash(migrationId),
        claimedFreeRemaining, claimedRewardCredits, receivedAt: clock() } })
      return { accepted: true, state: 'quarantined' }
    })
  }
  async function deleteMember(id) {
    const now = clock()
    if ((await store.get(memberPath(id)))?.deletedAt) {
      await purgeDeletedMember(id)
      return { deleted: true, subscriptionCancelled: false }
    }
    await store.runTransaction(async (tx) => {
      const context = await readContext(tx, id, now)
      const purchases = await tx.list(`${context.path}/purchases`)
      // Non-reversible keyed digest + consumed-quota guard prevents deleting and
      // immediately recreating an account to obtain another daily/free grant.
      tx.set(`identities/${context.member.identityHash}`, { freeGrantConsumed: true, deletedAt: now,
        quotaGuard: { window: context.window, used: context.day.used + context.day.reserved } })
      tx.set(context.path, { id, deletedAt: now, deletionCleanupState: 'pending' })
      for (const row of purchases) tx.set(`purchaseOwners/${row.id}`, { identityHash: context.member.identityHash })
    })
    // Marking deleted first prevents concurrent auth/generation writes. Repeating
    // cleanup after interruption is safe; callers can use purgeDeletedMember.
    await purgeDeletedMember(id)
    return { deleted: true, subscriptionCancelled: false }
  }
  async function purgeDeletedMember(id) {
    memberPath(id)
    try { return await purgeDeletedMemberData({ store, memberId: id }) }
    catch (error) {
      if (error.code === 'member_not_deleted') fail('member_not_deleted', 409)
      throw error
    }
  }
  return { store, policy, products, clock, hash, memberPath, readContext, publicState, identityHash,
    recognizeMember, status, setTimeZone, applyVerifiedPurchase, reconcileVerifiedPurchases,
    applyVerifiedNotification, creditVerifiedReward, quarantineLegacyMigration, deleteMember, purgeDeletedMember }
}

module.exports = { createMembershipService, deriveEntitlements, MembershipError, requireMember, memberPath }
