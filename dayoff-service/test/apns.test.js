import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { createApnsDispatcher } from '../apns.js';

// Ephemeral test keys only. Every send uses an injected fake transport.
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const testKey = privateKey.export({ type: 'pkcs8', format: 'pem' });
const deviceToken = 'ab'.repeat(32);
const base = { teamId: 'TEAM123456', keyId: 'KEY1234567', privateKey: testKey, topic: 'com.example.RainyClock' };
const fixedTime = 1_789_430_400_000;

function setup(options = {}) {
  const calls = [];
  const transport = async request => { calls.push(request); return { status: 200, body: '' }; };
  const dispatcher = createApnsDispatcher({ ...base, now: () => fixedTime, transport, ...options });
  return { ...dispatcher, calls };
}

test('alert mode sends one collapsible, mutable, localised notification per device and no location', async t => {
  const dispatcher = setup();
  t.after(dispatcher.close);
  assert.equal(dispatcher.pushMode, 'alert');
  const result = await dispatcher.send(deviceToken, { revision: 'revision-1' });
  assert.deepEqual(result, { ok: true, status: 200, unregistered: false, retryable: false });
  const { headers, body } = dispatcher.calls[0];
  assert.equal(headers['apns-push-type'], 'alert');
  assert.equal(headers['apns-priority'], '10');
  assert.equal(headers['apns-collapse-id'], 'dayoff-sync');
  assert.equal(headers['apns-expiration'], String(fixedTime / 1000 + 10 * 3600));
  assert.deepEqual(JSON.parse(body), {
    aps: {
      alert: { 'title-loc-key': 'dayoff_push_title', 'body-loc-key': 'dayoff_push_body' },
      sound: 'default', 'mutable-content': 1, 'thread-id': 'dayoff',
    },
    type: 'dayoff-sync', revision: 'revision-1',
  });
  // The phone decides relevance; nothing in the payload names a county or district.
  assert.doesNotMatch(body, /[縣市區鄉鎮]/u);
});

test('rejects an unknown push mode before touching the key', () => {
  assert.throws(() => createApnsDispatcher({ ...base, pushMode: 'silent' }), /Invalid APNs push mode/);
});

test('sends a background refresh hint using correct APNs headers and ES256 JWT', async t => {
  const dispatcher = setup({ pushMode: 'background' });
  t.after(dispatcher.close);
  assert.equal(dispatcher.calls.length, 0);
  const result = await dispatcher.send(deviceToken.toUpperCase(), { revision: 'revision-1' });
  assert.deepEqual(result, { ok: true, status: 200, unregistered: false, retryable: false });
  const { origin, headers, body } = dispatcher.calls[0];
  assert.equal(origin, 'https://api.sandbox.push.apple.com');
  assert.equal(headers[':method'], 'POST');
  assert.equal(headers[':path'], `/3/device/${deviceToken}`);
  assert.equal(headers['apns-topic'], base.topic);
  assert.equal(headers['apns-push-type'], 'background');
  assert.equal(headers['apns-priority'], '5');
  assert.equal(headers['apns-collapse-id'], 'dayoff-sync');
  assert.equal(headers['apns-expiration'], String(fixedTime / 1000 + 3600));
  assert.equal(headers['content-type'], 'application/json');
  assert.equal(Number(headers['content-length']), Buffer.byteLength(body));
  assert.deepEqual(JSON.parse(body), { aps: { 'content-available': 1 }, type: 'dayoff-sync', revision: 'revision-1' });
  const token = headers.authorization.replace(/^bearer /, '');
  const [header, claims, signature] = token.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: base.keyId });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: base.teamId, iat: fixedTime / 1000 });
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
  assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
});

test('production uses only the production endpoint', async t => {
  const dispatcher = setup({ production: true });
  t.after(dispatcher.close);
  await dispatcher.send(deviceToken, { revision: '2' });
  assert.equal(dispatcher.calls[0].origin, 'https://api.push.apple.com');
});

test('reuses JWT across requests and refreshes it after 50 minutes', async t => {
  let clock = fixedTime;
  const dispatcher = setup({ now: () => clock });
  t.after(dispatcher.close);
  await dispatcher.send(deviceToken, { revision: '1' });
  clock += 49 * 60 * 1000;
  await dispatcher.send(deviceToken, { revision: '2' });
  assert.equal(dispatcher.calls[0].headers.authorization, dispatcher.calls[1].headers.authorization);
  clock += 60 * 1000;
  await dispatcher.send(deviceToken, { revision: '3' });
  assert.notEqual(dispatcher.calls[0].headers.authorization, dispatcher.calls[2].headers.authorization);
  const claims = dispatcher.calls[2].headers.authorization.split('.')[1];
  assert.equal(JSON.parse(Buffer.from(claims, 'base64url')).iat, clock / 1000);
});

test('validates credentials without exposing private input', () => {
  for (const overrides of [
    { teamId: 'bad\nvalue' }, { keyId: '' }, { topic: 'com.example\ninjection' },
    { production: 'true' }, { timeoutMs: 0 }, { timeoutMs: 60_001 },
    { privateKey: 'private-secret-value' }, { transport: {} },
  ]) {
    assert.throws(() => setup(overrides), error => error instanceof TypeError && !error.message.includes('private-secret-value'));
  }
  const wrongKey = generateKeyPairSync('ec', { namedCurve: 'secp384r1' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.throws(() => setup({ privateKey: wrongKey }), /P-256 private key/);
});

test('rejects unsafe device tokens before contacting the transport', async t => {
  const dispatcher = setup();
  t.after(dispatcher.close);
  for (const value of ['', deviceToken + '\n', 'x'.repeat(64), '../device', null, 'ab'.repeat(31), 'ab'.repeat(33)]) {
    await assert.rejects(dispatcher.send(value, { revision: '1' }), /Invalid APNs device token/);
  }
  assert.equal(dispatcher.calls.length, 0);
});

test('enforces the notification payload limit in bytes, including JSON overhead', async t => {
  const dispatcher = setup({ pushMode: 'background' });
  t.after(dispatcher.close);
  for (const revision of ['', null, {}, 1]) {
    await assert.rejects(dispatcher.send(deviceToken, { revision }), /Invalid day-off revision/);
  }
  await assert.rejects(dispatcher.send(deviceToken, { revision: 'a'.repeat(4096) }), /4096 bytes/);
  await assert.rejects(dispatcher.send(deviceToken, { revision: '日'.repeat(1400) }), /4096 bytes/);
  await assert.rejects(dispatcher.send(deviceToken, { revision: '\\'.repeat(3000) }), /4096 bytes/);
  assert.equal(dispatcher.calls.length, 0);
  await dispatcher.send(deviceToken, { revision: 'a'.repeat(4000) });
  assert.ok(Buffer.byteLength(dispatcher.calls[0].body) <= 4096);
  // A real revision is a 64-hex digest; the alert envelope leaves it far under the limit.
  const alert = setup();
  t.after(alert.close);
  await alert.send(deviceToken, { revision: 'f'.repeat(64) });
  assert.ok(Buffer.byteLength(alert.calls[0].body) <= 4096);
});

test('410 identifies an unregistered token for the registry to remove', async t => {
  const dispatcher = setup({ transport: async () => ({ status: 410, body: JSON.stringify({ reason: 'Unregistered', timestamp: fixedTime }) }) });
  t.after(dispatcher.close);
  assert.deepEqual(await dispatcher.send(deviceToken, { revision: '1' }), {
    ok: false, status: 410, reason: 'Unregistered', unregistered: true, retryable: false, timestamp: fixedTime,
  });
});

test('classifies APNs rejection and transient failures without retrying', async t => {
  for (const [status, reason, retryable] of [[400, 'BadDeviceToken', false], [403, 'ExpiredProviderToken', false], [429, 'TooManyRequests', true], [503, 'Shutdown', true]]) {
    let count = 0;
    const dispatcher = setup({ transport: async () => { count++; return { status, body: JSON.stringify({ reason }) }; } });
    t.after(dispatcher.close);
    assert.deepEqual(await dispatcher.send(deviceToken, { revision: '1' }), { ok: false, status, reason, unregistered: false, retryable });
    assert.equal(count, 1);
  }
});

test('sanitizes invalid responses and arbitrary remote error strings', async t => {
  for (const response of [
    { status: 500, body: 'not-json' },
    { status: 500, body: JSON.stringify({ reason: deviceToken }) },
    { status: 500, body: 'x'.repeat(4097) },
  ]) {
    const dispatcher = setup({ transport: async () => response });
    t.after(dispatcher.close);
    assert.deepEqual(await dispatcher.send(deviceToken, { revision: '1' }), { ok: false, status: 500, reason: 'Rejected', unregistered: false, retryable: true });
  }
  const invalid = setup({ transport: async () => ({ status: undefined }) });
  t.after(invalid.close);
  assert.equal((await invalid.send(deviceToken, { revision: '1' })).reason, 'InvalidResponse');
});

test('bounds the full request even when the transport ignores cancellation', async t => {
  let signal;
  const dispatcher = setup({ timeoutMs: 15, transport: request => { signal = request.signal; return new Promise(() => {}); } });
  t.after(dispatcher.close);
  const start = performance.now();
  assert.deepEqual(await dispatcher.send(deviceToken, { revision: '1' }), { ok: false, status: 0, reason: 'Timeout', unregistered: false, retryable: true });
  assert.equal(signal.aborted, true);
  assert.ok(performance.now() - start < 1000);
});

test('does not expose network exception text, device tokens, or provider keys', async t => {
  const dispatcher = setup({ transport: async () => { throw new Error(`${deviceToken} ${testKey}`); } });
  t.after(dispatcher.close);
  assert.deepEqual(await dispatcher.send(deviceToken, { revision: '1' }), { ok: false, status: 0, reason: 'NetworkError', unregistered: false, retryable: true });
});

test('close cancels in-flight work and prevents subsequent requests', async () => {
  let signal;
  let count = 0;
  let closeCount = 0;
  const transport = request => { count++; signal = request.signal; return new Promise(() => {}); };
  transport.close = () => { closeCount++; };
  const dispatcher = setup({ transport });
  const pending = dispatcher.send(deviceToken, { revision: '1' });
  await Promise.resolve();
  dispatcher.close();
  dispatcher.close();
  assert.equal(signal.aborted, true);
  assert.equal((await pending).reason, 'Closed');
  assert.equal((await dispatcher.send(deviceToken, { revision: '2' })).reason, 'Closed');
  assert.equal(closeCount, 1);
  assert.equal(count, 1);
});
