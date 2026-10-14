'use strict'

const { createMembershipRuntime } = require('./runtime')

const ENVIRONMENT_HEADER = 'x-rc-apple-environment'
const NOTIFICATION_PATH = '/v1/membership/apple/notifications'
const REWARD_PATH = '/v1/membership/levelplay/callback'
const CALLBACK_ENVIRONMENTS = Object.freeze({ production: 'Production', sandbox: 'Sandbox' })

// This header selects an isolated verifier/store; it is never proof of payment
// or identity. Apple signatures, App Attest, and sessions remain mandatory in
// each runtime, so changing the hint cannot promote Sandbox rights.
function runtimeEnvironments(env) {
  const mode = env.MEMBERSHIP_SERVER_MODE || 'sandbox'
  if (!['sandbox', 'dual'].includes(mode)) throw new Error('invalid_membership_server_mode')
  if (mode === 'sandbox') {
    if (env.MEMBERSHIP_APPLE_ENVIRONMENT !== 'Sandbox') throw new Error('membership_server_requires_sandbox')
    return { Sandbox: { ...env } }
  }
  if (env.MEMBERSHIP_ATTEST_ENVIRONMENT && env.MEMBERSHIP_ATTEST_ENVIRONMENT !== 'production') {
    throw new Error('dual_requires_production_app_attest')
  }
  const productionSecret = env.MEMBERSHIP_PRODUCTION_IDENTITY_HASH_SECRET
  const sandboxSecret = env.MEMBERSHIP_SANDBOX_IDENTITY_HASH_SECRET
  if (typeof productionSecret !== 'string' || productionSecret.length < 32 ||
      typeof sandboxSecret !== 'string' || sandboxSecret.length < 32 || productionSecret === sandboxSecret) {
    throw new Error('membership_environments_require_distinct_identity_secrets')
  }
  const productionDB = env.MEMBERSHIP_PRODUCTION_FIRESTORE_DATABASE || 'membership-production'
  const sandboxDB = env.MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE || 'membership-testflight'
  const productionNamespace = env.MEMBERSHIP_PRODUCTION_NAMESPACE || 'membership_production_v1'
  const sandboxNamespace = env.MEMBERSHIP_SANDBOX_NAMESPACE || 'membership_testflight_v1'
  const validDatabase = (value) => /^[a-z][a-z0-9-]{2,61}[a-z0-9]$/.test(value)
  const validNamespace = (value) => /^[a-zA-Z0-9_-]{1,100}$/.test(value)
  if (!validDatabase(productionDB) || !validDatabase(sandboxDB) || productionDB === sandboxDB ||
      !validNamespace(productionNamespace) || !validNamespace(sandboxNamespace) || productionNamespace === sandboxNamespace) {
    throw new Error('membership_environments_require_isolated_storage')
  }
  const budgetDB = env.MEMBERSHIP_TTS_BUDGET_DATABASE || productionDB
  if (!validDatabase(budgetDB)) throw new Error('invalid_tts_budget_database')
  return Object.fromEntries([
    ['Production', productionDB, productionNamespace, 'PRODUCTION'],
    ['Sandbox', sandboxDB, sandboxNamespace, 'SANDBOX']
  ].map(([environment, database, namespace, prefix]) => [environment, {
    ...env,
    MEMBERSHIP_APPLE_ENVIRONMENT: environment,
    // TestFlight and App Review also use production App Attest, even though
    // their StoreKit transactions are Sandbox transactions.
    MEMBERSHIP_ATTEST_ENVIRONMENT: 'production',
    MEMBERSHIP_FIRESTORE_DATABASE: database,
    MEMBERSHIP_NAMESPACE: namespace,
    MEMBERSHIP_IDENTITY_HASH_SECRET: environment === 'Production' ? productionSecret : sandboxSecret,
    // Membership data is separate; upstream spending is shared across both.
    MEMBERSHIP_TTS_BUDGET_DATABASE: budgetDB,
    MEMBERSHIP_MIGRATION_CUTOVER: env[`MEMBERSHIP_${prefix}_MIGRATION_CUTOVER`] || env.MEMBERSHIP_MIGRATION_CUTOVER
  }]))
}

function routeMembershipRequest(req) {
  const url = new URL(req.url, 'http://localhost')
  if (url.pathname === REWARD_PATH) return { rewardQuery: url.searchParams }
  for (const path of [NOTIFICATION_PATH, REWARD_PATH]) {
    if (url.pathname === path || url.pathname.startsWith(path + '/')) {
      const suffix = url.pathname.slice(path.length + 1)
      if (!Object.hasOwn(CALLBACK_ENVIRONMENTS, suffix)) return { error: 'not_found', status: 404 }
      const environment = CALLBACK_ENVIRONMENTS[suffix]
      // Only provider callbacks have their path rewritten. Client assertions
      // bind the exact request path and raw bytes, which remain unchanged.
      return { environment, callbackURL: path + url.search,
        ...(path === REWARD_PATH ? { rewardQuery: url.searchParams, expectedEnvironment: environment } : {}) }
    }
  }
  const environment = req.headers[ENVIRONMENT_HEADER]
  if (!['Production', 'Sandbox'].includes(environment)) {
    return { error: 'invalid_apple_environment', status: 400 }
  }
  return { environment }
}

function createMembershipRouter(env, createRuntime = createMembershipRuntime) {
  const configurations = runtimeEnvironments(env)
  for (const name of ['MEMBERSHIP_APPLE_KEY_PATH', 'MEMBERSHIP_APPLE_KEY_ID', 'MEMBERSHIP_APPLE_ISSUER_ID']) {
    if (typeof env[name] !== 'string' || !env[name].trim()) throw new Error('apple_server_api_not_configured')
  }
  // Both runtimes must initialize before the server starts listening.
  const handlers = Object.fromEntries(Object.entries(configurations).map(([environment, configuration]) => {
    const handler = createRuntime(configuration)
    if (typeof handler !== 'function') throw new Error('membership_not_configured')
    return [environment, handler]
  }))
  if (env.MEMBERSHIP_SERVER_MODE !== 'dual') return handlers.Sandbox
  return async (req, res) => {
    const route = routeMembershipRequest(req)
    if (route.rewardQuery) {
      if (req.method !== 'GET') Object.assign(route, { error: 'method_not_allowed', status: 405 })
      else {
        try {
          // One LevelPlay app has one callback URL. Resolve only after each
          // runtime verifies the provider signature, and require unique ownership.
          const matches = await Promise.all(Object.entries(handlers).map(async ([environment, handler]) => {
            if (typeof handler.resolveVerifiedReward !== 'function') throw new Error('resolver_unavailable')
            return await handler.resolveVerifiedReward(route.rewardQuery) ? environment : null
          }))
          const owners = matches.filter(Boolean)
          if (owners.length !== 1) Object.assign(route, { error: owners.length ? 'ambiguous_reward_user' : 'unknown_reward_user', status: 401 })
          else if (route.expectedEnvironment && route.expectedEnvironment !== owners[0]) {
            Object.assign(route, { error: 'unknown_reward_user', status: 401 })
          } else route.environment = owners[0]
        } catch (failure) {
          const status = failure.statusCode || failure.status
          Object.assign(route, { error: status === 401 ? 'invalid_reward_callback' : 'reward_verification_unavailable',
            status: status === 401 ? 401 : 503 })
        }
      }
    }
    if (route.error) {
      const bytes = Buffer.from(JSON.stringify({ error: route.error }))
      res.writeHead(route.status, { 'Content-Type': 'application/json', 'Content-Length': bytes.length,
        'Cache-Control': 'no-store', ...(!req.complete ? { Connection: 'close' } : {}) })
      res.end(bytes)
      return true
    }
    const originalURL = req.url
    if (route.callbackURL) req.url = route.callbackURL
    try { return await handlers[route.environment](req, res) }
    finally { req.url = originalURL }
  }
}

module.exports = { ENVIRONMENT_HEADER, runtimeEnvironments, routeMembershipRequest, createMembershipRouter }
