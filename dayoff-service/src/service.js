import { createHash } from 'node:crypto';
import { LIMITS, parseAtom, parseCAP, officialCapURL, isoTimestamp } from './parser.js';
import { ServiceError, safeErrorCode } from './errors.js';

// Two official publications of the same DGPA feed. 'member' is NCDR's
// post-2026-01-30 interface and needs a member API key, which NCDR only
// issues to institutional e-mail addresses. 'open-data' is the keyless URL
// that data.gov.tw dataset 20457 registers under the Open Government Data
// License; NCDR announced its retirement for 2026-03-31 but it was still
// serving on 2026-09-24. The choice is explicit configuration, never a
// silent fallback, so a health check always says which one is in use.
export const SOURCES = {
  member: 'https://alerts.ncdr.nat.gov.tw/webapi/RssAtomFeed.ashx',
  'open-data': 'https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx'
};
// Firestore documents stop at 1 MiB; the rest of state/current is small, so
// this leaves room without ever truncating a notice list silently.
const STORED_NOTICES_BYTES = 900_000;
const CAP_TTL_MS = 30 * 24 * 60 * 60 * 1000;
// A transaction takes 500 writes; state/current and the broadcast claim need
// two, so past this many fresh CAPs they are written ahead of the commit.
const INLINE_CAP_WRITES = 450;
const hashOf = (text) => createHash('sha256').update(text).digest('hex');
export const revisionFor = (notices) => hashOf(JSON.stringify(notices));
// Codes that mean this process must not keep going, as opposed to a source
// problem the persisted backoff retries on its own.
const FATAL = new Set(['storage_unavailable', 'lease_lost']);

// The one availability rule, shared with the request-only reader so a cached
// document and a live poller can never disagree about a 503.
export function healthFrom({ configured, checkedAt = null, errorCode = null, lastAttemptAt = null, lastSuccessAt = null, nextAttemptAt = 0 }, now, maxCacheAgeMs) {
  const hasSnapshot = typeof checkedAt === 'string';
  const available = Boolean(configured && hasSnapshot && errorCode === null && now - Date.parse(checkedAt) <= maxCacheAgeMs);
  return {
    configured: Boolean(configured),
    available,
    state: available ? 'ready' : (configured ? 'unavailable' : 'not_configured'),
    errorCode: errorCode ?? (!configured ? 'not_configured' : available ? null : hasSnapshot ? 'stale_cache' : 'not_yet_checked'),
    lastAttemptAt,
    lastSuccessAt,
    nextAttemptAt: nextAttemptAt ? new Date(nextAttemptAt).toISOString() : null
  };
}

function retryAfter(value, now) {
  if (!value) return 0;
  const delay = /^\d+$/.test(value) ? Number(value) * 1000 : Date.parse(value) - now;
  return Number.isFinite(delay) ? Math.max(0, Math.min(delay, 3_600_000)) : 0;
}

async function boundedXML(fetchImpl, url, maximum, signal, now) {
  let response;
  try {
    response = await fetchImpl(url, { redirect: 'error', signal, headers: { Accept: 'application/atom+xml, application/xml, text/xml', 'User-Agent': 'RainyClock-Dayoff/0.1 (+https://www.dgpa.gov.tw/typh/daily/nds.html)' } });
  } catch { throw new ServiceError(signal.aborted ? 'upstream_timeout' : 'upstream_unavailable'); }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw new ServiceError(response.status === 429 ? 'upstream_rate_limited' : 'upstream_http_error', { retryAfterMs: retryAfter(response.headers.get('retry-after'), now) });
  }
  if (!/^(?:application\/(?:atom\+xml|xml)|text\/xml)(?:\s*;|$)/i.test(response.headers.get('content-type') ?? '')) {
    await response.body?.cancel().catch(() => {});
    throw new ServiceError('invalid_source_content_type');
  }
  const length = Number(response.headers.get('content-length'));
  if (length > maximum) {
    await response.body?.cancel().catch(() => {});
    throw new ServiceError('source_too_large');
  }
  const reader = response.body?.getReader();
  if (!reader) throw new ServiceError('invalid_source_xml');
  const chunks = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maximum) throw new ServiceError('source_too_large');
      chunks.push(value);
    }
    return new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, bytes));
  } catch (error) {
    if (error instanceof ServiceError) throw error;
    throw new ServiceError(signal.aborted ? 'upstream_timeout' : 'invalid_source_encoding');
  } finally { await reader.cancel().catch(() => {}); }
}

// A cached CAP is only reused for the same feed entry, and only after its raw
// bytes pass the parser again: the document holds xml, never a verdict.
function restoredCap(doc, entry) {
  try {
    if (!doc || doc.id !== entry.id || doc.url !== entry.url || doc.updatedAt !== entry.updatedAt || typeof doc.xml !== 'string') return null;
    officialCapURL(doc.url);
    isoTimestamp(doc.updatedAt);
    return { id: doc.id, url: doc.url, updatedAt: doc.updatedAt, xml: doc.xml, notice: parseCAP(doc.xml, entry.id) };
  } catch { return null; }
}

// Fields carried forward when a run fails, so the served snapshot survives a
// bad poll and only the health fields change. A document of another schema
// carries nothing forward.
function carriedState(stored) {
  const valid = stored?.schemaVersion === 1;
  return {
    revision: valid && typeof stored.revision === 'string' ? stored.revision : null,
    checkedAt: valid && typeof stored.checkedAt === 'string' ? stored.checkedAt : null,
    sourceUpdatedAt: valid && typeof stored.sourceUpdatedAt === 'string' ? stored.sourceUpdatedAt : null,
    noticesJSON: valid && typeof stored.noticesJSON === 'string' ? stored.noticesJSON : null,
    noticeCount: valid && Number.isInteger(stored.noticeCount) ? stored.noticeCount : 0,
    lastSuccessAt: valid && typeof stored.lastSuccessAt === 'string' ? stored.lastSuccessAt : null,
    pendingBroadcastRevision: valid && typeof stored.pendingBroadcastRevision === 'string' ? stored.pendingBroadcastRevision : null
  };
}

export class SuspensionService {
  constructor({ source = 'member', apiKey, store, owner = null, fetchImpl = fetch, now = Date.now, pollIntervalMs = 300_000, maxCacheAgeMs = 900_000, requestTimeoutMs = 10_000, push = { configured: false, mode: null }, onRevision = async () => {}, log = () => {} }) {
    if (!Object.hasOwn(SOURCES, source)) throw new ServiceError('invalid_configuration');
    this.source = source;
    this.apiKey = apiKey?.trim() ?? '';
    // A key with the open-data source is a deployment mistake, not a choice.
    if (source === 'open-data' && this.apiKey) throw new ServiceError('invalid_configuration');
    this.configured = source === 'open-data' || Boolean(this.apiKey);
    this.store = store;
    this.owner = owner;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.pollIntervalMs = pollIntervalMs;
    this.maxCacheAgeMs = maxCacheAgeMs;
    this.requestTimeoutMs = requestTimeoutMs;
    this.push = { configured: Boolean(push?.configured), mode: push?.mode ?? null };
    this.onRevision = onRevision;
    this.log = log;
    this.capCache = new Map();
    this.snapshot = null;
    this.previousRevision = null;
    this.errorCode = this.configured ? 'not_yet_checked' : 'not_configured';
    this.lastAttemptAt = null;
    this.lastSuccessAt = null;
    this.nextAttemptAt = 0;
    this.failures = 0;
    this.inFlight = null;
    this.started = false;
    this.stopped = false;
  }

  // Persisted data is never served before a successful current feed check;
  // only the backoff of an earlier failed run carries over, so a 429
  // Retry-After is honoured across processes.
  async initialize() {
    let saved;
    try {
      saved = await this.store.get('state/current');
    } catch (error) {
      if (error instanceof ServiceError && FATAL.has(error.code)) throw error;
      saved = undefined;
    }
    if (saved === null) return;
    if (!saved || saved.schemaVersion !== 1 || (saved.revision !== null && typeof saved.revision !== 'string')) {
      this.capCache.clear();
      this.log({ event: 'cache_restore_failed', code: 'invalid_stored_state' });
      return;
    }
    this.previousRevision = saved.revision;
    if (Number.isInteger(saved.failures) && saved.failures > 0 && Number.isFinite(saved.nextAttemptAt)) {
      this.failures = saved.failures;
      this.nextAttemptAt = saved.nextAttemptAt;
    }
  }

  health() {
    return healthFrom({ configured: this.configured, checkedAt: this.snapshot?.checkedAt ?? null, errorCode: this.errorCode, lastAttemptAt: this.lastAttemptAt, lastSuccessAt: this.lastSuccessAt, nextAttemptAt: this.nextAttemptAt }, this.now(), this.maxCacheAgeMs);
  }

  getSnapshot() {
    if (!this.health().available) throw new ServiceError(this.health().errorCode);
    return this.snapshot;
  }

  refresh() {
    if (this.inFlight) return this.inFlight;
    if (this.stopped || !this.configured) return Promise.resolve(false);
    if (this.now() < this.nextAttemptAt) {
      this.log({ event: 'source_check_skipped', nextAttemptAt: new Date(this.nextAttemptAt).toISOString() });
      return Promise.resolve(false);
    }
    this.inFlight = this.performRefresh().finally(() => { this.inFlight = null; });
    return this.inFlight;
  }

  async performRefresh() {
    const startedAt = this.now();
    this.lastAttemptAt = new Date(startedAt).toISOString();
    const cycleAbort = new AbortController();
    this.cycleAbort = cycleAbort;
    const cycleTimer = setTimeout(() => cycleAbort.abort(), 60_000);
    const signalFor = () => AbortSignal.any([cycleAbort.signal, AbortSignal.timeout(this.requestTimeoutMs)]);
    try {
      const url = new URL(SOURCES[this.source]);
      url.searchParams.set('AlertType', '33');
      if (this.source === 'member') url.searchParams.set('apikey', this.apiKey);
      const feed = parseAtom(await boundedXML(this.fetchImpl, url.href, LIMITS.feedBytes, signalFor(), this.now()));
      if (feed.sourceUpdatedAt && Date.parse(feed.sourceUpdatedAt) > this.now() + 300_000) throw new ServiceError('source_time_in_future');
      const stored = await this.storedCaps(feed.entries.filter((entry) => !this.capCache.has(entry.id)));
      const nextCaps = new Map();
      const fetched = new Set();
      let cursor = 0, totalBytes = 0;
      const workers = Array.from({ length: Math.min(4, feed.entries.length) }, async () => {
        while (cursor < feed.entries.length) {
          const entry = feed.entries[cursor++];
          const cached = this.capCache.get(entry.id) ?? stored.get(entry.id);
          if (cached && cached.updatedAt === entry.updatedAt && cached.url === entry.url) {
            nextCaps.set(entry.id, cached);
            continue;
          }
          const xml = await boundedXML(this.fetchImpl, entry.url, LIMITS.capBytes, signalFor(), this.now());
          totalBytes += Buffer.byteLength(xml);
          if (totalBytes > 16 * 1024 * 1024) throw new ServiceError('source_too_large');
          const notice = parseCAP(xml, entry.id);
          if (Date.parse(notice.sentAt) > this.now() + 300_000) throw new ServiceError('source_time_in_future');
          nextCaps.set(entry.id, { ...entry, xml, notice });
          fetched.add(entry.id);
        }
      });
      try { await Promise.all(workers); } catch (error) {
        cycleAbort.abort();
        await Promise.allSettled(workers);
        throw error;
      }
      const notices = [...nextCaps.values()].map((item) => item.notice).sort((a, b) => a.sentAt.localeCompare(b.sentAt) || a.id.localeCompare(b.id));
      // Hash the exact string that is stored, so the served bytes and the
      // revision cannot drift apart however the store returns the document.
      const noticesJSON = JSON.stringify(notices);
      if (Buffer.byteLength(noticesJSON) > STORED_NOTICES_BYTES) throw new ServiceError('stored_state_too_large');
      const revision = hashOf(noticesJSON);
      const snapshot = { schemaVersion: 1, checkedAt: new Date(this.now()).toISOString(), sourceUpdatedAt: feed.sourceUpdatedAt, notices, revision };
      const changed = await this.commit({ snapshot, noticesJSON, fresh: [...nextCaps.values()].filter((item) => fetched.has(item.id)), startedAt });
      this.capCache = nextCaps;
      this.snapshot = snapshot;
      this.lastSuccessAt = snapshot.checkedAt;
      this.errorCode = null;
      this.failures = 0;
      this.nextAttemptAt = this.now() + this.pollIntervalMs;
      this.log({ event: 'source_checked', noticeCount: notices.length, changed });
      if (changed) void Promise.resolve().then(() => this.onRevision(revision)).catch(() => this.log({ event: 'push_dispatch_failed' }));
      return true;
    } catch (error) {
      if (error instanceof ServiceError && FATAL.has(error.code)) throw error;
      this.failures += 1;
      this.errorCode = safeErrorCode(error);
      const backoff = Math.min(1_800_000, 30_000 * (2 ** Math.min(this.failures - 1, 6)));
      this.nextAttemptAt = this.now() + Math.max(backoff, error?.retryAfterMs ?? 0);
      this.log({ event: 'source_check_failed', code: this.errorCode });
      await this.recordFailure(startedAt);
      return false;
    } finally { clearTimeout(cycleTimer); this.cycleAbort = null; }
  }

  async storedCaps(entries) {
    if (entries.length === 0) return new Map();
    const docs = await this.store.getAll(entries.map((entry) => `caps/${entry.id}`));
    const restored = new Map();
    entries.forEach((entry, index) => {
      const item = restoredCap(docs[index], entry);
      if (item) restored.set(entry.id, item);
    });
    return restored;
  }

  capDocument(item) {
    const now = this.now();
    return { id: item.id, url: item.url, updatedAt: item.updatedAt, xml: item.xml, storedAt: new Date(now).toISOString(), expiresAt: new Date(now + CAP_TTL_MS) };
  }

  // The lease belongs to whoever runs the poll; asserting it inside the same
  // transaction as the write is what stops a slow, stale run from overwriting
  // a newer result after its lease has moved on.
  assertLease(lease) {
    if (this.owner !== null && lease?.owner !== this.owner) throw new ServiceError('lease_lost');
  }

  async commit({ snapshot, noticesJSON, fresh, startedAt }) {
    const inline = fresh.length <= INLINE_CAP_WRITES;
    if (!inline) for (const item of fresh) await this.store.set(`caps/${item.id}`, this.capDocument(item));
    return this.store.runTransaction(async (tx) => {
      const [lease, stored] = await tx.getAll(['state/lease', 'state/current']);
      this.assertLease(lease);
      const carried = carriedState(stored);
      const changed = snapshot.revision !== carried.revision;
      const now = this.now();
      tx.set('state/current', {
        schemaVersion: 1,
        revision: snapshot.revision,
        checkedAt: snapshot.checkedAt,
        sourceUpdatedAt: snapshot.sourceUpdatedAt,
        noticesJSON,
        noticeCount: snapshot.notices.length,
        errorCode: null,
        failures: 0,
        lastAttemptAt: this.lastAttemptAt,
        lastSuccessAt: snapshot.checkedAt,
        nextAttemptAt: now + this.pollIntervalMs,
        pendingBroadcastRevision: changed ? snapshot.revision : carried.pendingBroadcastRevision,
        source: this.source,
        push: this.push,
        job: { owner: this.owner, finishedAt: new Date(now).toISOString(), durationMs: now - startedAt, code: null, changed },
        updatedAt: new Date(now).toISOString()
      });
      // A revision that becomes current again after a flip-flop starts a full
      // pass: the claim is overwritten, not resumed.
      if (changed) {
        tx.set(`broadcasts/${snapshot.revision}`, { revision: snapshot.revision, claimedAt: now, state: 'pending', owner: null, leaseUntil: 0, attempts: 0, cursor: null, passComplete: false, accepted: 0, failed: 0, unregistered: 0, retryPending: 0, finishedAt: null, expiresAt: new Date(now + 7 * 24 * 60 * 60 * 1000) });
      }
      if (inline) for (const item of fresh) tx.set(`caps/${item.id}`, this.capDocument(item));
      return changed;
    });
  }

  // A failed poll leaves the snapshot fields alone and only records why, so
  // the reader answers 503 with this code at once and the next run waits.
  async recordFailure(startedAt) {
    await this.store.runTransaction(async (tx) => {
      const [lease, stored] = await tx.getAll(['state/lease', 'state/current']);
      this.assertLease(lease);
      const now = this.now();
      tx.set('state/current', {
        schemaVersion: 1,
        ...carriedState(stored),
        errorCode: this.errorCode,
        failures: this.failures,
        lastAttemptAt: this.lastAttemptAt,
        nextAttemptAt: this.nextAttemptAt,
        source: this.source,
        push: this.push,
        job: { owner: this.owner, finishedAt: new Date(now).toISOString(), durationMs: now - startedAt, code: this.errorCode, changed: false },
        updatedAt: new Date(now).toISOString()
      });
    });
  }

  start() {
    if (this.started || this.stopped) return;
    this.started = true;
    const tick = async () => {
      try { await this.refresh(); }
      catch (error) { this.log({ event: 'source_check_aborted', code: safeErrorCode(error) }); }
      if (!this.stopped && this.configured) this.timer = setTimeout(tick, Math.max(1000, this.nextAttemptAt - this.now()));
    };
    void tick();
  }

  async stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.cycleAbort?.abort();
    await this.inFlight?.catch(() => {});
  }
}
