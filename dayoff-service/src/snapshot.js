import { ServiceError } from './errors.js';
import { healthFrom } from './service.js';

// The request-only service never polls; it reads the document the Job wrote.
// One read per instance per cacheMs absorbs the burst of Notification Service
// Extensions that follows a broadcast, while availability is judged against
// the clock on every call so a cached document cannot outlive its 15 minutes.
function wellFormed(doc) {
  return doc?.schemaVersion === 1 && (doc.checkedAt === null || typeof doc.checkedAt === 'string') && (doc.noticesJSON === null || typeof doc.noticesJSON === 'string');
}

// The notices are parsed once per read, not per request; JSON.parse keeps the
// stored key order, so serialising them again yields the bytes the Job hashed.
function decode(doc) {
  if (doc === null) return { doc: null, notices: null, errorCode: 'not_configured' };
  if (!wellFormed(doc)) return { doc, notices: null, errorCode: 'invalid_stored_state' };
  if (doc.noticesJSON === null) return { doc, notices: null, errorCode: doc.errorCode ?? null };
  try {
    const notices = JSON.parse(doc.noticesJSON);
    if (!Array.isArray(notices)) throw new Error('not_a_list');
    return { doc, notices, errorCode: doc.errorCode ?? null };
  } catch { return { doc, notices: null, errorCode: 'invalid_stored_state' }; }
}

function fields({ doc, notices, errorCode }) {
  if (doc === null) return { configured: false };
  return { configured: true, checkedAt: notices ? doc.checkedAt : null, errorCode, lastAttemptAt: doc.lastAttemptAt ?? null, lastSuccessAt: doc.lastSuccessAt ?? null, nextAttemptAt: Number.isFinite(doc.nextAttemptAt) ? doc.nextAttemptAt : 0 };
}

const storageFailure = (error) => (error instanceof ServiceError ? error : new ServiceError('storage_unavailable'));

const broadcastSummary = (claim) => (claim ? { revision: claim.revision ?? null, state: claim.state ?? null, attempts: claim.attempts ?? 0, accepted: claim.accepted ?? 0, failed: claim.failed ?? 0, unregistered: claim.unregistered ?? 0, retryPending: claim.retryPending ?? 0, finishedAt: claim.finishedAt ?? null } : null);

export function createSnapshotReader({ store, now = Date.now, maxCacheAgeMs = 900_000, cacheMs = 5000 }) {
  let cached = null;
  let loading = null;

  function current() {
    if (cached && now() - cached.readAt < cacheMs) return Promise.resolve(cached);
    if (!loading) {
      loading = store.get('state/current')
        .then((doc) => { cached = { ...decode(doc), readAt: now() }; return cached; }, (error) => { throw storageFailure(error); })
        .finally(() => { loading = null; });
    }
    return loading;
  }

  async function health() {
    return healthFrom(fields(await current()), now(), maxCacheAgeMs);
  }

  async function getSnapshot() {
    const state = await current();
    const status = healthFrom(fields(state), now(), maxCacheAgeMs);
    if (!status.available) throw new ServiceError(status.errorCode);
    return { schemaVersion: 1, checkedAt: state.doc.checkedAt, sourceUpdatedAt: state.doc.sourceUpdatedAt, notices: state.notices, revision: state.doc.revision };
  }

  // Diagnostics for the runbook: fresh reads, never through the cache, and
  // nothing a phone sent (no tokens, no installation ids).
  async function details() {
    let doc, lease, claim = null;
    try {
      [doc, lease] = await store.getAll(['state/current', 'state/lease']);
      const revision = doc?.pendingBroadcastRevision ?? doc?.revision ?? null;
      if (typeof revision === 'string') claim = await store.get(`broadcasts/${revision}`);
    } catch (error) { throw storageFailure(error); }
    const state = decode(doc);
    const time = now();
    const status = healthFrom(fields(state), time, maxCacheAgeMs);
    return {
      ...status,
      revision: doc?.revision ?? null,
      checkedAt: doc?.checkedAt ?? null,
      noticeCount: doc?.noticeCount ?? null,
      ageMs: typeof doc?.checkedAt === 'string' ? time - Date.parse(doc.checkedAt) : null,
      sourceUpdatedAt: doc?.sourceUpdatedAt ?? null,
      nextAttemptAt: status.nextAttemptAt,
      job: doc?.job ?? null,
      lease: lease ? { owner: lease.owner ?? null, leaseUntil: lease.leaseUntil ?? 0 } : null,
      broadcast: broadcastSummary(claim),
      storage: store.kind,
      serverTime: new Date(time).toISOString()
    };
  }

  return { health, getSnapshot, details };
}
