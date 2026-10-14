import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { createApnsDispatcher } from '../apns.js';
import { ServiceError } from './errors.js';
import { firestoreConfiguration, createStoreFromEnv, integerSetting } from './runtime.js';
import { SuspensionService, FIXTURE_SOURCE, knownSource, fixtureAllowed } from './service.js';
import { DeviceRegistry } from './devices.js';
import { broadcastRevision } from './broadcast.js';

// Cloud Run Job: one poll, one broadcast, then exit. No listener. Everything
// this process learns is written to state/current before it exits, so the
// request-only service and the next execution start from the same facts.
// Only the summary line goes to stdout; diagnostics carry their own severity
// on stderr so Cloud Logging files them without guessing.
const PUSH_FIELDS = ['APNS_TEAM_ID', 'APNS_KEY_ID', 'APNS_PRIVATE_KEY_PATH', 'APNS_TOPIC'];
const PUSH_MODES = ['alert', 'background'];
const WARMUP_TIMEOUT_MS = 8000;

const defaultLog = (event) => process.stderr.write(JSON.stringify({ severity: 'INFO', at: new Date().toISOString(), ...event }) + '\n');
const defaultStdout = (line) => process.stdout.write(line + '\n');

function serviceUrl(value) {
  if (value === undefined || value === '') return null;
  let url;
  try { url = new URL(value); } catch { throw new ServiceError('invalid_configuration'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new ServiceError('invalid_configuration');
  return url.href.replace(/\/+$/, '');
}

// Shared with local mode, which is the only other process that holds a key.
export function apnsConfiguration(env) {
  const values = PUSH_FIELDS.map((name) => env[name]?.trim());
  if (values.some(Boolean) && !values.every(Boolean)) throw new ServiceError('invalid_apns_configuration');
  const pushMode = env.APNS_PUSH_MODE?.trim() || 'alert';
  if (!PUSH_MODES.includes(pushMode)) throw new ServiceError('invalid_apns_configuration');
  if (!values.every(Boolean)) return { apns: null, pushMode };
  // Sandbox and production tokens are different sets; a default here would
  // silently push to the wrong one, so the environment must say which.
  if (!['true', 'false'].includes(env.APNS_PRODUCTION)) throw new ServiceError('invalid_apns_configuration');
  return { apns: { teamId: values[0], keyId: values[1], privateKeyPath: values[2], topic: values[3], production: env.APNS_PRODUCTION === 'true', pushMode }, pushMode };
}

// Pure: nothing here touches the disk, the network or the store, so a bad
// deployment fails before it can hold a lease.
export function jobConfig(env = process.env) {
  const source = (env.NCDR_SOURCE ?? 'member').trim();
  const apiKey = env.NCDR_API_KEY?.trim() || null;
  if (!knownSource(source)) throw new ServiceError('invalid_configuration');
  if (source === 'member' && !apiKey) throw new ServiceError('invalid_configuration');
  if (source !== 'member' && apiKey) throw new ServiceError('invalid_configuration');
  const firestore = firestoreConfiguration(env);
  // The fixture source reads whatever an operator wrote; only a namespace
  // that says sandbox may ever be served from it.
  if (source === FIXTURE_SOURCE && !fixtureAllowed(firestore.namespace)) throw new ServiceError('fixture_not_allowed');
  const leaseMs = integerSetting(env, 'LEASE_MS', 120_000, 10_000, 600_000);
  const leaseRenewMs = integerSetting(env, 'LEASE_RENEW_MS', 30_000, 1000, 600_000);
  if (leaseRenewMs >= leaseMs) throw new ServiceError('invalid_configuration');
  return {
    source,
    apiKey,
    ...apnsConfiguration(env),
    pollIntervalMs: integerSetting(env, 'POLL_INTERVAL_MS', 300_000, 60_000, 3_600_000),
    requestTimeoutMs: integerSetting(env, 'REQUEST_TIMEOUT_MS', 10_000, 2000, 30_000),
    concurrency: integerSetting(env, 'BROADCAST_CONCURRENCY', 16, 1, 64),
    pageSize: integerSetting(env, 'BROADCAST_PAGE_SIZE', 200, 50, 500),
    leaseMs,
    leaseRenewMs,
    runBudgetMs: integerSetting(env, 'RUN_BUDGET_MS', 420_000, 10_000, 3_600_000),
    serviceUrl: serviceUrl(env.DAYOFF_SERVICE_URL),
    // Execution-level, so a task retry of the same execution takes over the
    // lease its killed predecessor still holds.
    owner: env.CLOUD_RUN_EXECUTION?.trim() || randomUUID(),
    firestore
  };
}

export async function createDispatcher(config, transport, now) {
  if (!config.apns) return null;
  let privateKey;
  try { privateKey = await readFile(config.apns.privateKeyPath, 'utf8'); } catch { throw new ServiceError('invalid_apns_configuration'); }
  const { teamId, keyId, topic, production, pushMode } = config.apns;
  try { return createApnsDispatcher({ teamId, keyId, privateKey, topic, production, pushMode, timeoutMs: 10_000, transport, now }); }
  catch { throw new ServiceError('invalid_apns_configuration'); }
}

// state/lease is separate from state/current so heartbeats never rewrite
// the document the phones are served from.
function acquireLease({ store, owner, leaseMs, now }) {
  return store.runTransaction(async (tx) => {
    const lease = await tx.get('state/lease');
    const time = now();
    if (lease && lease.owner !== owner && Number(lease.leaseUntil) > time) return false;
    tx.set('state/lease', { owner, leaseUntil: time + leaseMs });
    return true;
  });
}

function renewLease({ store, owner, leaseMs, now }) {
  return store.runTransaction(async (tx) => {
    const lease = await tx.get('state/lease');
    if (lease?.owner !== owner) return false;
    tx.set('state/lease', { owner, leaseUntil: now() + leaseMs });
    return true;
  });
}

function releaseLease({ store, owner }) {
  return store.runTransaction(async (tx) => {
    const lease = await tx.get('state/lease');
    if (lease?.owner === owner) tx.set('state/lease', { owner: null, leaseUntil: 0 });
  });
}

// Best effort: a warm instance before the extension herd. The served
// revision itself is guaranteed by the single-document commit, not by this.
async function warmUp({ fetchImpl, url, revision, log }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), WARMUP_TIMEOUT_MS);
  let result = { status: 0, revisionMatches: false };
  try {
    const response = await fetchImpl(`${url}/v1/suspensions`, { signal: controller.signal, headers: { Accept: 'application/json' } });
    let revisionMatches = false;
    try { revisionMatches = (await response.json())?.revision === revision; } catch { /* Not JSON: reported as a mismatch. */ }
    result = { status: response.status, revisionMatches };
  } catch { /* Reported below. */ } finally { clearTimeout(timer); }
  log({ event: 'dayoff_warmup', ...result });
  return result;
}

const documented = (broadcast) => (broadcast ? { revision: broadcast.revision, state: broadcast.state, attempts: broadcast.attempts, accepted: broadcast.accepted, failed: broadcast.failed, unregistered: broadcast.unregistered, retryPending: broadcast.retryPending, complete: broadcast.complete } : null);

// Exit 1 is reserved for what a Cloud Run task retry can fix or an operator
// must see now; a source failure exits 0 because the persisted backoff is
// its retry, and an immediate rerun would only trip that gate.
function exitCodeFor(failure, broadcast) {
  if (failure) return 1;
  if (broadcast?.state === 'partial' && !(broadcast.passComplete && broadcast.retryPending > 0)) return 1;
  return 0;
}

export async function runJob({ env = process.env, store: injectedStore, closeStore = async () => {}, fetchImpl = fetch, transport, now = Date.now, log = defaultLog, stdout = defaultStdout, signal } = {}) {
  const config = jobConfig(env);
  const dispatcher = await createDispatcher(config, transport, now);
  const { store, close } = injectedStore ? { store: injectedStore, close: closeStore } : createStoreFromEnv(env, { log });
  const { owner, leaseMs } = config;
  const startedAt = now();
  const summary = { event: 'dayoff_job', severity: 'INFO', ok: true, owner, source: config.source, skipped: null, refreshed: false, changed: false, revision: null, noticeCount: null, errorCode: null, warmup: null, broadcast: null, durationMs: 0 };
  let failure = null;
  let leased = false;
  let lostLease = false;
  let heldUntil = 0;
  let heartbeat = null;
  let renewal = null;
  let broadcast = null;
  try {
    leased = await acquireLease({ store, owner, leaseMs, now });
    if (!leased) {
      summary.skipped = 'lease_held';
    } else {
      heldUntil = now() + leaseMs;
      // The lease is lost when the document names someone else, or when it
      // has expired unrenewed; one failed renewal is neither, since the
      // document still names this owner for the rest of the lease.
      heartbeat = setInterval(() => {
        if (renewal) return;
        const renewedAt = now();
        renewal = renewLease({ store, owner, leaseMs, now })
          .then((held) => { if (held) heldUntil = renewedAt + leaseMs; else lostLease = true; }, () => { if (now() > heldUntil) lostLease = true; })
          .finally(() => { renewal = null; });
      }, config.leaseRenewMs);
      heartbeat.unref();
      const service = new SuspensionService({ source: config.source, apiKey: config.apiKey, store, owner, namespace: config.firestore.namespace, fetchImpl, now, pollIntervalMs: config.pollIntervalMs, requestTimeoutMs: config.requestTimeoutMs, push: { configured: Boolean(dispatcher), mode: dispatcher ? config.pushMode : null }, log });
      await service.initialize();
      if (now() < service.nextAttemptAt) summary.skipped = 'backoff';
      summary.refreshed = await service.refresh();
      const stored = await store.get('state/current');
      summary.revision = stored?.revision ?? null;
      summary.noticeCount = Number.isInteger(stored?.noticeCount) ? stored.noticeCount : null;
      summary.errorCode = summary.refreshed ? null : summary.skipped === 'backoff' ? stored?.errorCode ?? null : service.errorCode;
      summary.changed = summary.refreshed && stored?.job?.owner === owner && stored.job.changed === true;
      if (summary.changed && config.serviceUrl) summary.warmup = await warmUp({ fetchImpl, url: config.serviceUrl, revision: summary.revision, log });
      const pending = stored?.pendingBroadcastRevision;
      // No dispatcher leaves the pointer in place: nothing is lost, the next
      // configured execution sends it.
      if (typeof pending === 'string' && dispatcher) {
        broadcast = await broadcastRevision({ store, registry: new DeviceRegistry({ store, now }), dispatcher, revision: pending, owner, concurrency: config.concurrency, pageSize: config.pageSize, leaseMs, deadlineAt: startedAt + config.runBudgetMs, isCancelled: () => Boolean(signal?.aborted) || lostLease, now, log });
        summary.broadcast = documented(broadcast);
      }
    }
  } catch (error) {
    failure = error instanceof ServiceError ? error.code : 'internal_error';
    summary.errorCode = failure;
  } finally {
    clearInterval(heartbeat);
    await renewal;
    // Owner-checked, so a lease that really went to someone else is left alone.
    if (leased) await releaseLease({ store, owner }).catch(() => {});
    dispatcher?.close();
    try { await close(); } catch { failure ??= 'storage_unavailable'; summary.errorCode ??= failure; }
    summary.durationMs = now() - startedAt;
  }
  const exitCode = exitCodeFor(failure, broadcast);
  summary.ok = exitCode === 0 && summary.errorCode === null && !broadcast?.exhausted;
  summary.severity = exitCode === 0 ? (summary.ok ? 'INFO' : 'WARNING') : 'ERROR';
  stdout(JSON.stringify(summary));
  return { exitCode, summary };
}

async function main() {
  const controller = new AbortController();
  for (const event of ['SIGTERM', 'SIGINT']) process.once(event, () => controller.abort());
  let exitCode = 1;
  try {
    ({ exitCode } = await runJob({ signal: controller.signal }));
  } catch (error) {
    // Configuration and startup failures: a code only, never the values.
    process.stderr.write(JSON.stringify({ event: 'dayoff_job_failed', code: error instanceof ServiceError ? error.code : 'invalid_configuration' }) + '\n');
  }
  process.exit(exitCode);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) void main();
