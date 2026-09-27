import { readFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { ServiceError } from './errors.js';
import { firestoreConfiguration, createStoreFromEnv, operatorAuthClient } from './runtime.js';
import { FIXTURE_PATH, fixtureAllowed, fixtureFeed } from './service.js';

// Operator CLI for the sandbox stack: writes the announcement the fixture
// source will serve, so a push can be made to happen on a phone on any day
// of the year. Modelled on weather-proxy/membership/maintenance-cli.js:
// validate everything, then act. Output is one JSON line and never a
// secret; the environment is the same one the Job reads, so the namespace
// gate here is the same gate that stops production from serving fixtures.
//
//   node src/fixture-cli.js set --county 新北市 --district 板橋區 [--when tomorrow] [--scope both] [--day-part full] [--geocode 65000]
//   node src/fixture-cli.js clear
//   node src/fixture-cli.js show
//
// Taiwan_Geocode_103 county codes. The district table the app ships carries
// names only, so a district-level notice defaults to its county's code
// unless --geocode gives the exact 7-digit one; the phone matches on the
// area text and only requires a well-formed code, so that is enough to
// exercise every path a real notice takes.
export const COUNTY_GEOCODES = Object.freeze({
  臺北市: '63000', 高雄市: '64000', 新北市: '65000', 臺中市: '66000', 臺南市: '67000', 桃園市: '68000',
  宜蘭縣: '10002', 新竹縣: '10004', 苗栗縣: '10005', 彰化縣: '10007', 南投縣: '10008', 雲林縣: '10009',
  嘉義縣: '10010', 屏東縣: '10013', 臺東縣: '10014', 花蓮縣: '10015', 澎湖縣: '10016', 基隆市: '10017',
  新竹市: '10018', 嘉義市: '10020', 金門縣: '09020', 連江縣: '09007'
});
export const DISTRICTS_URL = new URL('../../RainyClock/Resources/taiwan-districts.json', import.meta.url);
// The wording patterns in docs/dayoff-fixtures.json, which are what the
// phone's evaluator was written against; anything else would test the
// fixture rather than the phone.
const WHEN = { today: '今天', tomorrow: '明天' };
const DAY_PART = { full: '', morning: '上午' };
const SCOPE = { both: '停止上班、停止上課', work: '停止上班、照常上課', school: '照常上班、停止上課' };
const COMMANDS = ['set', 'clear', 'show'];
const GEOCODE = /^(?:\d{2}|\d{5}|\d{7})$/;
const NAME = /^[一-鿿]{2,10}$/;

const taipeiStamp = (time) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Taipei', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
  .format(new Date(time)).replace(/\D/g, '');

// Pure: the notice is built from the options and the clock alone, so the
// same command always yields the same shape and a test can assert on it.
export function buildFixture({ county, district = null, when = 'tomorrow', scope = 'both', dayPart = 'full', geocode = null, now = Date.now(), districts }) {
  if (typeof county !== 'string' || !NAME.test(county) || !Object.hasOwn(COUNTY_GEOCODES, county)) throw new ServiceError('unknown_county');
  if (district !== null) {
    if (typeof district !== 'string' || !NAME.test(district)) throw new ServiceError('unknown_district');
    if (!Array.isArray(districts)) throw new ServiceError('districts_unavailable');
    if (!districts.some((row) => row?.county === county && row?.district === district)) throw new ServiceError('unknown_district');
  }
  if (!Object.hasOwn(WHEN, when) || !Object.hasOwn(SCOPE, scope) || !Object.hasOwn(DAY_PART, dayPart)) throw new ServiceError('invalid_fixture_option');
  if (geocode !== null && (typeof geocode !== 'string' || !GEOCODE.test(geocode))) throw new ServiceError('invalid_geocode');
  const code = geocode ?? COUNTY_GEOCODES[county];
  const sentAt = new Date(now).toISOString();
  const notice = {
    id: `dgpa.gov.tw_workSchlClos_${taipeiStamp(now)}_i_${code}_001`,
    sentAt,
    description: `[停班停課通知]${county}${district ?? ''}:${WHEN[when]}${DAY_PART[dayPart]}${SCOPE[scope]}。行政院人事行政總處。`,
    severity: scope === 'school' ? 'Severe' : 'Extreme',
    msgType: 'Alert',
    status: 'Actual',
    geocodes: [code],
    references: []
  };
  const document = { notices: [notice], sourceUpdatedAt: sentAt, writtenAt: sentAt, writtenBy: 'fixture-cli', request: { county, district, when, scope, dayPart } };
  // The same validation the Job applies, so a document that would fail the
  // poll is never written in the first place.
  fixtureFeed(document);
  return document;
}

export function parseCommand(argv) {
  // parseArgs throws a plain TypeError for an unknown or valueless flag;
  // left alone, a typo like --dayPart would be reported as internal_error.
  let parsed;
  try {
    parsed = parseArgs({ args: argv, allowPositionals: true, strict: true, options: {
      county: { type: 'string' }, district: { type: 'string' }, when: { type: 'string' }, scope: { type: 'string' }, 'day-part': { type: 'string' }, geocode: { type: 'string' }
    } });
  } catch { throw new ServiceError('invalid_fixture_command'); }
  const { values, positionals } = parsed;
  const [command, ...rest] = positionals;
  if (!COMMANDS.includes(command) || rest.length > 0) throw new ServiceError('invalid_fixture_command');
  // The command must come first: deploy/fixture.sh decides from $1 whether
  // to execute the Job, so `--county X set` would write the fixture and then
  // never push it.
  if (argv[0] !== command) throw new ServiceError('invalid_fixture_command');
  if (command !== 'set' && Object.keys(values).length > 0) throw new ServiceError('invalid_fixture_command');
  if (command === 'set' && !values.county) throw new ServiceError('invalid_fixture_command');
  return { command, options: { county: values.county ?? null, district: values.district ?? null, when: values.when ?? 'tomorrow', scope: values.scope ?? 'both', dayPart: values['day-part'] ?? 'full', geocode: values.geocode ?? null } };
}

async function loadDistricts(url) {
  try { return JSON.parse(await readFile(url, 'utf8')); } catch { return null; }
}

// Everything that can be refused is refused before a Firestore client
// exists: the command line, the names, and the namespace.
export async function runFixtureCli({ argv, env = process.env, now = Date.now, districtsUrl = DISTRICTS_URL, createStore = createStoreFromEnv, stderr = (line) => process.stderr.write(line) } = {}) {
  const { command, options } = parseCommand(argv);
  const { namespace } = firestoreConfiguration(env);
  if (!fixtureAllowed(namespace)) throw new ServiceError('fixture_not_allowed');
  const document = command === 'set' ? buildFixture({ ...options, now: now(), districts: options.district === null ? undefined : await loadDistricts(districtsUrl) }) : null;
  // Only the event name and the gRPC code reach stderr (the store's failure
  // event carries nothing else): without them an expired ADC, a missing
  // datastore.user grant and a mistyped database id all read as the same
  // storage_unavailable.
  const authClient = await operatorAuthClient(env);
  const { store, close } = createStore(env, { authClient, log: (event) => stderr(JSON.stringify({ event: event.event, grpcCode: event.grpcCode ?? null }) + '\n') });
  try {
    if (command === 'set') await store.set(FIXTURE_PATH, document);
    else if (command === 'clear') await store.delete(FIXTURE_PATH);
    const stored = command === 'show' ? await store.get(FIXTURE_PATH) : document;
    return { event: 'dayoff_fixture', command, namespace, path: FIXTURE_PATH, document: stored };
  } finally { await close(); }
}

async function main() {
  try {
    process.stdout.write(JSON.stringify(await runFixtureCli({ argv: process.argv.slice(2) })) + '\n');
  } catch (error) {
    // A code only: the environment and SDK messages can quote paths or ids.
    process.stderr.write(JSON.stringify({ event: 'dayoff_fixture_failed', code: error instanceof ServiceError ? error.code : 'internal_error' }) + '\n');
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) void main();
