import { pathToFileURL } from 'node:url';
import { ServiceError } from './errors.js';
import { firestoreConfiguration, createStoreFromEnv, integerSetting } from './runtime.js';
import { createSnapshotReader } from './snapshot.js';
import { DeviceRegistry } from './devices.js';
import { createHTTPServer } from './http.js';

// Cloud Run service: answers phones from the document the Job wrote and holds
// nothing else. No poller, no NCDR key, no APNs key, no disk and no timer
// beyond the shutdown deadline, so an instance can be started, scaled out or
// killed at any moment without a phone noticing.
const PUSH_MODES = ['alert', 'background'];
// Cloud Run allows ten seconds after SIGTERM; in-flight requests get most of it.
const SHUTDOWN_DEADLINE_MS = 8000;

const log = (event) => process.stdout.write(JSON.stringify({ severity: 'INFO', at: new Date().toISOString(), ...event }) + '\n');

function flag(env, name) {
  const value = env[name]?.trim() ?? '';
  if (!['', '0', '1'].includes(value)) throw new ServiceError('invalid_configuration');
  return value === '1';
}

// Pure: nothing here touches the store or the network. pushConfigured comes
// from the environment rather than from holding a dispatcher, because this
// process never has one and the phones still need the push_not_configured
// gate and the /health fields to say what the Job is set up to do.
export function serviceConfig(env = process.env) {
  const pushConfigured = flag(env, 'PUSH_CONFIGURED');
  const pushMode = env.APNS_PUSH_MODE?.trim() || 'alert';
  if (!PUSH_MODES.includes(pushMode)) throw new ServiceError('invalid_configuration');
  return {
    port: integerSetting(env, 'PORT', 8080, 1, 65535),
    host: env.HOST?.trim() || '0.0.0.0',
    maxCacheAgeMs: integerSetting(env, 'MAX_CACHE_AGE_MS', 900_000, 60_000, 86_400_000),
    cacheMs: integerSetting(env, 'SNAPSHOT_CACHE_MS', 5000, 0, 60_000),
    pushConfigured,
    pushMode: pushConfigured ? pushMode : null,
    trustForwardedFor: flag(env, 'TRUST_PROXY'),
    firestore: firestoreConfiguration(env)
  };
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => { server.removeListener('error', reject); resolve(); });
  });
}

async function main() {
  const config = serviceConfig(process.env);
  const { store, close } = createStoreFromEnv(process.env);
  const service = createSnapshotReader({ store, maxCacheAgeMs: config.maxCacheAgeMs, cacheMs: config.cacheMs });
  const registry = new DeviceRegistry({ store });
  const server = createHTTPServer({ service, registry, pushConfigured: config.pushConfigured, pushMode: config.pushMode, trustForwardedFor: config.trustForwardedFor });
  await listen(server, config.port, config.host);
  log({ event: 'listening', port: config.port, pushConfigured: config.pushConfigured, pushMode: config.pushMode, trustForwardedFor: config.trustForwardedFor, database: config.firestore.databaseId, namespace: config.firestore.namespace });
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    const deadline = setTimeout(() => process.exit(0), SHUTDOWN_DEADLINE_MS);
    deadline.unref();
    server.close(() => { close().catch(() => {}).finally(() => process.exit(0)); });
    server.closeIdleConnections();
  };
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    // A code only: configuration values and listen errors can name hosts and paths.
    const code = error instanceof ServiceError ? error.code : error?.syscall === 'listen' ? 'listen_failed' : 'internal_error';
    log({ severity: 'ERROR', event: 'startup_failed', code });
    process.exitCode = 1;
  });
}
