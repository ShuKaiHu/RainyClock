'use strict'

const { createHash, timingSafeEqual } = require('node:crypto')
const { readFileSync } = require('node:fs')
const { SignedDataVerifier, AppStoreServerAPIClient, Environment, GetTransactionHistoryVersion, VerificationStatus } =
  require('@apple/app-store-server-library')

const uuidPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
const idPattern = /^[A-Za-z0-9._-]{1,128}$/
function fail(code, status = 401) { const error = new Error(code); error.code = code; error.statusCode = status; throw error }
function requiredString(value, code, pattern = idPattern) {
  if (typeof value !== 'string' || !pattern.test(value)) fail(code)
  return value
}

// Device verification is additional binding, NOT a password or standalone proof.
// Its inputs must arrive inside the App Attest-bound bootstrap request.
function verifyDeviceBinding(payload, deviceVerificationID) {
  requiredString(deviceVerificationID, 'device_verification_missing', uuidPattern)
  requiredString(payload.deviceVerificationNonce, 'device_verification_missing', uuidPattern)
  const actual = Buffer.from(payload.deviceVerification || '', 'base64')
  const expected = createHash('sha384')
    .update(payload.deviceVerificationNonce.toLowerCase() + deviceVerificationID.toLowerCase(), 'ascii').digest()
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) fail('device_verification_failed')
}

function createAppleVerifier({ environment, bundleId, appAppleId, rootCertificates, products,
  apiClient, enableOnlineChecks = true, now = Date.now, bootstrapFreshnessMs = 5 * 60_000 }) {
  // Apple's library intentionally skips cryptography for Xcode/LocalTesting.
  // Never permit those modes on a network-facing membership service.
  if (![Environment.PRODUCTION, Environment.SANDBOX].includes(environment)) fail('apple_environment_not_allowed', 503)
  if (!bundleId || !rootCertificates?.length || !Object.keys(products || {}).length ||
      (environment === Environment.PRODUCTION && (!Number.isSafeInteger(appAppleId) || !enableOnlineChecks))) {
    fail('apple_verifier_not_configured', 503)
  }
  const verifier = new SignedDataVerifier(rootCertificates, enableOnlineChecks, environment, bundleId, appAppleId)
  const run = async (method, input) => {
    if (typeof input !== 'string' || input.length > 64_000 || input.split('.').length !== 3) fail('invalid_apple_proof')
    try { return await verifier[method](input) } catch (error) {
      if (error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) fail('apple_verification_unavailable', 503)
      fail('invalid_apple_proof')
    }
  }
  function normalizeTransaction(data) {
    requiredString(data.transactionId, 'invalid_transaction')
    requiredString(data.originalTransactionId, 'invalid_transaction')
    if (!Object.hasOwn(products, data.productId)) fail('unknown_product')
    if (!Number.isFinite(data.signedDate) || data.signedDate > now() + 60_000 ||
        !Number.isFinite(data.purchaseDate)) fail('invalid_transaction_date')
    if (data.expiresDate !== undefined && !Number.isFinite(data.expiresDate)) fail('invalid_transaction_date')
    const expectedType = products[data.productId] === 'lifetime' || products[data.productId]?.type === 'lifetime'
      ? 'Non-Consumable' : 'Auto-Renewable Subscription'
    if (data.type !== expectedType) fail('unexpected_product_type')
    if (data.inAppOwnershipType === 'FAMILY_SHARED') fail('family_sharing_not_configured')
    return {
      environment, bundleId: data.bundleId, appTransactionId: data.appTransactionId || null,
      transactionId: data.transactionId, originalTransactionId: data.originalTransactionId,
      productId: data.productId, purchaseDate: data.purchaseDate, signedDate: data.signedDate,
      expiresDate: data.expiresDate ?? null, revocationDate: data.revocationDate ?? null,
      appAccountToken: data.appAccountToken || null, type: data.type,
      inAppOwnershipType: data.inAppOwnershipType || 'PURCHASED',
      subscriptionGroupIdentifier: data.subscriptionGroupIdentifier || null
    }
  }
  const verifyTransaction = async (jws) => normalizeTransaction(await run('verifyAndDecodeTransaction', jws))
  function applyRenewal(transaction, renewal) {
    if (!transaction || !renewal) return
    if (renewal.originalTransactionId !== transaction.originalTransactionId) fail('renewal_transaction_mismatch')
    if (!Number.isFinite(renewal.signedDate) || renewal.signedDate < 0 || renewal.signedDate > now() + 60_000) {
      fail('invalid_renewal_date')
    }
    // Renewal preference has its own signed timestamp; a transaction can be
    // re-signed without changing the user's subsequently verified preference.
    transaction.renewalSignedAt = renewal.signedDate
    transaction.autoRenewStatus = [0, 1].includes(renewal.autoRenewStatus) ? renewal.autoRenewStatus : null
    const renewalType = products[renewal.autoRenewProductId]?.type ?? products[renewal.autoRenewProductId]
    transaction.autoRenewProductId = ['monthly', 'yearly'].includes(renewalType) ? renewal.autoRenewProductId : null
    transaction.gracePeriodExpiresDate = renewal.gracePeriodExpiresDate ?? null
  }
  async function verifyAppTransaction(jws, deviceVerificationID) {
    const data = await run('verifyAndDecodeAppTransaction', jws)
    requiredString(data.appTransactionId, 'app_transaction_id_unavailable')
    if (!Number.isFinite(data.receiptCreationDate) || data.receiptCreationDate > now() + 60_000 ||
        data.receiptCreationDate < now() - bootstrapFreshnessMs) fail('app_transaction_refresh_required')
    verifyDeviceBinding(data, deviceVerificationID)
    // Fingerprint verified claims, not compact JWS bytes: ECDSA permits a
    // mathematically equivalent signature representation for the same payload.
    const proofId = createHash('sha256').update(JSON.stringify([environment, data.bundleId,
      data.appTransactionId, data.receiptCreationDate, data.deviceVerificationNonce.toLowerCase(),
      Buffer.from(data.deviceVerification, 'base64').toString('hex')])).digest('hex')
    return { environment, appTransactionId: data.appTransactionId, bundleId: data.bundleId,
      signedDate: data.receiptCreationDate, originalPurchaseDate: data.originalPurchaseDate ?? null, proofId }
  }
  async function verifyNotification(jws) {
    const event = await run('verifyAndDecodeNotification', jws)
    requiredString(event.notificationUUID, 'invalid_notification_id')
    if (!Number.isFinite(event.signedDate) || event.signedDate > now() + 60_000) fail('invalid_notification_date')
    const data = event.data || {}
    const transaction = data.signedTransactionInfo ? await verifyTransaction(data.signedTransactionInfo) : null
    const renewal = data.signedRenewalInfo ? await run('verifyAndDecodeRenewalInfo', data.signedRenewalInfo) : null
    if (renewal && transaction && renewal.originalTransactionId !== transaction.originalTransactionId) {
      fail('notification_transaction_mismatch')
    }
    applyRenewal(transaction, renewal)
    if (transaction && data.status !== undefined) {
      transaction.status = data.status
      transaction.statusVerifiedAt = event.signedDate
      transaction.gracePeriodExpiresDate = renewal?.gracePeriodExpiresDate ?? null
    }
    return { environment, notificationUUID: event.notificationUUID, notificationType: event.notificationType,
      subtype: event.subtype || null, signedDate: event.signedDate, transaction, renewal,
      status: data.status ?? null }
  }
  async function reconcile(appTransactionId) {
    requiredString(appTransactionId, 'invalid_app_transaction_id')
    if (!apiClient) fail('apple_server_api_not_configured', 503)
    const transactions = new Map()
    let revision = null
    // Authoritative history includes refunded/revoked records; never filter those out.
    // App transaction IDs are supported by the V2 history endpoint.
    for (let page = 0; page < 100; page++) {
      const response = await apiClient.getTransactionHistory(appTransactionId, revision, {}, GetTransactionHistoryVersion.V2)
      if (response.environment !== environment || response.bundleId !== bundleId) fail('apple_history_mismatch')
      for (const jws of response.signedTransactions || []) {
        // Other app products can exist in the account. Skip only after Apple signature verification.
        const decoded = await run('verifyAndDecodeTransaction', jws)
        if (!Object.hasOwn(products, decoded.productId)) continue
        const tx = normalizeTransaction(decoded)
        if (tx.appTransactionId !== appTransactionId) fail('transaction_owner_mismatch')
        transactions.set(tx.transactionId, tx)
      }
      if (!response.hasMore) break
      if (!response.revision || response.revision === revision || page === 99) fail('apple_history_incomplete', 503)
      revision = response.revision
    }
    // Fetch latest status for subscription chains to capture grace/retry/revocation.
    const subscriptions = [...transactions.values()].filter((tx) => tx.type === 'Auto-Renewable Subscription')
    if (subscriptions.length) {
      const response = await apiClient.getAllSubscriptionStatuses(appTransactionId)
      if (response.environment !== environment || response.bundleId !== bundleId) fail('apple_status_mismatch')
      for (const group of response.data || []) {
        for (const last of group.lastTransactions || []) {
          const tx = await verifyTransaction(last.signedTransactionInfo)
          if (tx.appTransactionId !== appTransactionId) fail('transaction_owner_mismatch')
          const renewal = last.signedRenewalInfo ? await run('verifyAndDecodeRenewalInfo', last.signedRenewalInfo) : null
          applyRenewal(tx, renewal)
          tx.status = last.status
          tx.statusVerifiedAt = now()
          tx.gracePeriodExpiresDate = renewal?.gracePeriodExpiresDate ?? null
          if (last.status === 5 && !tx.revocationDate) tx.revocationDate = now()
          transactions.set(tx.transactionId, tx)
        }
      }
    }
    return { transactions: [...transactions.values()], checkedAt: now() }
  }
  return { environment, verifyAppTransaction, verifyTransaction, verifyNotification, reconcile }
}

function createAppleVerifierFromEnv(env = process.env, products) {
  const roots = (env.MEMBERSHIP_APPLE_ROOT_CERTIFICATES || '').split(',').filter(Boolean).map((path) => readFileSync(path.trim()))
  const environment = env.MEMBERSHIP_APPLE_ENVIRONMENT
  let apiClient
  if (env.MEMBERSHIP_APPLE_KEY_PATH && env.MEMBERSHIP_APPLE_KEY_ID && env.MEMBERSHIP_APPLE_ISSUER_ID) {
    apiClient = new AppStoreServerAPIClient(readFileSync(env.MEMBERSHIP_APPLE_KEY_PATH, 'utf8'),
      env.MEMBERSHIP_APPLE_KEY_ID, env.MEMBERSHIP_APPLE_ISSUER_ID, env.MEMBERSHIP_BUNDLE_ID, environment)
  }
  return createAppleVerifier({ environment, bundleId: env.MEMBERSHIP_BUNDLE_ID,
    appAppleId: env.MEMBERSHIP_APPLE_APP_ID ? Number(env.MEMBERSHIP_APPLE_APP_ID) : undefined,
    rootCertificates: roots, products, apiClient })
}

module.exports = { createAppleVerifier, createAppleVerifierFromEnv, verifyDeviceBinding }
