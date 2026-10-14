import { randomUUID } from 'node:crypto';
import { ServiceError } from './errors.js';

// One resumable pass per revision. The claim document is the whole state of
// a broadcast: which run holds it, how far the device scan got, and how many
// tokens still owe a retry. Every counter and cursor write goes through a
// transaction that re-reads the claim and checks the owner and pass id, so a
// run that lost its lease (or was superseded) cannot write over a newer one.
const MAX_ATTEMPTS = 3;
const DEVICE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const CLAIM_TTL_MS = 7 * 24 * 60 * 60 * 1000;
// A degraded APNs answers 429/5xx for nearly everyone; past this many results
// in one run, that ratio stops the pass instead of burning the budget.
const BREAKER_MIN_RESULTS = 100;
const BREAKER_RATIO = 0.5;
const CREDENTIAL_REJECTIONS = { 400: ['BadTopic', 'TopicDisallowed'], 403: ['ExpiredProviderToken', 'InvalidProviderToken', 'MissingProviderToken'] };
const HEX = /^[a-f0-9]{64}$/;
const FATAL = new Set(['lease_lost', 'apns_credentials_rejected']);
// States nothing will send again: a later claim reports them and stops.
const FINISHED = new Set(['done', 'superseded', 'exhausted']);

const claimPath = (revision) => `broadcasts/${revision}`;
const retriesPath = (revision) => `broadcasts/${revision}/retries`;
const retryPath = (revision, token) => `${retriesPath(revision)}/${token}`;
const counter = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : 0);

// Same shape the poll commit writes when a revision changes; created here only
// when nothing wrote one (tests and local mode).
function freshClaim(revision, time) {
  return { revision, claimedAt: time, state: 'pending', owner: null, leaseUntil: 0, attempts: 0, cursor: null, passComplete: false, accepted: 0, failed: 0, unregistered: 0, retryPending: 0, finishedAt: null, expiresAt: new Date(time + CLAIM_TTL_MS) };
}

function normalised(doc, revision, time) {
  if (!doc) return freshClaim(revision, time);
  return {
    ...doc,
    revision,
    claimedAt: counter(doc.claimedAt),
    state: typeof doc.state === 'string' ? doc.state : 'pending',
    owner: typeof doc.owner === 'string' ? doc.owner : null,
    leaseUntil: counter(doc.leaseUntil),
    attempts: counter(doc.attempts),
    cursor: typeof doc.cursor === 'string' ? doc.cursor : null,
    passComplete: doc.passComplete === true,
    accepted: counter(doc.accepted),
    failed: counter(doc.failed),
    unregistered: counter(doc.unregistered),
    retryPending: counter(doc.retryPending),
    finishedAt: typeof doc.finishedAt === 'string' ? doc.finishedAt : null
  };
}

// apns.js already decides retryable (429, 5xx, Timeout, NetworkError,
// InvalidResponse); the only classification added here is the credential
// rejection that no amount of retrying fixes.
export function classifyResult(result) {
  if (!result || typeof result !== 'object') return 'failed';
  if (result.ok) return 'accepted';
  if (result.unregistered) return 'unregistered';
  if (CREDENTIAL_REJECTIONS[result.status]?.includes(result.reason)) return 'credentials_rejected';
  return result.retryable ? 'retryable' : 'failed';
}

function outcome(claim, extra = {}) {
  return {
    revision: claim.revision,
    state: claim.state,
    attempts: claim.attempts,
    accepted: claim.accepted,
    failed: claim.failed,
    unregistered: claim.unregistered,
    retryPending: claim.retryPending,
    passComplete: claim.passComplete,
    complete: claim.state === 'done' || claim.state === 'superseded',
    ...(claim.state === 'exhausted' ? { exhausted: true } : {}),
    ...extra
  };
}

// Exhaustion is written down, not just reported: the pointer that names this
// revision is cleared so no later tick re-claims it, and the claim itself is
// marked so it cannot be mistaken for a fresh one once the TTL removes it
// (a missing claim would otherwise start a full pass of a week-old feed).
async function claimRevision({ store, revision, owner, leaseMs, now }) {
  return store.runTransaction(async (tx) => {
    const time = now();
    const [stored, state] = await tx.getAll([claimPath(revision), 'state/current']);
    const current = normalised(stored, revision, time);
    if (FINISHED.has(current.state)) return { claim: current, skipped: current.state };
    if (current.owner !== owner && current.leaseUntil > time) return { claim: current, skipped: 'broadcast_in_progress' };
    if (current.attempts >= MAX_ATTEMPTS) {
      const claim = { ...current, owner: null, leaseUntil: 0, state: 'exhausted', finishedAt: new Date(time).toISOString() };
      tx.set(claimPath(revision), claim);
      if (state?.pendingBroadcastRevision === revision) tx.set('state/current', { ...state, pendingBroadcastRevision: null });
      return { claim, exhausted: true };
    }
    const claim = { ...current, owner, leaseUntil: time + leaseMs, attempts: current.attempts + 1, state: 'sending' };
    tx.set(claimPath(revision), claim);
    return { claim };
  });
}

// A run that APNs refused on credentials sent nothing the attempt cap is
// meant to bound, so the attempt it claimed is given back: three ticks with
// an expired key must not exhaust a revision the rotated key could still
// send. Owner and pass are checked so a newer holder is never touched.
async function refundAttempt({ store, revision, owner }, pass) {
  return store.runTransaction(async (tx) => {
    const stored = await tx.get(claimPath(revision));
    const claim = stored && normalised(stored, revision, 0);
    if (!claim || claim.owner !== owner || claim.claimedAt !== pass) return claim;
    const refunded = { ...claim, attempts: Math.max(0, claim.attempts - 1) };
    tx.set(claimPath(revision), refunded);
    return refunded;
  });
}

async function releaseClaim({ store, revision, owner }) {
  await store.runTransaction(async (tx) => {
    const claim = await tx.get(claimPath(revision));
    if (claim?.owner === owner) tx.set(claimPath(revision), { ...claim, owner: null, leaseUntil: 0 });
  });
}

// A worker pool over one page. A 410 is acted on at once (the conditional
// delete is its own transaction); everything else is reported back so the
// checkpoint can record it together with the cursor.
async function sendPage(tokens, { dispatcher, registry, revision, concurrency }) {
  const page = { accepted: 0, failed: 0, unregistered: 0, retryable: [], resolved: [] };
  let next = 0;
  let abort = null;
  await Promise.all(Array.from({ length: Math.min(concurrency, tokens.length) }, async () => {
    while (next < tokens.length && !abort) {
      const token = tokens[next++];
      let result;
      try { result = await dispatcher.send(token, { revision }); } catch { result = null; }
      const kind = classifyResult(result);
      if (kind === 'credentials_rejected') { abort = new ServiceError('apns_credentials_rejected'); break; }
      if (kind === 'retryable') { page.retryable.push({ token, reason: typeof result.reason === 'string' ? result.reason : 'Rejected' }); continue; }
      page.resolved.push(token);
      if (kind === 'accepted') page.accepted += 1;
      else if (kind === 'unregistered') {
        // A busy registry refuses the delete; the token is counted as failed
        // and the next broadcast to it gets another 410 to act on.
        try { await registry.removeUnregistered(token, result.timestamp); page.unregistered += 1; } catch { page.failed += 1; }
      } else page.failed += 1;
    }
  }));
  if (abort) throw abort;
  return page;
}

// The one write per page. Reads come first (claim, served state, this page's
// retry documents), then the owner and pass assertion, then the writes.
// Firestore may run the body more than once, so it is pure over its reads.
async function checkpoint(context, run, page, { cursor, exhausted, retriesPass }) {
  const { store, revision, owner, leaseMs, deadlineAt, isCancelled, now } = context;
  const pass = run.pass;
  const retryTokens = page.retryable.map(({ token }) => token);
  const paths = [claimPath(revision), 'state/current', ...retryTokens.map((token) => retryPath(revision, token))];
  const breaker = run.results >= BREAKER_MIN_RESULTS && run.retryable / run.results > BREAKER_RATIO;
  return store.runTransaction(async (tx) => {
    const [stored, current, ...priors] = await tx.getAll(paths);
    const claim = stored && normalised(stored, revision, 0);
    if (!claim || claim.owner !== owner || claim.claimedAt !== pass) throw new ServiceError('lease_lost');
    const time = now();
    let retryPending = claim.retryPending;
    page.retryable.forEach(({ token, reason }, index) => {
      const prior = priors[index]?.claimedAt === pass ? priors[index] : null;
      if (!prior) retryPending += 1;
      tx.set(retryPath(revision, token), { token, reason, claimedAt: pass, attempts: counter(prior?.attempts) + 1, expiresAt: new Date(time + CLAIM_TTL_MS) });
    });
    if (retriesPass) {
      for (const token of page.resolved) tx.delete(retryPath(revision, token));
      retryPending = Math.max(0, retryPending - page.resolved.length);
    }
    const updated = {
      ...claim,
      cursor,
      passComplete: claim.passComplete || exhausted,
      leaseUntil: time + leaseMs,
      accepted: claim.accepted + page.accepted,
      failed: claim.failed + page.failed,
      unregistered: claim.unregistered + page.unregistered,
      retryPending
    };
    const superseded = Boolean(current) && typeof current.pendingBroadcastRevision === 'string' && current.pendingBroadcastRevision !== revision;
    let stop = null;
    if (superseded) {
      updated.state = 'superseded';
      updated.finishedAt = new Date(time).toISOString();
      stop = 'superseded';
    } else if (exhausted && retryPending === 0) {
      updated.state = 'done';
      updated.finishedAt = new Date(time).toISOString();
      // Only this revision's own pointer is cleared: a newer commit has
      // already moved it on, and must keep it.
      if (current?.pendingBroadcastRevision === revision) tx.set('state/current', { ...current, pendingBroadcastRevision: null });
      stop = 'done';
    } else if (exhausted || isCancelled() || time > deadlineAt || breaker) {
      updated.state = 'partial';
      stop = 'partial';
    }
    tx.set(claimPath(revision), updated);
    return { stop, claim: updated };
  });
}

function liveToken(data, time) {
  if (typeof data?.deviceToken !== 'string' || !HEX.test(data.deviceToken) || !Number.isFinite(data.updatedAt)) return null;
  return time - data.updatedAt < DEVICE_TTL_MS ? data.deviceToken : null;
}

async function pageOf(store, path, cursor, pageSize) {
  return store.list(path, { orderByName: true, ...(cursor === null ? {} : { startAfter: cursor }), limit: pageSize });
}

// Full pass over the registry. The cursor is the last document of a page and
// moves only after that page was sent: a crash resends at most one page, and
// apns-collapse-id keeps the phone from showing the duplicate.
async function devicesPass(context, run) {
  const { store, pageSize, now } = context;
  let cursor = run.claim.cursor;
  while (true) {
    const rows = await pageOf(store, 'devices', cursor, pageSize);
    const time = now();
    const tokens = [];
    for (const { data } of rows) {
      const token = liveToken(data, time);
      if (token === null || run.seen.has(token)) continue;
      run.seen.add(token);
      tokens.push(token);
    }
    const page = await sendPage(tokens, context);
    run.results += tokens.length;
    run.retryable += page.retryable.length;
    const exhausted = rows.length < pageSize;
    cursor = exhausted ? null : rows[rows.length - 1].id;
    const { stop, claim } = await checkpoint(context, run, page, { cursor, exhausted, retriesPass: false });
    run.claim = claim;
    if (stop) return;
  }
}

// After a complete pass only the tokens that answered retryably are sent
// again. Documents from an earlier pass of the same revision are skipped and
// left to the TTL: their attempts belong to a claim that was overwritten.
async function retriesPass(context, run) {
  const { store, revision, pageSize } = context;
  let cursor = run.claim.cursor;
  while (true) {
    const rows = await pageOf(store, retriesPath(revision), cursor, pageSize);
    const due = rows.filter(({ id, data }) => data?.claimedAt === run.pass && data.token === id);
    const tokens = due.filter(({ id }) => HEX.test(id)).map(({ id }) => id);
    const page = await sendPage(tokens, context);
    for (const { id } of due) if (!HEX.test(id)) { page.resolved.push(id); page.failed += 1; }
    run.results += tokens.length;
    run.retryable += page.retryable.length;
    const exhausted = rows.length < pageSize;
    cursor = exhausted ? null : rows[rows.length - 1].id;
    const { stop, claim } = await checkpoint(context, run, page, { cursor, exhausted, retriesPass: true });
    run.claim = claim;
    if (stop) return;
  }
}

export async function broadcastRevision({ store, registry, dispatcher, revision, owner = randomUUID(), concurrency = 16, pageSize = 200, leaseMs = 120_000, deadlineAt = Infinity, isCancelled = () => false, now = Date.now, log = () => {} }) {
  if (!dispatcher) throw new ServiceError('push_not_configured');
  const context = { store, registry, dispatcher, revision, owner, concurrency, pageSize, leaseMs, deadlineAt, isCancelled, now };
  const claimed = await claimRevision(context);
  const summary = (claim, extra) => ({ event: 'push_batch', revision, accepted: claim.accepted, failed: claim.failed, unregistered: claim.unregistered, retryPending: claim.retryPending, attempts: claim.attempts, state: claim.state, ...extra });
  if (claimed.skipped) return outcome(claimed.claim, { skipped: claimed.skipped });
  if (claimed.exhausted) {
    log(summary(claimed.claim, { severity: 'WARNING', exhausted: true }));
    return outcome(claimed.claim, { exhausted: true });
  }
  const run = { claim: claimed.claim, pass: claimed.claim.claimedAt, seen: new Set(), results: 0, retryable: 0 };
  let keepLease = false;
  try {
    if (run.claim.passComplete) await retriesPass(context, run);
    else await devicesPass(context, run);
  } catch (error) {
    // A lost lease is not ours to release; rejected credentials keep the
    // lease so the pass resumes, rather than restarts, once the key rotates.
    keepLease = error instanceof ServiceError && FATAL.has(error.code);
    if (error instanceof ServiceError && error.code === 'apns_credentials_rejected') {
      try { run.claim = (await refundAttempt(context, run.pass)) ?? run.claim; } catch { /* The attempt stays charged; the log line says so. */ }
    }
    throw error;
  } finally {
    if (!keepLease) await releaseClaim(context).catch(() => {});
    log(summary(run.claim));
  }
  return outcome(run.claim);
}
