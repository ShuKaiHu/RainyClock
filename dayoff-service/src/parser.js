import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { ServiceError } from './errors.js';

export const LIMITS = Object.freeze({ feedBytes: 1_048_576, capBytes: 262_144, entries: 500, depth: 32, text: 16_384 });
const ATOM = 'http://www.w3.org/2005/Atom';
const CAPS = ['urn:oasis:names:tc:emergency:cap:1.1', 'urn:oasis:names:tc:emergency:cap:1.2'];
const parser = new XMLParser({
  ignoreAttributes: false, removeNSPrefix: true, parseTagValue: false,
  parseAttributeValue: false, trimValues: true, processEntities: true,
});
const many = (value) => value == null ? [] : Array.isArray(value) ? value : [value];
const text = (value) => typeof value === 'string' ? value : typeof value?.['#text'] === 'string' ? value['#text'] : '';
function required(value, maximum = LIMITS.text) {
  const result = text(value).trim();
  if (!result || result.length > maximum) throw new ServiceError('invalid_source_fields');
  return result;
}

export function isoTimestamp(value) {
  const raw = required(value, 40);
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$/.exec(raw);
  if (!match) throw new ServiceError('invalid_source_time');
  const [, year, month, day, hour, minute, second, , offset] = match;
  const days = new Date(Date.UTC(Number(year), Number(month), 0)).getUTCDate();
  if (+year < 2000 || +month < 1 || +month > 12 || +day < 1 || +day > days || +hour > 23 || +minute > 59 || +second > 59 ||
      (offset !== 'Z' && (+offset.slice(1, 3) > 14 || +offset.slice(4) > 59 || (+offset.slice(1, 3) === 14 && +offset.slice(4) !== 0)))) {
    throw new ServiceError('invalid_source_time');
  }
  const millis = Date.parse(raw);
  if (!Number.isFinite(millis)) throw new ServiceError('invalid_source_time');
  return new Date(millis).toISOString();
}

function xmlRoot(xml, expected, namespaces, maximum) {
  if (typeof xml !== 'string' || Buffer.byteLength(xml) > maximum) throw new ServiceError('source_too_large');
  if (/<!\s*(?:DOCTYPE|ENTITY)\b/i.test(xml)) throw new ServiceError('unsafe_source_xml');
  const stripped = xml.replace(/^\uFEFF/, '').replace(/<\?[\s\S]*?\?>|<!--[\s\S]*?-->/g, '').trim();
  const opening = /^<((?:[\w.-]+:)?[\w.-]+)\b([^>]*)>/.exec(stripped);
  if (!opening || opening[1].split(':').at(-1) !== expected) throw new ServiceError('invalid_source_xml');
  const prefix = opening[1].includes(':') ? opening[1].split(':')[0] : '';
  const namespacePattern = new RegExp(`\\bxmlns${prefix ? `:${prefix}` : ''}\\s*=\\s*(["'])(.*?)\\1`);
  const namespace = namespacePattern.exec(opening[2])?.[2];
  if (!namespaces.includes(namespace)) throw new ServiceError('invalid_source_namespace');
  let depth = 0;
  for (const token of stripped.replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '').matchAll(/<([^>]+)>/g)) {
    if (token[1].startsWith('/')) depth -= 1;
    else if (!token[1].startsWith('!') && !token[1].endsWith('/')) depth += 1;
    if (depth > LIMITS.depth) throw new ServiceError('source_too_deep');
  }
  if (XMLValidator.validate(xml) !== true) throw new ServiceError('invalid_source_xml');
  try {
    const result = parser.parse(xml)?.[expected];
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
    return result;
  } catch { throw new ServiceError('invalid_source_xml'); }
}

// Only HTTPS CAP files served by the documented NCDR DGPA archive are permitted.
// No redirects, credentials, ports, query strings, fragments, or arbitrary source URLs.
export function officialCapURL(raw) {
  let url;
  try { url = new URL(required(raw, 2048)); } catch { throw new ServiceError('unsafe_source_link'); }
  if (url.protocol !== 'https:' || url.hostname !== 'alerts.ncdr.nat.gov.tw' || url.port || url.username || url.password || url.search || url.hash ||
      !/^\/Capstorage\/DGPA\/\d{4}\/workschoolclose_cap\/dgpa\.gov\.tw_workSchlClos_[A-Za-z0-9_-]+\.cap$/.test(url.pathname)) {
    throw new ServiceError('unsafe_source_link');
  }
  return url.href;
}

export function parseAtom(xml) {
  const feed = xmlRoot(xml, 'feed', [ATOM], LIMITS.feedBytes);
  required(feed.id, 2048);
  required(feed.title, 512);
  const sourceUpdatedAt = feed.updated == null ? null : isoTimestamp(feed.updated);
  const entries = many(feed.entry);
  if (entries.length > LIMITS.entries) throw new ServiceError('too_many_notices');
  if (entries.length && !sourceUpdatedAt) throw new ServiceError('invalid_source_time');
  const seen = new Set();
  return {
    sourceUpdatedAt,
    entries: entries.map((entry) => {
      const id = required(entry.id, 256);
      if (!/^dgpa\.gov\.tw_workSchlClos_[A-Za-z0-9_-]+$/.test(id) || seen.has(id)) throw new ServiceError('invalid_source_identity');
      seen.add(id);
      const updatedAt = isoTimestamp(entry.updated);
      const links = many(entry.link).filter((link) => !link['@_rel'] || link['@_rel'] === 'alternate');
      if (links.length !== 1) throw new ServiceError('invalid_source_link');
      return { id, updatedAt, url: officialCapURL(links[0]['@_href']) };
    }),
  };
}

export function parseCAP(xml, expectedID) {
  const alert = xmlRoot(xml, 'alert', CAPS, LIMITS.capBytes);
  const id = required(alert.identifier, 256);
  if (!/^dgpa\.gov\.tw_workSchlClos_[A-Za-z0-9_-]+$/.test(id) || (expectedID && id !== expectedID)) throw new ServiceError('invalid_source_identity');
  if (!/^https?:\/\/(?:www\.)?dgpa\.gov\.tw\/?$/.test(required(alert.sender, 128))) throw new ServiceError('invalid_source_sender');
  const sentAt = isoTimestamp(alert.sent);
  const status = required(alert.status, 32);
  const msgType = required(alert.msgType, 32);
  if (!['Actual', 'Exercise', 'System', 'Test', 'Draft'].includes(status) || !['Alert', 'Update', 'Cancel'].includes(msgType) || text(alert.scope) !== 'Public') {
    throw new ServiceError('invalid_source_fields');
  }
  const infos = many(alert.info);
  const chinese = infos.filter((info) => ['zh-TW', 'zh-tw', 'zh-Hant', ''].includes(text(info.language)));
  if (chinese.length > 1 || (chinese.length === 0 && msgType !== 'Cancel')) throw new ServiceError('invalid_source_fields');
  const info = chinese[0];
  let description = '', severity = '', geocodes = [];
  if (info) {
    if (text(info.event) !== '停班停課' || text(info.senderName) !== '行政院人事行政總處') throw new ServiceError('invalid_source_sender');
    description = required(info.description);
    severity = required(info.severity, 32);
    if (!['Extreme', 'Severe', 'Moderate', 'Minor', 'Unknown'].includes(severity)) throw new ServiceError('invalid_source_fields');
    // These fields describe CAP delivery validity, not the actual suspension date.
    if (info.effective != null) isoTimestamp(info.effective);
    if (info.expires != null) isoTimestamp(info.expires);
    const codes = many(info.area).flatMap((area) => many(area.geocode))
      .filter((item) => text(item.valueName) === 'Taiwan_Geocode_103').map((item) => required(item.value, 16));
    if (codes.length > 500 || codes.some((code) => !/^\d{2,11}$/.test(code))) throw new ServiceError('invalid_source_geocodes');
    geocodes = [...new Set(codes)].sort();
  }
  const references = text(alert.references).trim().split(/\s+/).filter(Boolean).map((reference) => {
    const components = reference.split(',');
    if (components.length !== 3 || !/^dgpa\.gov\.tw_workSchlClos_[A-Za-z0-9_-]+$/.test(components[1])) throw new ServiceError('invalid_source_references');
    isoTimestamp(components[2]);
    return components[1];
  });
  if (references.length > LIMITS.entries) throw new ServiceError('invalid_source_references');
  return { id, sentAt, description, severity, msgType, status, geocodes, references: [...new Set(references)] };
}
