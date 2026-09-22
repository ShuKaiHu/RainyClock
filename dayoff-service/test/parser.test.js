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
