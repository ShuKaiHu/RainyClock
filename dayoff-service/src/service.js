import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { LIMITS, parseAtom, parseCAP, officialCapURL, isoTimestamp } from './parser.js';
import { ServiceError, safeErrorCode } from './errors.js';
import { readJSON, writeJSON } from './storage.js';

const FEED = 'https://alerts.ncdr.nat.gov.tw/webapi/RssAtomFeed.ashx';
const STORED_BYTES = 4 * 1024 * 1024;
export const revisionFor = (notices) => createHash('sha256').update(JSON.stringify(notices)).digest('hex');

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

export class SuspensionService {
  constructor({ apiKey, dataDir, fetchImpl = fetch, now = Date.now, pollIntervalMs = 300_000, maxCacheAgeMs = 900_000, requestTimeoutMs = 10_000, onRevision = async () => {}, log = () => {} }) {
    this.apiKey = apiKey?.trim() ?? '';
    this.statePath = join(dataDir, 'suspensions.json');
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.pollIntervalMs = pollIntervalMs;
    this.maxCacheAgeMs = maxCacheAgeMs;
    this.requestTimeoutMs = requestTimeoutMs;
    this.onRevision = onRevision;
    this.log = log;
    this.capCache = new Map();
    this.snapshot = null;
    this.errorCode = this.apiKey ? 'not_yet_checked' : 'not_configured';
    this.lastAttemptAt = null;
    this.lastSuccessAt = null;
    this.nextAttemptAt = 0;
    this.failures = 0;
    this.inFlight = null;
    this.started = false;
    this.stopped = false;
  }

  async initialize() {
    try {
      const saved = await readJSON(this.statePath, STORED_BYTES);
      if (!saved) return;
      if (saved.schemaVersion !== 1 || !Array.isArray(saved.caps) || saved.caps.length > LIMITS.entries) throw new ServiceError('invalid_stored_state');
      const restored = new Map();
      for (const item of saved.caps) {
        if (!item || !item.notice || typeof item.notice.id !== 'string' || item.notice.id !== item.id) throw new ServiceError('invalid_stored_state');
        officialCapURL(item.url);
        isoTimestamp(item.updatedAt);
        // Revalidate raw CAP bytes, not a previously derived or editable verdict.
        const notice = parseCAP(item.xml, item.id);
        restored.set(item.id, { ...item, notice });
      }
      this.capCache = restored;
      // Persisted data is not served before a successful current feed check.
      this.previousRevision = typeof saved.revision === 'string' ? saved.revision : null;
    } catch {
      this.capCache.clear();
      this.log({ event: 'cache_restore_failed', code: 'invalid_stored_state' });
    }
  }

  health() {
    const available = Boolean(this.apiKey && this.snapshot && !this.errorCode && this.now() - Date.parse(this.snapshot.checkedAt) <= this.maxCacheAgeMs);
    return { configured: Boolean(this.apiKey), available, state: available ? 'ready' : (!this.apiKey ? 'not_configured' : 'unavailable'), errorCode: this.errorCode ?? (available ? null : 'stale_cache'), lastAttemptAt: this.lastAttemptAt, lastSuccessAt: this.lastSuccessAt, nextAttemptAt: this.nextAttemptAt ? new Date(this.nextAttemptAt).toISOString() : null };
  }

  getSnapshot() {
    if (!this.health().available) throw new ServiceError(this.health().errorCode);
    return this.snapshot;
  }

  refresh() {
    if (this.inFlight) return this.inFlight;
    if (this.stopped || !this.apiKey || this.now() < this.nextAttemptAt) return Promise.resolve(false);
    this.inFlight = this.performRefresh().finally(() => { this.inFlight = null; });
    return this.inFlight;
  }

  async performRefresh() {
    this.lastAttemptAt = new Date(this.now()).toISOString();
    const cycleAbort = new AbortController();
    this.cycleAbort = cycleAbort;
    const cycleTimer = setTimeout(() => cycleAbort.abort(), 60_000);
    const signalFor = () => AbortSignal.any([cycleAbort.signal, AbortSignal.timeout(this.requestTimeoutMs)]);
    try {
      const url = new URL(FEED);
      url.searchParams.set('AlertType', '33');
      url.searchParams.set('apikey', this.apiKey);
      const feed = parseAtom(await boundedXML(this.fetchImpl, url.href, LIMITS.feedBytes, signalFor(), this.now()));
      if (feed.sourceUpdatedAt && Date.parse(feed.sourceUpdatedAt) > this.now() + 300_000) throw new ServiceError('source_time_in_future');
      const nextCaps = new Map();
      let cursor = 0, totalBytes = 0;
      const workers = Array.from({ length: Math.min(4, feed.entries.length) }, async () => {
        while (cursor < feed.entries.length) {
          const entry = feed.entries[cursor++];
          const cached = this.capCache.get(entry.id);
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
        }
      });
      try { await Promise.all(workers); } catch (error) {
        cycleAbort.abort();
        await Promise.allSettled(workers);
        throw error;
      }
      const notices = [...nextCaps.values()].map((item) => item.notice).sort((a, b) => a.sentAt.localeCompare(b.sentAt) || a.id.localeCompare(b.id));
      const revision = revisionFor(notices);
      const snapshot = { schemaVersion: 1, checkedAt: new Date(this.now()).toISOString(), sourceUpdatedAt: feed.sourceUpdatedAt, notices, revision };
      await writeJSON(this.statePath, { schemaVersion: 1, revision, checkedAt: snapshot.checkedAt, sourceUpdatedAt: feed.sourceUpdatedAt, caps: [...nextCaps.values()] }, STORED_BYTES);
      const changed = revision !== (this.snapshot?.revision ?? this.previousRevision);
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
      this.failures += 1;
      this.errorCode = safeErrorCode(error);
      const backoff = Math.min(1_800_000, 30_000 * (2 ** Math.min(this.failures - 1, 6)));
      this.nextAttemptAt = this.now() + Math.max(backoff, error?.retryAfterMs ?? 0);
      this.log({ event: 'source_check_failed', code: this.errorCode });
      return false;
    } finally { clearTimeout(cycleTimer); this.cycleAbort = null; }
  }

  start() {
    if (this.started || this.stopped) return;
    this.started = true;
    const tick = async () => {
      await this.refresh();
      if (!this.stopped && this.apiKey) this.timer = setTimeout(tick, Math.max(1000, this.nextAttemptAt - this.now()));
    };
    void tick();
  }

  async stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.cycleAbort?.abort();
    await this.inFlight;
  }
}
