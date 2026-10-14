'use strict'

// IAM-only Cloud Run Job. No HTTP listener, Apple verifier, secret access,
// AI call, ad SDK or membership creation is initialized by this entrypoint.
const { Firestore } = require('@google-cloud/firestore')
const { createFirestoreStore } = require('./store')
const { createStoreDeletionMaintenance } = require('./maintenance')

function boundedInteger(value, fallback, maximum) {
  if (value === undefined) return fallback
  if (!/^[1-9][0-9]*$/.test(value) || Number(value) > maximum) throw new Error('invalid_maintenance_limit')
  return Number(value)
}

function maintenanceConfiguration(env) {
  const projectId = env.MEMBERSHIP_FIRESTORE_PROJECT || env.GOOGLE_CLOUD_PROJECT
  if (typeof projectId !== 'string' || !/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(projectId) ||
      (env.FIRESTORE_EMULATOR_HOST && !projectId.startsWith('demo-'))) throw new Error('unsafe_firestore_project')
  const mode = env.MEMBERSHIP_SERVER_MODE || 'sandbox'
  let targets
  if (mode === 'dual') {
    targets = [
      { environment: 'Production', databaseId: env.MEMBERSHIP_PRODUCTION_FIRESTORE_DATABASE || 'membership-production',
        namespace: env.MEMBERSHIP_PRODUCTION_NAMESPACE || 'membership_production_v1' },
      { environment: 'Sandbox', databaseId: env.MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE || 'membership-testflight',
        namespace: env.MEMBERSHIP_SANDBOX_NAMESPACE || 'membership_testflight_v1' }
    ]
    if (targets[0].databaseId === targets[1].databaseId || targets[0].namespace === targets[1].namespace) {
      throw new Error('maintenance_requires_isolated_storage')
    }
  } else if (mode === 'sandbox' && env.MEMBERSHIP_APPLE_ENVIRONMENT === 'Sandbox') {
    // The legacy development job must name its database explicitly. Never
    // silently fall back to the default production database for a deletion job.
    targets = [{ environment: 'Sandbox', databaseId: env.MEMBERSHIP_FIRESTORE_DATABASE,
      namespace: env.MEMBERSHIP_NAMESPACE || 'membership_sandbox_v1' }]
  } else throw new Error('invalid_maintenance_mode')
  for (const target of targets) {
    if (!/^[a-z][a-z0-9-]{2,61}[a-z0-9]$/.test(target.databaseId || '') ||
        !/^[a-zA-Z0-9_-]{1,100}$/.test(target.namespace || '')) throw new Error('invalid_maintenance_storage')
  }
  return { targets: targets.map((target) => ({ ...target, projectId,
    ...(env.FIRESTORE_EMULATOR_HOST ? { emulatorHost: env.FIRESTORE_EMULATOR_HOST } : {}) })),
    batchSize: boundedInteger(env.MEMBERSHIP_MAINTENANCE_BATCH_SIZE, 100, 100),
    maxBatches: boundedInteger(env.MEMBERSHIP_MAINTENANCE_MAX_BATCHES, 10, 100) }
}

function createMaintenanceTarget({ projectId, databaseId, namespace, emulatorHost }) {
  const firestore = new Firestore({ projectId, databaseId,
    ...(emulatorHost ? { host: emulatorHost, ssl: false } : {}) })
  const store = createFirestoreStore({ firestore, namespace })
  return { ...createStoreDeletionMaintenance({ store }), close: () => firestore.terminate() }
}

async function runDeletionMaintenance({ env = process.env, createTarget = createMaintenanceTarget } = {}) {
  // Validate every target before touching either database.
  const { targets, batchSize, maxBatches } = maintenanceConfiguration(env)
  const results = []
  for (const config of targets) {
    let target
    const result = { environment: config.environment, examined: 0, completed: 0, failed: 0,
      batches: 0, pendingRemaining: false, error: false }
    try {
      target = await createTarget(config)
      for (let batch = 0; batch < maxBatches; batch++) {
        const outcome = await target.cleanup({ limit: batchSize })
        result.batches++
        for (const field of ['examined', 'completed', 'failed']) result[field] += outcome[field]
        // A stuck record stays pending. Continue past partial progress, but
        // do not spin if an entire batch fails or the outbox is empty.
        if (outcome.examined === 0 || outcome.completed === 0) break
      }
      result.pendingRemaining = await target.hasPending()
    } catch {
      // Do not log raw exceptions: they can contain document paths or tokens.
      result.error = true
    } finally {
      try { await target?.close?.() } catch { result.error = true }
    }
    results.push(result)
  }
  // A successful other environment must still finish when one database fails.
  // Nonzero status makes Cloud Run retry partial cleanup, safely and visibly.
  return { ok: results.every((r) => !r.error && r.failed === 0 && !r.pendingRemaining), results }
}

async function main() {
  const summary = await runDeletionMaintenance()
  console.log(JSON.stringify({ event: 'membership_deletion_maintenance', ...summary }))
  process.exitCode = summary.ok ? 0 : 1
}

if (require.main === module) main().catch(() => {
  console.error(JSON.stringify({ event: 'membership_deletion_maintenance_failed' }))
  process.exitCode = 1
})

module.exports = { maintenanceConfiguration, createMaintenanceTarget, runDeletionMaintenance }
