import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
export const CAP_ID = 'dgpa.gov.tw_workSchlClos_20260822141104_i_6403700_001';
export const CAP_URL = `https://alerts.ncdr.nat.gov.tw/Capstorage/DGPA/2026/workschoolclose_cap/${CAP_ID}.cap`;
export const NOW = Date.parse('2026-09-15T12:30:00Z');
export const cap = await readFile(new URL('./fixtures/afternoon.cap', import.meta.url), 'utf8');
export const atom = (entries = [{ id: CAP_ID, url: CAP_URL }], updated = '2026-08-24T18:29:00+08:00') => `<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><id>https://alerts.ncdr.nat.gov.tw/RSS.aspx</id><title>NCDR_CAP-即時防災資訊</title>${updated ? `<updated>${updated}</updated>` : ''}${entries.map(({ id, url }) => `<entry><id>${id}</id><updated>2026-08-22T14:11:04+08:00</updated><link rel="alternate" href="${url}" /></entry>`).join('')}</feed>`;
export const xmlResponse = (value) => new Response(value, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
export async function temporaryDirectory(t) {
  const path = await mkdtemp(join(tmpdir(), 'rainyclock-dayoff-test-'));
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}
