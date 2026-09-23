import { pathToFileURL } from 'node:url';
import { ServiceError } from './errors.js';
import { createMemoryStore } from './store.js';
import { createStoreFromEnv, integerSetting } from './runtime.js';
import { apnsConfiguration, createDispatcher } from './job.js';
import { SuspensionService } from './service.js';
import { DeviceRegistry, RevisionBroadcaster } from './devices.js';
import { createSnapshotReader } from './snapshot.js';
import { createHTTPServer } from './http.js';

// Laptop only: the Job's poller, the broadcaster and the request-only reader
// in one resident process, so the whole flow can be watched without a
// project. State lives in memory unless FIRESTORE_EMULATOR_HOST is set, and
// the emulator client is the only Firestore client this file ever builds, so
// a production database is out of reach by construction. Never deployed: the
// Dockerfile CMD and the Job run the other two entrypoints.
const log = (event) => process.stdout.write(JSON.stringify({ severity: 'INFO', at: new Date().toISOString(), ...event }) + '\n');

export function localConfig(env = process.env) {
  const pollIntervalMs = integerSetting(env, 'POLL_INTERVAL_MS', 300_000, 60_000, 3_600_000);
  return {
    // Without a key the poller never runs and every read is not_configured,
    // which is still a useful way to check the HTTP surface.
    apiKey: env.NCDR_API_KEY?.trim() || null,
    pollIntervalMs,
    maxCacheAgeMs: integerSetting(env, 'MAX_CACHE_AGE_MS', 900_000, pollIntervalMs, 86_400_000),
    requestTimeoutMs: integerSetting(env, 'REQUEST_TIMEOUT_MS', 10_000, 2000, 30_000),
    cacheMs: integerSetting(env, 'SNAPSHOT_CACHE_MS', 5000, 0, 60_000),
    port: integerSetting(env, 'PORT', 8080, 1, 65535),
    concurrency: integerSetting(env, 'BROADCAST_CONCURRENCY', 4, 1, 64),
    ...apnsConfiguration(env)
  };
}

export function localStore(env = process.env) {
  if (env.FIRESTORE_EMULATOR_HOST) return createStoreFromEnv(env);
  return { store: createMemoryStore(), close: async () => {} };
}

async function main() {
  const config = localConfig(process.env);
  const dispatcher = await createDispatcher(config, undefined, Date.now);
  const push = { configured: Boolean(dispatcher), mode: dispatcher ? config.pushMode : null };
  const { store, close } = localStore(process.env);
  const registry = new DeviceRegistry({ store });
  const broadcaster = new RevisionBroadcaster({ registry, dispatcher, concurrency: config.concurrency, log });
  const service = new SuspensionService({ apiKey: config.apiKey, store, pollIntervalMs: config.pollIntervalMs, maxCacheAgeMs: config.maxCacheAgeMs, requestTimeoutMs: config.requestTimeoutMs, push, onRevision: (revision) => broadcaster.enqueue(revision), log });
  await service.initialize();
  // Phones are served through the same reader the deployed service uses, so
  // what this process shows on /health/details is what production shows.
  const reader = createSnapshotReader({ store, maxCacheAgeMs: config.maxCacheAgeMs, cacheMs: config.cacheMs });
  const server = createHTTPServer({ service: reader, registry, pushConfigured: push.configured, pushMode: push.mode });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.port, '127.0.0.1', () => { server.removeListener('error', reject); resolve(); });
  });
  log({ event: 'listening', port: config.port, sourceConfigured: Boolean(config.apiKey), pushConfigured: push.configured, pushMode: push.mode, storage: store.kind });
  service.start();
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    server.close();
    server.closeIdleConnections();
    await Promise.allSettled([service.stop(), broadcaster.stop()]);
    await close().catch(() => {});
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    // Never print caught errors: fetch paths and configuration can contain secrets.
    const code = error instanceof ServiceError ? error.code : error?.syscall === 'listen' ? 'listen_failed' : 'internal_error';
    log({ severity: 'ERROR', event: 'startup_failed', code });
    process.exitCode = 1;
  });
}
