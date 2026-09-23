import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createApnsDispatcher } from '../apns.js';
import { SuspensionService } from './service.js';
import { DeviceRegistry, RevisionBroadcaster } from './devices.js';
import { createHTTPServer } from './http.js';

const log = (event) => console.log(JSON.stringify({ at: new Date().toISOString(), ...event }));
function integer(name, fallback, min, max) {
  const value = process.env[name] ?? String(fallback);
  if (!/^\d+$/.test(value) || +value < min || +value > max) throw new Error('invalid_configuration');
  return +value;
}

async function main() {
  const dataDir = resolve(process.env.DATA_DIR || './data');
  const pollIntervalMs = integer('POLL_INTERVAL_MS', 300_000, 60_000, 3_600_000);
  const maxCacheAgeMs = integer('MAX_CACHE_AGE_MS', 900_000, pollIntervalMs, 86_400_000);
  const requestTimeoutMs = integer('REQUEST_TIMEOUT_MS', 10_000, 2000, 30_000);
  const port = integer('PORT', 8081, 1, 65535);
  const apiKey = process.env.NCDR_API_KEY?.trim();
  let dispatcher = null;
  const pushFields = ['APNS_TEAM_ID', 'APNS_KEY_ID', 'APNS_PRIVATE_KEY_PATH', 'APNS_TOPIC'];
  const pushValues = pushFields.map((name) => process.env[name]?.trim());
  if (pushValues.some(Boolean) && !pushValues.every(Boolean)) throw new Error('invalid_apns_configuration');
  const pushMode = process.env.APNS_PUSH_MODE?.trim() || 'alert';
  if (!['alert', 'background'].includes(pushMode)) throw new Error('invalid_apns_configuration');
  if (pushValues.every(Boolean)) {
    if (process.env.APNS_PRODUCTION && !['true', 'false'].includes(process.env.APNS_PRODUCTION)) throw new Error('invalid_apns_configuration');
    dispatcher = createApnsDispatcher({ teamId: pushValues[0], keyId: pushValues[1], privateKey: await readFile(pushValues[2], 'utf8'), topic: pushValues[3], production: process.env.APNS_PRODUCTION === 'true', timeoutMs: 10_000, pushMode });
  }
  const registry = new DeviceRegistry({ dataDir });
  await registry.initialize();
  const broadcaster = new RevisionBroadcaster({ registry, dispatcher, log });
  const service = new SuspensionService({ apiKey, dataDir, pollIntervalMs, maxCacheAgeMs, requestTimeoutMs, onRevision: (revision) => broadcaster.enqueue(revision), log });
  await service.initialize();
  const server = createHTTPServer({ service, registry, pushConfigured: Boolean(dispatcher), pushMode: dispatcher ? pushMode : null });
  server.listen(port, process.env.HOST || '127.0.0.1', () => {
    log({ event: 'listening', port, sourceConfigured: Boolean(apiKey), pushConfigured: Boolean(dispatcher), pushMode: dispatcher ? pushMode : null });
    service.start();
  });
  let stopping = false;
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    server.close();
    server.closeIdleConnections();
    await Promise.allSettled([service.stop(), broadcaster.stop(), registry.queue]);
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
  server.on('error', () => { log({ event: 'server_failed', code: 'listen_failed' }); void shutdown(); process.exitCode = 1; });
}

main().catch(() => {
  // Never print caught errors: TLS/fetch paths and configuration can contain secrets.
  log({ event: 'startup_failed', code: 'invalid_configuration_or_storage' });
  process.exitCode = 1;
});
