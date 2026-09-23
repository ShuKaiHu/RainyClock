import { createServer } from 'node:http';
import { ServiceError, safeErrorCode } from './errors.js';
import { syncStatus } from './devices.js';

function respond(response, status, value, extra = {}) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...extra });
  response.end(status === 204 ? undefined : JSON.stringify(value));
}

async function deviceBody(request) {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? '')) throw new ServiceError('invalid_device_request');
  if (request.headers['content-encoding'] || Number(request.headers['content-length']) > 1024) throw new ServiceError('device_request_too_large');
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 1024) throw new ServiceError('device_request_too_large');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new ServiceError('invalid_device_request'); }
}

export function createHTTPServer({ service, registry, pushConfigured = false, pushMode = null, trustForwardedFor = false, now = Date.now }) {
  // Behind Cloud Run every socket peer is the same front end. Google appends
  // the address it saw to whatever X-Forwarded-For the client sent, so only
  // the LAST entry is the caller; the first is the client's to write. (A load
  // balancer in front would append one more hop; the entry before it would
  // then be the caller.) A direct listener must not trust the header at all,
  // so the flag is off unless the deployment says so. In-memory and per
  // instance: abuse damping, not security.
  function clientAddress(request) {
    const socket = request.socket.remoteAddress ?? 'unknown';
    if (!trustForwardedFor) return socket;
    const forwarded = request.headers['x-forwarded-for'];
    return (typeof forwarded === 'string' ? forwarded.split(',').at(-1).trim() : '') || socket;
  }
  const limits = new Map();
  let lastSweep = 0;
  function allowed(peer) {
    const time = now();
    if (time - lastSweep >= 60_000) {
      for (const [key, value] of limits) if (value.until <= time) limits.delete(key);
      lastSweep = time;
    }
    const existing = limits.get(peer);
    if (!existing || existing.until <= time) {
      // A full table forgets everyone rather than refusing new phones: the
      // burst that fills it is the one the service exists for.
      if (!existing && limits.size >= 10_000) limits.clear();
      limits.set(peer, { count: 1, until: time + 60_000 });
      return true;
    }
    existing.count += 1;
    return existing.count <= 30;
  }
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 10_000, headersTimeout: 5000, keepAliveTimeout: 5000 }, async (request, response) => {
    try {
      if (request.url === '/health' && request.method === 'GET') {
        const health = await service.health();
        return respond(response, health.available ? 200 : 503, { ...health, pushConfigured, pushMode });
      }
      // Runbook diagnostics; only a store-backed reader has them.
      if (request.url === '/health/details' && request.method === 'GET') {
        if (typeof service.details !== 'function') return respond(response, 404, { error: 'not_found' });
        return respond(response, 200, await service.details());
      }
      if (request.url === '/v1/suspensions' && request.method === 'GET') {
        try { return respond(response, 200, await service.getSnapshot()); }
        catch (error) { return respond(response, 503, { error: safeErrorCode(error) }, { 'Retry-After': '60' }); }
      }
      if (request.url === '/v1/devices' && ['POST', 'DELETE'].includes(request.method)) {
        if (!allowed(clientAddress(request))) return respond(response, 429, { error: 'rate_limited' }, { 'Retry-After': '60' });
        if (!pushConfigured && request.method === 'POST') return respond(response, 503, { error: 'push_not_configured' });
        const input = await deviceBody(request);
        if (request.method === 'DELETE') {
          await registry.remove(input);
          return respond(response, 204);
        }
        const result = await registry.register(input);
        return respond(response, result.created ? 201 : 200, { registered: true });
      }
      if (['/v1/devices/sync-receipt', '/v1/devices/sync-status'].includes(request.url) && request.method === 'POST') {
        if (!allowed(clientAddress(request))) return respond(response, 429, { error: 'rate_limited' }, { 'Retry-After': '60' });
        const input = await deviceBody(request);
        if (request.url === '/v1/devices/sync-receipt') return respond(response, 200, await registry.recordReceipt(input));
        const receipt = await registry.receipt(input);
        let snapshot = null;
        try { snapshot = await service.getSnapshot(); } catch { /* Report source availability separately from authenticated receipt access. */ }
        return respond(response, 200, syncStatus(receipt, snapshot, now()));
      }
      return respond(response, 404, { error: 'not_found' });
    } catch (error) {
      const code = safeErrorCode(error);
      const status = code === 'device_credential_mismatch' ? 403 : code === 'device_not_registered' ? 404 : code === 'device_request_too_large' ? 413 : code === 'invalid_device_request' ? 400 : 503;
      if (!response.headersSent) respond(response, status, { error: code });
      else response.destroy();
    }
  });
  server.maxConnections = 256;
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  return server;
}
