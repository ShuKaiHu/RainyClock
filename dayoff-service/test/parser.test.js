import test from 'node:test';
import assert from 'node:assert/strict';
import { parseAtom, parseCAP, isoTimestamp, officialCapURL, LIMITS } from '../src/parser.js';
import { cap, atom, CAP_ID, CAP_URL } from './helpers.js';

test('real DGPA CAP retains prose, independent work/school data and district geocode', () => {
  const notice = parseCAP(cap, CAP_ID);
  assert.deepEqual(notice, { id: CAP_ID, sentAt: '2026-08-22T06:11:04.000Z', description: '[停班停課通知]高雄市桃源區:今天下午已達停止上班及上課標準。行政院人事行政總處。如有任何問題請撥1999(市內直撥)。', severity: 'Extreme', msgType: 'Alert', status: 'Actual', geocodes: ['6403700'], references: [] });
  assert.equal('targetDate' in notice, false); // The iOS decision engine resolves this from prose.
});

test('CAP prefixed namespaces, CDATA, multiple geocodes and references are parsed', () => {
  const source = cap.replace('<alert ', '<cap:alert xmlns:cap="urn:oasis:names:tc:emergency:cap:1.2" ').replace('</alert>', '</cap:alert>')
    .replace('<msgType>Alert</msgType>', '<msgType>Update</msgType>')
    .replace('<source />', `<references>http://www.dgpa.gov.tw,${CAP_ID},2026-08-22T14:11:04+08:00</references>`)
    .replace('<description>', '<description><![CDATA[').replace('</description>', ']]></description>')
    .replace('</area>', '<geocode><valueName>Taiwan_Geocode_103</valueName><value>64</value></geocode></area>');
  const result = parseCAP(source);
  assert.equal(result.msgType, 'Update');
  assert.deepEqual(result.references, [CAP_ID]);
  assert.deepEqual(result.geocodes, ['64', '6403700']);
  assert.match(result.description, /今天下午/);
});

test('Cancel can contain only a reference and must not become a positive notice', () => {
  const source = cap.replace(/<info>[\s\S]*<\/info>/, '').replace('<msgType>Alert</msgType>', '<msgType>Cancel</msgType>')
    .replace('<source />', `<references>http://www.dgpa.gov.tw,${CAP_ID},2026-08-22T14:11:04+08:00</references>`);
  const result = parseCAP(source);
  assert.equal(result.description, '');
  assert.deepEqual(result.geocodes, []);
  assert.equal(result.msgType, 'Cancel');
});

test('Atom metadata preserves old update time; empty official feed is valid', () => {
  assert.deepEqual(parseAtom(atom()), { sourceUpdatedAt: '2026-08-24T10:29:00.000Z', entries: [{ id: CAP_ID, updatedAt: '2026-08-22T06:11:04.000Z', url: CAP_URL }] });
  assert.deepEqual(parseAtom(atom([], null)), { sourceUpdatedAt: null, entries: [] });
  assert.throws(() => parseAtom(atom(undefined, null)), /invalid_source_time/);
});

test('dates require timezone and reject impossible or ambiguous times', () => {
  for (const value of ['2026-02-30T12:00:00Z', '2026-09-15T24:00:00Z', '2026-13-01T00:00:00Z', '2026-09-15T12:00:00', '2026/9/15 下午 12:00:00', '2026-09-15T12:00:00+14:01']) assert.throws(() => isoTimestamp(value));
  assert.equal(isoTimestamp('2024-02-29T12:00:00+08:00'), '2024-02-29T04:00:00.000Z');
});

test('reject HTML, malformed XML, DTD/entities, wrong namespace and deep documents', () => {
  for (const value of ['<html><body>Access denied</body></html>', atom().replace('</feed>', ''), '<!DOCTYPE feed [<!ENTITY bad "test">]>' + atom(), atom().replace('http://www.w3.org/2005/Atom', 'https://attacker.example/atom'), atom().replace('</feed>', '<x>'.repeat(40) + '</x>'.repeat(40) + '</feed>')]) assert.throws(() => parseAtom(value));
  assert.throws(() => parseCAP(cap.replace(CAP_ID, 'wrong')));
  assert.throws(() => parseCAP(cap.replace('<status>Actual</status>', '<status>Unknown</status>')));
  assert.throws(() => parseCAP(cap.replace('http://www.dgpa.gov.tw', 'http://attacker.example')));
});

test('CAP links reject off-host URLs, redirect destinations, credentials, arbitrary paths and queries', () => {
  for (const value of ['http://' + CAP_URL.slice(8), CAP_URL.replace('alerts.ncdr.nat.gov.tw', '127.0.0.1'), CAP_URL.replace('alerts.ncdr.nat.gov.tw', 'alerts.ncdr.nat.gov.tw.evil.example'), CAP_URL.replace('https://', 'https://user:secret@'), CAP_URL + '?apikey=secret', CAP_URL + '#fragment', 'https://alerts.ncdr.nat.gov.tw/admin', 'file:///etc/passwd']) assert.throws(() => officialCapURL(value));
  assert.equal(officialCapURL(CAP_URL), CAP_URL);
});

test('oversized feeds, too many entries and duplicate identities fail closed', () => {
  assert.throws(() => parseAtom('x'.repeat(LIMITS.feedBytes + 1)), /source_too_large/);
  assert.throws(() => parseAtom(atom(Array(2).fill({ id: CAP_ID, url: CAP_URL }))), /invalid_source_identity/);
  assert.throws(() => parseAtom(atom(Array(501).fill({ id: CAP_ID, url: CAP_URL }))), /too_many_notices/);
});

test('a WarningMessage document is the source refusing the request, not malformed XML', () => {
  assert.throws(() => parseAtom('<WarningMessage><Warning>請先登入會員。</Warning></WarningMessage>'), /source_login_required/);
  assert.throws(() => parseAtom('<html><body>denied</body></html>'), /invalid_source_xml/);
});

test('history page: DGPA rows become feed entries with official CAP locations and UTC times', async () => {
  const { parseHistoryPage, taipeiTimestamp } = await import('../src/parser.js');
  const { historyPage, historyRow } = await import('./helpers.js');
  const page = parseHistoryPage(historyPage([historyRow()], 23));
  assert.equal(page.total, 23);
  assert.equal(page.pageSize, 10);
  assert.deepEqual(page.entries, [{ id: CAP_ID, updatedAt: '2026-08-22T06:11:04.000Z', url: CAP_URL }], 'expires is not carried: it ends the announcement day, not the closure');
  assert.equal(taipeiTimestamp('2026-08-24T18:21:42'), '2026-08-24T10:21:42.000Z');
  assert.equal(taipeiTimestamp('2026-08-24T18:21:42+08:00'), '2026-08-24T10:21:42.000Z');
  assert.equal(taipeiTimestamp('2026-08-24T10:21:42Z'), '2026-08-24T10:21:42.000Z');
  assert.equal(parseHistoryPage(historyPage([historyRow({ expires: null })])).entries.length, 1);
  assert.throws(() => parseHistoryPage(historyPage([historyRow({ expires: 'soon' })])), /invalid_source_time/);
  assert.deepEqual(parseHistoryPage(historyPage([], 0)).entries, []);
});

test('history page: the login wall, foreign identifiers, unsafe paths and oversized totals are refused', async () => {
  const { parseHistoryPage } = await import('../src/parser.js');
  const { historyPage, historyRow } = await import('./helpers.js');
  assert.throws(() => parseHistoryPage({ Warning: '請先登入會員。' }), /source_login_required/);
  assert.throws(() => parseHistoryPage({ data: [], code: 200, status: false, total: 0 }), /invalid_source_json/);
  assert.throws(() => parseHistoryPage([]), /invalid_source_json/);
  assert.throws(() => parseHistoryPage(historyPage([historyRow({ identifier: 'WRA_ReservoirWarn_20261006171840_0000', filePath: 'WRA/2026/ReservoirDis/WRA_ReservoirWarn_20261006171840_0000.cap' })])), /invalid_source_identity/);
  assert.throws(() => parseHistoryPage(historyPage([historyRow({ filePath: `../DGPA/2026/workschoolclose_cap/${CAP_ID}.cap` })])), /unsafe_source_link/);
  assert.throws(() => parseHistoryPage(historyPage([historyRow({ filePath: 'DGPA/2026/workschoolclose_cap/dgpa.gov.tw_workSchlClos_20260822141104_i_6403700_002.cap' })])), /unsafe_source_link/, 'the path must name the row\'s own alert');
  assert.throws(() => parseHistoryPage(historyPage([historyRow({ sentDate: 'yesterday' })])), /invalid_source_time/);
  assert.throws(() => parseHistoryPage(historyPage([historyRow()], LIMITS.entries + 1)), /too_many_notices/);
  assert.throws(() => parseHistoryPage(historyPage(Array.from({ length: 11 }, () => historyRow()), 11)), /too_many_notices/);
});
