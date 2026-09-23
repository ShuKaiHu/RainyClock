import { connect, constants } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';

const MAX_PAYLOAD_BYTES = 4096;
const MAX_RESPONSE_BYTES = 4096;
const TOKEN_LIFETIME_SECONDS = 50 * 60;
// 'alert' is the shipped design: a visible push to every registered device, personalised
// on the phone by its notification service extension against the districts it keeps
// locally. The server never learns where anyone lives. 'background' is the older silent
// refresh hint, kept for operators who want it.
const PUSH_MODES = new Set(['alert', 'background']);
// An announcement matters until the next morning's alarm; a silent hint only for an hour.
const ALERT_EXPIRATION_SECONDS = 10 * 3600;
const BACKGROUND_EXPIRATION_SECONDS = 3600;
const APNS_REASONS = new Set([
  'BadCollapseId', 'BadDeviceToken', 'BadExpirationDate', 'BadMessageId',
  'BadPriority', 'BadTopic', 'DeviceTokenNotForTopic', 'DuplicateHeaders',
  'IdleTimeout', 'InvalidPushType', 'MissingDeviceToken', 'MissingTopic',
  'PayloadEmpty', 'TopicDisallowed', 'BadCertificate', 'BadCertificateEnvironment',
  'ExpiredProviderToken', 'Forbidden', 'InvalidProviderToken', 'MissingProviderToken',
  'BadPath', 'MethodNotAllowed', 'Unregistered', 'PayloadTooLarge',
  'TooManyProviderTokenUpdates', 'TooManyRequests', 'InternalServerError',
  'ServiceUnavailable', 'Shutdown',
]);

function createHttp2Transport() {
  let currentSession;
  const sessions = new Set();
  const request = ({ origin, headers, body, signal }) => new Promise((resolve, reject) => {
    let stream;
    let session;
    let finished = false;
    let responseHeaders;
    let responseBytes = 0;
    const chunks = [];
    const finish = (error, value) => {
      if (finished) return;
      finished = true;
      signal.removeEventListener('abort', abort);
      error ? reject(error) : resolve(value);
    };
    const abort = () => {
      finish(new Error('Aborted'));
      stream?.close(constants.NGHTTP2_CANCEL);
    };
    if (signal.aborted) return abort();
    try {
      if (!currentSession || currentSession.closed || currentSession.destroyed) {
        currentSession = connect(origin, { minVersion: 'TLSv1.2' });
        session = currentSession;
        sessions.add(session);
        // Stream listeners report request failures; never log connection details.
        session.on('error', () => {});
        session.on('close', () => sessions.delete(session));
        session.on('goaway', () => {
          if (currentSession === session) currentSession = undefined;
          session.close();
        });
      }
      stream = currentSession.request(headers);
      stream.on('error', () => finish(new Error('NetworkError')));
      stream.on('response', value => { responseHeaders = value; });
      stream.on('data', chunk => {
        responseBytes += chunk.length;
        if (responseBytes > MAX_RESPONSE_BYTES) {
          finish(new Error('InvalidResponse'));
          stream.close(constants.NGHTTP2_CANCEL);
          return;
        }
        chunks.push(chunk);
      });
      stream.on('end', () => finish(null, {
        status: responseHeaders?.[':status'],
        body: Buffer.concat(chunks).toString('utf8'),
      }));
      stream.on('close', () => finish(new Error('NetworkError')));
      signal.addEventListener('abort', abort, { once: true });
      stream.end(body);
    } catch {
      finish(new Error('NetworkError'));
    }
  });
  request.close = () => {
    currentSession = undefined;
    for (const session of sessions) session.destroy();
    sessions.clear();
  };
  return request;
}

function parseResponse(response) {
  const status = response?.status;
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    return { ok: false, status: 0, reason: 'InvalidResponse', unregistered: false, retryable: true };
  }
  if (status === 200) return { ok: true, status, unregistered: false, retryable: false };
  let parsed;
  if (typeof response.body === 'string' && Buffer.byteLength(response.body) <= MAX_RESPONSE_BYTES) {
    try { parsed = JSON.parse(response.body); } catch { /* Preserve the HTTP result. */ }
  }
  const result = {
    ok: false,
    status,
    reason: APNS_REASONS.has(parsed?.reason) ? parsed.reason : 'Rejected',
    unregistered: status === 410,
    retryable: status === 429 || status >= 500,
  };
  if (status === 410 && Number.isSafeInteger(parsed?.timestamp) && parsed.timestamp >= 0) {
    result.timestamp = parsed.timestamp;
  }
  return result;
}

/**
 * Optional APNs dispatcher. All credentials are explicitly supplied by its caller.
 * Construction performs no network request. `ok` means accepted by APNs, never
 * proof of delivery or a changed device alarm. There are no automatic retries.
 * Tests can inject transport({origin, headers, body, signal}) and now() in ms.
 */
export function createApnsDispatcher({
  teamId, keyId, privateKey, topic, production = false,
  timeoutMs = 10_000, transport, now = Date.now, pushMode = 'alert',
} = {}) {
  if (!PUSH_MODES.has(pushMode)) throw new TypeError('Invalid APNs push mode');
  if (typeof teamId !== 'string' || !/^[A-Z0-9]{10}$/.test(teamId)) throw new TypeError('Invalid APNs team ID');
  if (typeof keyId !== 'string' || !/^[A-Z0-9]{10}$/.test(keyId)) throw new TypeError('Invalid APNs key ID');
  if (typeof topic !== 'string' || topic.length > 255 || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(topic)) {
    throw new TypeError('Invalid APNs topic');
  }
  if (typeof production !== 'boolean') throw new TypeError('APNs production must be a boolean');
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) throw new TypeError('Invalid APNs timeout');
  if (typeof now !== 'function' || (transport !== undefined && typeof transport !== 'function')) {
    throw new TypeError('Invalid APNs transport or clock');
  }
  let signingKey;
  try {
    signingKey = createPrivateKey(privateKey);
    if (signingKey.asymmetricKeyType !== 'ec' || signingKey.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
      throw new Error('Invalid curve');
    }
  } catch {
    throw new TypeError('APNs requires a valid P-256 private key');
  }
  const sendRequest = transport ?? createHttp2Transport();
  const origin = production ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
  const pending = new Set();
  let closed = false;
  let cachedToken;
  let tokenIssuedAt;

  function providerToken() {
    const issuedAt = Math.floor(now() / 1000);
    if (!Number.isSafeInteger(issuedAt) || issuedAt < 0) throw new Error('InvalidClock');
    if (cachedToken && issuedAt >= tokenIssuedAt && issuedAt - tokenIssuedAt < TOKEN_LIFETIME_SECONDS) return cachedToken;
    const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId })).toString('base64url');
    const claims = Buffer.from(JSON.stringify({ iss: teamId, iat: issuedAt })).toString('base64url');
    const unsigned = `${header}.${claims}`;
    const signature = sign('sha256', Buffer.from(unsigned), { key: signingKey, dsaEncoding: 'ieee-p1363' });
    cachedToken = `${unsigned}.${signature.toString('base64url')}`;
    tokenIssuedAt = issuedAt;
    return cachedToken;
  }

  async function send(deviceToken, { revision } = {}) {
    if (typeof deviceToken !== 'string' || !/^[a-fA-F0-9]{64}$/.test(deviceToken)) throw new TypeError('Invalid APNs device token');
    if (typeof revision !== 'string' || revision.length === 0) throw new TypeError('Invalid day-off revision');
    if (Buffer.byteLength(revision) > MAX_PAYLOAD_BYTES) throw new RangeError('APNs payload exceeds 4096 bytes');
    const alert = pushMode === 'alert';
    // loc-keys resolve in the app's own Localizable.strings, so the fallback the system
    // shows if the extension fails is still localised and still says nothing about a
    // specific district. The extension rewrites title, body, sound and urgency.
    const body = JSON.stringify(alert
      ? { aps: { alert: { 'title-loc-key': 'dayoff_push_title', 'body-loc-key': 'dayoff_push_body' }, sound: 'default', 'mutable-content': 1, 'thread-id': 'dayoff' }, type: 'dayoff-sync', revision }
      : { aps: { 'content-available': 1 }, type: 'dayoff-sync', revision });
    if (Buffer.byteLength(body) > MAX_PAYLOAD_BYTES) throw new RangeError('APNs payload exceeds 4096 bytes');
    if (closed) return { ok: false, status: 0, reason: 'Closed', unregistered: false, retryable: false };
    const controller = new AbortController();
    pending.add(controller);
    let timer;
    let timedOut = false;
    let abortListener;
    try {
      const aborted = new Promise((_, reject) => {
        abortListener = () => reject(new Error('Aborted'));
        controller.signal.addEventListener('abort', abortListener, { once: true });
      });
      timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
      const request = Promise.resolve().then(() => {
        if (controller.signal.aborted) throw new Error('Aborted');
        return sendRequest({
          origin,
          headers: {
            ':method': 'POST', ':path': `/3/device/${deviceToken.toLowerCase()}`,
            authorization: `bearer ${providerToken()}`,
            'apns-topic': topic, 'apns-push-type': alert ? 'alert' : 'background', 'apns-priority': alert ? '10' : '5',
            // One visible notification per device, replaced as revisions land, never a pile.
            'apns-collapse-id': 'dayoff-sync',
            'apns-expiration': String(Math.floor(now() / 1000) + (alert ? ALERT_EXPIRATION_SECONDS : BACKGROUND_EXPIRATION_SECONDS)),
            'content-type': 'application/json', 'content-length': String(Buffer.byteLength(body)),
          },
          body,
          signal: controller.signal,
        });
      });
      return parseResponse(await Promise.race([request, aborted]));
    } catch {
      return {
        ok: false, status: 0,
        reason: timedOut ? 'Timeout' : closed ? 'Closed' : 'NetworkError',
        unregistered: false, retryable: !closed,
      };
    } finally {
      clearTimeout(timer);
      controller.signal.removeEventListener('abort', abortListener);
      pending.delete(controller);
    }
  }

  function close() {
    if (closed) return;
    closed = true;
    cachedToken = undefined;
    for (const controller of pending) controller.abort();
    sendRequest.close?.();
  }
  return { send, close, pushMode };
}
