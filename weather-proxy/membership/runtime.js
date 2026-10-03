'use strict'

const { Firestore } = require('@google-cloud/firestore')
const { createFirestoreStore } = require('./store')
const { createPolicy } = require('./policy')
const { createMembershipService } = require('./service')
const { createGenerationService } = require('./generation')
const { createPersistentTTSBudget } = require('./budget')
const { createAppleVerifierFromEnv } = require('./apple')
const { createAttestationVerifier } = require('./attestation')
const { createMembershipAuth } = require('./auth')
const { createLevelPlayVerifier } = require('./rewards')
const { createMembershipHandler } = require('./http')
const { cleanupDeletedMembers } = require('./maintenance')
const { PERSONA_IDS } = require('../personas')
const { annotate, splitSentences } = require('../annotate')
const { synthesize, normalizeSynthesisOptions, SAMPLE_RATE } = require('../tts')

const products = Object.freeze({ monthly: 'com.shukaihu.RainyClock.plus.monthly',
  yearly: 'com.shukaihu.RainyClock.plus.yearly', lifetime: 'com.shukaihu.RainyClock.banner.lifetime' })
function validateInput(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      Object.keys(input).some((key) => !['text', 'persona', 'language'].includes(key)) ||
      !PERSONA_IDS.includes(input.persona) || !['en', 'zh', 'zh-TW', 'zh-Hant', 'en-US'].includes(input.language) ||
      typeof input.text !== 'string' || !input.text.trim() || input.text.length > 200) {
    throw Object.assign(new Error('invalid_generation_input'), { code: 'invalid_generation_input', status: 400 })
  }
}

// ASC has one Sandbox notification URL for both Xcode device testing and
// TestFlight. Only an already verified Sandbox payload may be relayed to this
// existing, independently verifying endpoint; never follow redirects.
const LEGACY_SANDBOX_NOTIFICATION_URL = 'https://rainyclock-membership-sandbox-510427696731.asia-east1.run.app/v1/membership/apple/notifications'
function withSandboxNotificationForwarding(apple, env, fetcher = fetch) {
  const destination = env.MEMBERSHIP_SANDBOX_NOTIFICATION_FORWARD_URL
  if (!destination || env.MEMBERSHIP_APPLE_ENVIRONMENT !== 'Sandbox') return apple
  if (destination !== LEGACY_SANDBOX_NOTIFICATION_URL) throw new Error('invalid_sandbox_notification_forward_url')
  return { ...apple, async verifyNotification(signedPayload) {
    const event = await apple.verifyNotification(signedPayload)
    if (event.environment !== 'Sandbox') throw Object.assign(new Error('invalid_apple_proof'), { code: 'invalid_apple_proof', status: 401 })
    // The same event can be retried after partial success. Both receiving
    // runtimes use the existing notification UUID/transaction replay ledger.
    try {
      const response = await fetcher(destination, { method: 'POST', redirect: 'error',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ signedPayload }),
        signal: AbortSignal.timeout(10_000) })
      if (!response.ok) throw new Error('forward_failed')
      await response.body?.cancel()
    } catch {
      throw Object.assign(new Error('sandbox_notification_forward_unavailable'), {
        code: 'sandbox_notification_forward_unavailable', status: 503
      })
    }
    return event
  } }
}

function createVerifiedRewardResolver({ rewards, auth }) {
  return async (query) => {
    if (!rewards) throw Object.assign(new Error('levelplay_s2s_not_configured'), { code: 'levelplay_s2s_not_configured', status: 503 })
    // userId is a signed, fixed-width random server-issued identifier. Neither
    // custom parameters nor an environment hint may decide who gets a reward.
    const reward = rewards.verify(query)
    try { return Boolean(await auth.resolveRewardMember(reward.rewardUserId)) }
    catch (failure) {
      if (failure.code === 'unknown_reward_user') return false
      throw failure
    }
  }
}

function createMembershipRuntime(env = process.env) {
  if (env.MEMBERSHIP_ENABLED !== '1') return null
  if (env.MEMBERSHIP_APPLE_ENVIRONMENT === 'Production' && env.MEMBERSHIP_ATTEST_ENVIRONMENT === 'development') {
    throw new Error('production_requires_production_app_attest')
  }
  const projectId = env.MEMBERSHIP_FIRESTORE_PROJECT || env.GOOGLE_CLOUD_PROJECT
  if (!projectId || (env.FIRESTORE_EMULATOR_HOST && !projectId.startsWith('demo-'))) throw new Error('unsafe_firestore_project')
  const cutover = Date.parse(env.MEMBERSHIP_MIGRATION_CUTOVER || '')
  const policy = createPolicy({ migrationCutoverAt: cutover })
  // One provider call per reserved generation also makes the persistent cost
  // cap reflect actual synthesis attempts. The US endpoint avoids the global
  // routing stalls observed during runtime verification. Legacy TTS is unchanged.
  const speechOptions = normalizeSynthesisOptions({
    endpointRegion: env.MEMBERSHIP_TTS_REGION || 'us', timeoutMs: 35_000,
    maxAttempts: 1, retryNetworkErrors: false
  })
  const firestore = new Firestore({ projectId, databaseId: env.MEMBERSHIP_FIRESTORE_DATABASE || '(default)' })
  const store = createFirestoreStore({ firestore,
    namespace: env.MEMBERSHIP_NAMESPACE || `membership_${env.MEMBERSHIP_APPLE_ENVIRONMENT?.toLowerCase()}_v1` })
  const budgetDatabase = env.MEMBERSHIP_TTS_BUDGET_DATABASE || env.MEMBERSHIP_FIRESTORE_DATABASE || '(default)'
  const budgetFirestore = budgetDatabase === (env.MEMBERSHIP_FIRESTORE_DATABASE || '(default)')
    ? firestore : new Firestore({ projectId, databaseId: budgetDatabase })
  const ttsBudget = createPersistentTTSBudget({
    store: createFirestoreStore({ firestore: budgetFirestore, namespace: 'membership_tts_cost_v1' }),
    limit: Number(env.DAILY_TTS_LIMIT ?? 2_000)
  })
  const apple = withSandboxNotificationForwarding(
    createAppleVerifierFromEnv(env, Object.fromEntries(Object.entries(products).map(([type, id]) => [id, type]))), env)
  const attestationVerifier = createAttestationVerifier({ teamId: env.MEMBERSHIP_TEAM_ID,
    bundleId: env.MEMBERSHIP_BUNDLE_ID, environment: env.MEMBERSHIP_ATTEST_ENVIRONMENT || 'production' })
  const auth = createMembershipAuth({ store, appleVerifier: apple, attestationVerifier })
  const membership = createMembershipService({ store, policy, products, identityHashSecret: env.MEMBERSHIP_IDENTITY_HASH_SECRET })
  const rewards = env.MEMBERSHIP_LEVELPLAY_PRIVATE_KEY
    ? createLevelPlayVerifier({ privateKey: env.MEMBERSHIP_LEVELPLAY_PRIVATE_KEY }) : null
  const generation = createGenerationService({ membership, generate: async (input) => {
    if (env.TTS_DISABLED === '1') throw Object.assign(new Error('tts_disabled'), { code: 'tts_disabled', status: 503 })
    // This happens only for a new reserved generation, before either AI request.
    // Retry downloads never enter generate; failures never refund this cost cap.
    await ttsBudget.consume()
    const sentences = splitSentences(input.text, 8)
    const emotions = await annotate({ ...input, sentences })
    const segments = sentences.map((text, i) => ({ text, emotion: emotions[i] || 'neutral' }))
    const pcm = await synthesize({ ...input, segments, maximumSeconds: 10 }, speechOptions)
    return { pcm, sampleRate: SAMPLE_RATE, emotions }
  } })
  const handler = createMembershipHandler({ membership, auth, apple, rewards, generation, validateInput })
  handler.resolveVerifiedReward = createVerifiedRewardResolver({ rewards, auth })
  handler.maintenance = () => cleanupDeletedMembers({ membership, auth })
  return handler
}
module.exports = { products, validateInput, createMembershipRuntime, withSandboxNotificationForwarding,
  createVerifiedRewardResolver, LEGACY_SANDBOX_NOTIFICATION_URL }
