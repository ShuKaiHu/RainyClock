import test from 'node:test';
import assert from 'node:assert/strict';
import { SuspensionService } from '../src/service.js';
import { cap, atom, CAP_ID, CAP_URL, NOW, xmlResponse, memoryStore } from './helpers.js';

test('one shared source check serves all clients and preserves old source dates', async () => {
  const store = memoryStore();
  const calls = [], revisions = [];
  const service = new SuspensionService({ apiKey: 'private-key', store, now: () => NOW, onRevision: async (revision) => revisions.push(revision), fetchImpl: async (url, options) => {
    calls.push({ url, options });
    return xmlResponse(url === CAP_URL ? cap : atom());
  } });
  const first = service.refresh();
  assert.equal(service.refresh(), first);
  assert.equal(await first, true);
  const snapshot = service.getSnapshot();
  assert.equal(snapshot.checkedAt, '2026-09-15T12:30:00.000Z');
  assert.equal(snapshot.sourceUpdatedAt, '2026-08-24T10:29:00.000Z');
  assert.match(snapshot.notices[0].description, /今天下午/);
  for (let i = 0; i < 20; i += 1) assert.equal(service.getSnapshot(), snapshot);
  assert.equal(calls.length, 2);
  assert.equal(new URL(calls[0].url).pathname, '/webapi/RssAtomFeed.ashx');
  assert.equal(new URL(calls[0].url).searchParams.get('apikey'), 'private-key');
  assert.equal(calls[0].options.redirect, 'error');
  assert.equal(calls[1].url.includes('private-key'), false);
  await new Promise(setImmediate);
  assert.equal(revisions.length, 1);
  assert.equal(JSON.stringify([await store.get('state/current'), await store.list('caps')]).includes('private-key'), false);
});

test('new checkedAt does not produce pushes when notices are unchanged; CAP is cached', async () => {
  const store = memoryStore();
  let time = NOW, calls = 0, pushes = 0;
  const service = new SuspensionService({ apiKey: 'key', store, now: () => time, onRevision: async () => { pushes += 1; }, fetchImpl: async (url) => { calls += 1; return xmlResponse(url === CAP_URL ? cap : atom()); } });
  await service.refresh();
  await new Promise(setImmediate);
  const oldRevision = service.getSnapshot().revision;
  time += 300_001;
  await service.refresh();
  await new Promise(setImmediate);
  assert.equal(service.getSnapshot().revision, oldRevision);
  assert.equal(pushes, 1);
  assert.equal(calls, 3);
});

test('successful empty feed is distinct from HTTP or HTML failure', async () => {
  const store = memoryStore();
  let time = NOW, failed = false;
  const service = new SuspensionService({ apiKey: 'key', store, now: () => time, fetchImpl: async () => failed ? new Response('<html>denied</html>', { headers: { 'Content-Type': 'text/html' } }) : xmlResponse(atom([])) });
  assert.equal(await service.refresh(), true);
  assert.deepEqual(service.getSnapshot().notices, []);
  failed = true;
  time += 300_001;
  assert.equal(await service.refresh(), false);
  assert.equal(service.health().errorCode, 'invalid_source_content_type');
  assert.throws(() => service.getSnapshot(), /invalid_source_content_type/);
});

test('429 respects Retry-After; no calls during backoff; errors cannot leak key', async () => {
  const store = memoryStore();
  let time = NOW, calls = 0;
  const logs = [];
  const service = new SuspensionService({ apiKey: 'super-secret-value', store, now: () => time, log: (event) => logs.push(event), fetchImpl: async () => { calls += 1; return new Response('No', { status: 429, headers: { 'Retry-After': '120' } }); } });
  await service.refresh();
  assert.equal(service.nextAttemptAt, time + 120_000);
  assert.equal(await service.refresh(), false);
  assert.equal(calls, 1);
  time += 120_001;
  service.fetchImpl = async () => { throw new Error('failed URL with super-secret-value'); };
  await service.refresh();
  assert.equal(service.health().errorCode, 'upstream_unavailable');
  assert.equal(JSON.stringify(logs).includes('super-secret-value'), false);
});

test('missing key is explicitly not configured and performs no network work', async () => {
  const service = new SuspensionService({ store: memoryStore(), fetchImpl: async () => { throw new Error('must never run'); } });
  assert.equal(await service.refresh(), false);
  assert.equal(service.health().configured, false);
  assert.equal(service.health().errorCode, 'not_configured');
  assert.throws(() => service.getSnapshot(), /not_configured/);
  service.start();
  await service.stop();
});

test('restart revalidates feed before serving and reuses validated persisted CAP', async () => {
  const store = memoryStore();
  const revisions = [];
  const first = new SuspensionService({ apiKey: 'key', store, now: () => NOW, fetchImpl: async (url) => xmlResponse(url === CAP_URL ? cap : atom()) });
  await first.refresh();
  let calls = 0;
  const restored = new SuspensionService({ apiKey: 'key', store, now: () => NOW, onRevision: async (revision) => revisions.push(revision), fetchImpl: async (url) => { calls += 1; assert.notEqual(url, CAP_URL); return xmlResponse(atom()); } });
  await restored.initialize();
  assert.throws(() => restored.getSnapshot(), /not_yet_checked/);
  await restored.refresh();
  await new Promise(setImmediate);
  assert.equal(calls, 1);
  assert.equal(restored.getSnapshot().notices.length, 1);
  assert.equal(restored.getSnapshot().revision, first.getSnapshot().revision);
  assert.deepEqual(revisions, []);
});

test('corrupt persisted data is ignored and never becomes a ready snapshot', async () => {
  const store = memoryStore();
  await store.set(`caps/${CAP_ID}`, { id: 'bad' });
  await store.set('state/current', { schemaVersion: 2 });
  let calls = 0;
  const service = new SuspensionService({ apiKey: 'key', store, now: () => NOW, fetchImpl: async (url) => { calls += 1; return xmlResponse(url === CAP_URL ? cap : atom()); } });
  await service.initialize();
  // A document of another schema must not seed the compare-and-set.
  assert.equal(service.previousRevision, null);
  assert.throws(() => service.getSnapshot());
  assert.equal(await service.refresh(), true);
  assert.equal(calls, 2);
  assert.equal(service.getSnapshot().notices.length, 1);
  // The corrupt CAP document was refetched and overwritten, not served.
  assert.equal((await store.get(`caps/${CAP_ID}`)).xml, cap);
});

test('cache age is enforced even after a past successful check', async () => {
  let time = NOW;
  const service = new SuspensionService({ apiKey: 'key', store: memoryStore(), now: () => time, fetchImpl: async () => xmlResponse(atom([])) });
  await service.refresh();
  time += 900_001;
  assert.equal(service.health().errorCode, 'stale_cache');
  assert.throws(() => service.getSnapshot(), /stale_cache/);
});

test('partial upstream CAP failures and future-dated feeds reject the whole refresh', async () => {
  const service = new SuspensionService({ apiKey: 'key', store: memoryStore(), now: () => NOW, fetchImpl: async (url) => url === CAP_URL ? new Response('no', { status: 500 }) : xmlResponse(atom()) });
  await service.refresh();
  assert.equal(service.snapshot, null);
  assert.throws(() => service.getSnapshot());
  service.nextAttemptAt = 0;
  service.fetchImpl = async () => xmlResponse(atom([], '2099-09-15T00:00:00Z'));
  await service.refresh();
  assert.equal(service.health().errorCode, 'source_time_in_future');
});

test('request timeout cancels the request instead of hanging a poller', async () => {
  const service = new SuspensionService({ apiKey: 'key', store: memoryStore(), now: () => NOW, requestTimeoutMs: 20,
    fetchImpl: (_url, { signal }) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })) });
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    assert.equal(await service.refresh(), false);
    assert.equal(service.health().errorCode, 'upstream_timeout');
  } finally { clearTimeout(keepAlive); }
});

test('response streaming is bounded even without Content-Length', async () => {
  const service = new SuspensionService({ apiKey: 'key', store: memoryStore(), now: () => NOW, fetchImpl: async () => xmlResponse('x'.repeat(1_048_577)) });
  await service.refresh();
  assert.equal(service.health().errorCode, 'source_too_large');
});

test('the source is explicit: open-data fetches the data.gov.tw URL without a key, member without a key is not configured', async () => {
  const urls = [];
  const store = memoryStore();
  const open = new SuspensionService({ source: 'open-data', store, now: () => NOW, fetchImpl: async (url) => { urls.push(url); return xmlResponse(url === CAP_URL ? cap : atom()); } });
  assert.equal(open.health().configured, true);
  assert.equal(open.health().errorCode, 'not_yet_checked');
  assert.equal(await open.refresh(), true);
  assert.ok(urls[0].startsWith('https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx?AlertType=33'), urls[0]);
  assert.equal(urls.some((url) => url.includes('apikey')), false);
  assert.equal(open.getSnapshot().revision.length, 64);
  assert.equal((await store.get('state/current')).source, 'open-data');

  const memberUrls = [];
  const member = new SuspensionService({ source: 'member', apiKey: 'k', store: memoryStore(), now: () => NOW, fetchImpl: async (url) => { memberUrls.push(url); return xmlResponse(url === CAP_URL ? cap : atom()); } });
  await member.refresh();
  assert.ok(memberUrls[0].startsWith('https://alerts.ncdr.nat.gov.tw/webapi/RssAtomFeed.ashx?AlertType=33&apikey=k'), memberUrls[0]);

  const unconfigured = new SuspensionService({ store: memoryStore(), now: () => NOW, fetchImpl: async () => { throw new Error('must not fetch'); } });
  assert.equal(unconfigured.health().configured, false);
  assert.equal(unconfigured.health().errorCode, 'not_configured');
  assert.equal(await unconfigured.refresh(), false);

  assert.throws(() => new SuspensionService({ source: 'open-data', apiKey: 'k', store: memoryStore() }), /invalid_configuration/);
  assert.throws(() => new SuspensionService({ source: 'html', store: memoryStore() }), /invalid_configuration/);
});

test('history source: three day windows, paged, an evening alert kept past its expires, CAPs fetched as before', async () => {
  const { HISTORY_URL, historyPage, historyRow, jsonResponse } = await import('./helpers.js');
  const urls = [];
  const store = memoryStore();
  // NOW is 2026-09-15T12:30Z = 20:30 Asia/Taipei on 9/15: the live set is what was sent on 9/14 and 9/15.
  const secondID = 'dgpa.gov.tw_workSchlClos_20260915180000_i_6403700_002';
  const second = historyRow({ identifier: secondID, filePath: `DGPA/2026/workschoolclose_cap/${secondID}.cap`, sentDate: '2026-09-15T18:00:00', expires: '2026-09-17T00:00:00' });
  // Sent on 9/14 for 9/15, with NCDR's expires at the end of the announcement day: still live on 9/15 evening.
  const eveningID = 'dgpa.gov.tw_workSchlClos_20260914180000_i_6403700_003';
  const evening = historyRow({ identifier: eveningID, filePath: `DGPA/2026/workschoolclose_cap/${eveningID}.cap`, sentDate: '2026-09-14T18:00:00', expires: '2026-09-15T00:00:00' });
  const service = new SuspensionService({ source: 'history', historyGapMs: 0, store, now: () => NOW, fetchImpl: async (url) => {
    urls.push(url);
    if (url.startsWith(HISTORY_URL)) {
      const query = new URL(url).searchParams;
      if (query.get('effective') === '2026-09-13') return jsonResponse(historyPage([], 0));
      if (query.get('effective') === '2026-09-14') return jsonResponse(historyPage([evening], 1));
      // Eleven alerts sent on 9/15: page 1 holds ten (the fixture alert ten times is deduplicated), page 2 the second.
      return jsonResponse(query.get('page') === '1' ? historyPage(Array.from({ length: 10 }, () => historyRow()), 11) : historyPage([second], 11));
    }
    const id = [secondID, eveningID].find((candidate) => url.endsWith(`${candidate}.cap`));
    return xmlResponse(id ? cap.replaceAll(CAP_ID, id) : cap);
  } });
  assert.equal(service.health().configured, true);
  assert.equal(await service.refresh(), true);
  const index = urls.filter((url) => url.startsWith(HISTORY_URL)).map((url) => { const q = new URL(url).searchParams; return `${q.get('alertTypeId')}:${q.get('sentdate')}>${q.get('effective')}#${q.get('page')}`; });
  assert.deepEqual(index, ['33:2026-09-12>2026-09-13#1', '33:2026-09-13>2026-09-14#1', '33:2026-09-14>2026-09-15#1', '33:2026-09-14>2026-09-15#2']);
  assert.equal(urls.some((url) => url.includes('apikey')), false);
  // All three alerts were fetched from the archive, the evening one included.
  const capFetches = urls.filter((url) => url.includes('/Capstorage/'));
  assert.deepEqual(capFetches.sort(), [CAP_URL, `https://alerts.ncdr.nat.gov.tw/Capstorage/DGPA/2026/workschoolclose_cap/${eveningID}.cap`, `https://alerts.ncdr.nat.gov.tw/Capstorage/DGPA/2026/workschoolclose_cap/${secondID}.cap`]);
  const snapshot = service.getSnapshot();
  assert.equal(snapshot.sourceUpdatedAt, '2026-09-15T10:00:00.000Z', 'the newest live alert, in UTC');
  assert.deepEqual(snapshot.notices.map((notice) => notice.id).sort(), [CAP_ID, eveningID, secondID]);
  assert.equal((await store.get('state/current')).source, 'history');
});

test('history source: a second alert with its own CAP is a second notice, and the index is reused from cache', async () => {
  const { HISTORY_URL, historyPage, historyRow, jsonResponse } = await import('./helpers.js');
  const secondID = 'dgpa.gov.tw_workSchlClos_20260915180000_i_6403700_002';
  const secondCap = cap.replaceAll(CAP_ID, secondID);
  const second = historyRow({ identifier: secondID, filePath: `DGPA/2026/workschoolclose_cap/${secondID}.cap`, sentDate: '2026-09-15T18:00:00', expires: '2026-09-17T00:00:00' });
  let capCalls = 0;
  const service = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, fetchImpl: async (url) => {
    if (url.startsWith(HISTORY_URL)) return jsonResponse(new URL(url).searchParams.get('effective') === '2026-09-15' ? historyPage([historyRow(), second], 2) : historyPage([], 0));
    capCalls += 1;
    return xmlResponse(url.endsWith(`${secondID}.cap`) ? secondCap : cap);
  } });
  assert.equal(await service.refresh(), true);
  assert.deepEqual(service.getSnapshot().notices.map((notice) => notice.id).sort(), [CAP_ID, secondID]);
  assert.equal(capCalls, 2);
  service.nextAttemptAt = 0;
  assert.equal(await service.refresh(), true);
  assert.equal(capCalls, 2, 'unchanged sent times reuse the cached CAPs');
});

test('history source: the login wall and a throttled host are source failures with their own codes', async () => {
  const { HISTORY_URL, jsonResponse } = await import('./helpers.js');
  const logs = [];
  const wall = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, log: (event) => logs.push(event), fetchImpl: async () => jsonResponse({ Warning: '請先登入會員。' }) });
  assert.equal(await wall.refresh(), false);
  assert.equal(wall.health().errorCode, 'source_login_required');
  const throttled = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, fetchImpl: async () => new Response('<WarningMessage><Warning>限制存取間隔時間為3秒</Warning></WarningMessage>', { status: 429, headers: { 'Content-Type': 'application/xml', 'Retry-After': '3' } }) });
  assert.equal(await throttled.refresh(), false);
  assert.equal(throttled.health().errorCode, 'upstream_rate_limited');
  assert.ok(logs.some((event) => event.event === 'source_check_failed' && event.code === 'source_login_required'));
  assert.throws(() => new SuspensionService({ source: 'history', apiKey: 'k', store: memoryStore() }), /invalid_configuration/);
  void HISTORY_URL;
});

test('history source: the pause between requests is real and abortable', async () => {
  const { HISTORY_URL, historyPage, historyRow, jsonResponse } = await import('./helpers.js');
  const times = [];
  const start = Date.now();
  const service = new SuspensionService({ source: 'history', historyGapMs: 120, store: memoryStore(), now: () => NOW, fetchImpl: async (url) => {
    if (url.startsWith(HISTORY_URL)) { times.push(Date.now() - start); return jsonResponse(historyPage([historyRow()], 1)); }
    return xmlResponse(cap);
  } });
  assert.equal(await service.refresh(), true);
  assert.equal(times.length, 3, 'one page per day window');
  assert.ok(times[1] - times[0] >= 100 && times[2] - times[1] >= 100, `each index request after the first waited: ${times}`);
  const slow = new SuspensionService({ source: 'history', historyGapMs: 60_000, cycleTimeoutMs: 150, store: memoryStore(), now: () => NOW, fetchImpl: async () => jsonResponse(historyPage([historyRow()], 1)) });
  const started = Date.now();
  assert.equal(await slow.refresh(), false);
  assert.ok(Date.now() - started < 5_000, 'the cycle abort cuts the pause short');
  assert.equal(slow.health().errorCode, 'upstream_timeout');
});

test('history source: a 「明天停班」 sent the evening before is still served at 00:05 and 06:00 on the closure day', async () => {
  const { HISTORY_URL, historyPage, historyRow, jsonResponse } = await import('./helpers.js');
  // Sent 9/15 18:21 for 9/16; NCDR's expires is 9/16 00:00. Polled at 00:05 and 06:00 Asia/Taipei on 9/16.
  const row = historyRow({ sentDate: '2026-09-15T18:21:42', expires: '2026-09-16T00:00:00' });
  for (const at of ['2026-09-15T16:05:00Z', '2026-09-15T22:00:00Z']) {
    const service = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => Date.parse(at), fetchImpl: async (url) => {
      if (url.startsWith(HISTORY_URL)) return jsonResponse(new URL(url).searchParams.get('effective') === '2026-09-15' ? historyPage([row], 1) : historyPage([], 0));
      return xmlResponse(cap);
    } });
    assert.equal(await service.refresh(), true, at);
    assert.deepEqual(service.getSnapshot().notices.map((notice) => notice.id), [CAP_ID], at);
  }
});

test('history source: one 429 on a page is retried within the cycle; a persistent one backs the poll off', async () => {
  const { HISTORY_URL, historyPage, historyRow, jsonResponse } = await import('./helpers.js');
  let indexCalls = 0;
  const service = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, fetchImpl: async (url) => {
    if (url.startsWith(HISTORY_URL)) {
      indexCalls += 1;
      if (indexCalls === 2) return new Response('<WarningMessage><Warning>限制存取間隔時間為3秒</Warning></WarningMessage>', { status: 429, headers: { 'Content-Type': 'application/xml', 'Retry-After': '0' } });
      return jsonResponse(new URL(url).searchParams.get('effective') === '2026-09-15' ? historyPage([historyRow()], 1) : historyPage([], 0));
    }
    return xmlResponse(cap);
  } });
  assert.equal(await service.refresh(), true);
  assert.equal(indexCalls, 4, 'three windows plus one retry');
  assert.equal(service.getSnapshot().notices.length, 1);

  let calls = 0;
  const stuck = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, fetchImpl: async () => { calls += 1; return new Response('no', { status: 429, headers: { 'Retry-After': '0' } }); } });
  assert.equal(await stuck.refresh(), false);
  assert.equal(stuck.health().errorCode, 'upstream_rate_limited');
  assert.equal(calls, 3, 'the first page, retried twice, then the cycle fails');
});

test('history source: NCDR\'s XML login wall on the JSON endpoint is reported as source_login_required', async () => {
  const service = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, fetchImpl: async () => new Response('<WarningMessage><Warning>請先登入會員。</Warning></WarningMessage>', { headers: { 'Content-Type': 'application/xml; charset=utf-8' } }) });
  assert.equal(await service.refresh(), false);
  assert.equal(service.health().errorCode, 'source_login_required');
  const html = new SuspensionService({ source: 'history', historyGapMs: 0, store: memoryStore(), now: () => NOW, fetchImpl: async () => new Response('<html>maintenance</html>', { headers: { 'Content-Type': 'text/xml' } }) });
  assert.equal(await html.refresh(), false);
  assert.equal(html.health().errorCode, 'invalid_source_json');
});

test('a set that only lost notices updates the revision but wakes no phone; a notice coming back is news', async () => {
  const { HISTORY_URL, historyPage, historyRow, jsonResponse } = await import('./helpers.js');
  const store = memoryStore();
  const revisions = [];
  let rows = [historyRow()];
  const service = new SuspensionService({ source: 'history', historyGapMs: 0, store, now: () => NOW, onRevision: async (revision) => revisions.push(revision), fetchImpl: async (url) => {
    if (url.startsWith(HISTORY_URL)) return jsonResponse(new URL(url).searchParams.get('effective') === '2026-09-15' ? historyPage(rows, rows.length) : historyPage([], 0));
    return xmlResponse(cap);
  } });
  assert.equal(await service.refresh(), true);
  const first = service.getSnapshot().revision;
  assert.deepEqual(revisions, [first]);
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, first);

  rows = [];
  service.nextAttemptAt = 0;
  assert.equal(await service.refresh(), true);
  const emptied = service.getSnapshot().revision;
  assert.notEqual(emptied, first, 'readers see the smaller set');
  assert.deepEqual(revisions, [first], 'no broadcast for a set that only shrank');
  assert.equal((await store.get('state/current')).pendingBroadcastRevision, first, 'the earlier claim is left as it was');
  assert.ok(!(await store.get(`broadcasts/${emptied}`)), 'no claim for the shrunken set');

  rows = [historyRow()];
  service.nextAttemptAt = 0;
  assert.equal(await service.refresh(), true);
  assert.deepEqual(revisions, [first, first], 'the notice is back: that is news again');
});

