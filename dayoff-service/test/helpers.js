import { generateKeyPairSync } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMemoryStore } from '../src/store.js';
export const CAP_ID = 'dgpa.gov.tw_workSchlClos_20260822141104_i_6403700_001';
export const CAP_URL = `https://alerts.ncdr.nat.gov.tw/Capstorage/DGPA/2026/workschoolclose_cap/${CAP_ID}.cap`;
export const NOW = Date.parse('2026-09-15T12:30:00Z');
export const cap = await readFile(new URL('./fixtures/afternoon.cap', import.meta.url), 'utf8');
export const atom = (entries = [{ id: CAP_ID, url: CAP_URL }], updated = '2026-08-24T18:29:00+08:00') => `<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><id>https://alerts.ncdr.nat.gov.tw/RSS.aspx</id><title>NCDR_CAP-即時防災資訊</title>${updated ? `<updated>${updated}</updated>` : ''}${entries.map(({ id, url }) => `<entry><id>${id}</id><updated>2026-08-22T14:11:04+08:00</updated><link rel="alternate" href="${url}" /></entry>`).join('')}</feed>`;
export const xmlResponse = (value) => new Response(value, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
export const jsonResponse = (value) => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
// One page of NCDR's history search, in the site's own envelope and Taipei
// local timestamps without an offset, as the real API answers.
export const HISTORY_URL = 'https://alerts.ncdr.nat.gov.tw/server/v1/Alerts/Search/history';
export const historyRow = (overrides = {}) => ({
  alertPk: 2272388, infoPk: 20031466, eventName: '停班停課', msgType: 'Alert', severity: 'Extreme', headline: '停班課通知',
  description: '[停班停課通知]高雄市茂林區:明天停止上班、停止上課。', countyName: '高雄市茂林區', org: '行政院人事行政總處', code: '',
  identifier: CAP_ID, sentDate: '2026-08-22T14:11:04', effective: '2026-08-22T14:10:00', expires: '2026-09-16T00:00:00',
  filePath: `DGPA/2026/workschoolclose_cap/${CAP_ID}.cap`, ...overrides
});
export const historyPage = (rows = [historyRow()], total = rows.length) => ({ data: rows, code: 200, status: true, message: 'OK', total });
export const memoryStore = () => createMemoryStore();
// An ephemeral P-256 key written to a temp file, since the Job reads the
// .p8 from APNS_PRIVATE_KEY_PATH like the deployed secret mount.
export async function apnsEnv(t) {
  const directory = await mkdtemp(join(tmpdir(), 'dayoff-job-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'AuthKey.p8');
  await writeFile(path, generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  return { APNS_TEAM_ID: 'TEAM123456', APNS_KEY_ID: 'KEY1234567', APNS_PRIVATE_KEY_PATH: path, APNS_TOPIC: 'com.example.RainyClock', APNS_PRODUCTION: 'false' };
}
