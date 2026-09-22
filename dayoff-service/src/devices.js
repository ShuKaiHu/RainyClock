import { createHash, timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';
import { readJSON, writeJSON } from './storage.js';
import { ServiceError } from './errors.js';
import { isoTimestamp } from './parser.js';

const MAX_DEVICES = 10_000;
// 10,000 bounded registrations plus one small acknowledgement each.
const MAX_STATE_BYTES = 8 * 1024 * 1024;
const DEVICE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const CLOCK_SKEW_MS = 300_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HEX = /^[a-f0-9]{64}$/i;
const digest = (value) => createHash('sha256').update(value).digest('hex');
const taipeiDay = (value) => new Date(value + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);

function exactObject(input, keys) {
  return input && !Array.isArray(input) && typeof input === 'object' && Object.keys(input).every((key) => keys.includes(key));
}

function validateIdentity(input) {
  if (!exactObject(input, ['installationId', 'credential']) || typeof input.installationId !== 'string' || !UUID.test(input.installationId) || typeof input.credential !== 'string' || !HEX.test(input.credential)) throw new ServiceError('invalid_device_request');
  return { installationId: input.installationId.toLowerCase(), credentialHash: digest(input.credential.toLowerCase()) };
}

function validateReceipt(input, now) {
  if (!exactObject(input, ['revision', 'checkedAt', 'appliedAt', 'result']) || typeof input.revision !== 'string' || !HEX.test(input.revision) || !['applied', 'no_alarm'].includes(input.result)) throw new ServiceError('invalid_device_request');
  let checkedAt, appliedAt;
  try { checkedAt = isoTimestamp(input.checkedAt); appliedAt = isoTimestamp(input.appliedAt); }
  catch { throw new ServiceError('invalid_device_request'); }
  // checkedAt is the server's clock; appliedAt is the phone's clock. Permit a
  // small offset without accepting a receipt from a substantially later feed.
  if (Date.parse(checkedAt) > now + CLOCK_SKEW_MS || Date.parse(appliedAt) > now + CLOCK_SKEW_MS || Date.parse(checkedAt) > Date.parse(appliedAt) + CLOCK_SKEW_MS) throw new ServiceError('invalid_device_request');
  return { revision: input.revision.toLowerCase(), checkedAt, appliedAt, result: input.result };
}

function authenticate(devices, identity) {
  const device = devices.get(identity.installationId);
  if (!device) throw new ServiceError('device_not_registered');
  if (!timingSafeEqual(Buffer.from(device.credentialHash, 'hex'), Buffer.from(identity.credentialHash, 'hex'))) throw new ServiceError('device_credential_mismatch');
  return device;
}

export function syncStatus(receipt, snapshot, now = Date.now()) {
  const currentRevision = snapshot?.revision ?? null;
  const matchesCurrentRevision = Boolean(receipt && currentRevision && receipt.revision === currentRevision);
  // An acknowledgement describes completed processing at appliedAt. At the
  // next Taiwan calendar day it cannot demonstrate today's date-dependent plan.
  const currentDay = receipt && taipeiDay(Date.parse(receipt.appliedAt)) === taipeiDay(now);
  const status = !snapshot ? 'source_unavailable' : matchesCurrentRevision && currentDay ? receipt.result : 'pending';
  return { status, matchesCurrentRevision, currentRevision, receipt };
}

export function validateDeviceInput(input, remove = false) {
  if (!input || Array.isArray(input) || typeof input !== 'object' || Object.keys(input).some((key) => !['installationId', 'deviceToken', 'credential'].includes(key)) ||
      !UUID.test(input.installationId) || typeof input.credential !== 'string' || !HEX.test(input.credential) || (!remove && (typeof input.deviceToken !== 'string' || !HEX.test(input.deviceToken)))) {
    throw new ServiceError('invalid_device_request');
  }
  return { installationId: input.installationId.toLowerCase(), credentialHash: digest(input.credential.toLowerCase()), deviceToken: remove ? null : input.deviceToken.toLowerCase() };
}

export class DeviceRegistry {
  constructor({ dataDir, now = Date.now, maxDevices = MAX_DEVICES }) {
    this.path = join(dataDir, 'devices.json');
    this.now = now;
    this.maxDevices = maxDevices;
    this.devices = new Map();
    this.queue = Promise.resolve();
    this.pendingWrites = 0;
  }

  async initialize() {
    const saved = await readJSON(this.path, MAX_STATE_BYTES);
    if (!saved) return;
    if (saved.schemaVersion !== 1 || !Array.isArray(saved.devices) || saved.devices.length > this.maxDevices) throw new ServiceError('invalid_device_storage');
    for (const device of saved.devices) {
      if (!UUID.test(device.installationId) || !HEX.test(device.deviceToken) || !HEX.test(device.credentialHash) || !Number.isFinite(device.updatedAt) || device.updatedAt > this.now() + 300_000 || this.devices.has(device.installationId)) throw new ServiceError('invalid_device_storage');
      let receipt;
      if (device.receipt !== undefined) {
        try { receipt = validateReceipt(device.receipt, this.now()); }
        catch { throw new ServiceError('invalid_device_storage'); }
      }
      if (this.now() - device.updatedAt < DEVICE_TTL_MS) this.devices.set(device.installationId, { installationId: device.installationId, deviceToken: device.deviceToken, credentialHash: device.credentialHash, updatedAt: device.updatedAt, ...(receipt ? { receipt } : {}) });
    }
  }

  transact(operation) {
    if (this.pendingWrites >= 128) return Promise.reject(new ServiceError('device_registry_busy'));
    this.pendingWrites += 1;
    const task = this.queue.then(async () => {
      const next = new Map([...this.devices].filter(([, device]) => this.now() - device.updatedAt < DEVICE_TTL_MS));
      const result = operation(next);
      await writeJSON(this.path, { schemaVersion: 1, devices: [...next.values()] }, MAX_STATE_BYTES);
      this.devices = next;
      return result;
    });
    const completed = task.finally(() => { this.pendingWrites -= 1; });
    this.queue = completed.catch(() => {});
    return completed;
  }

  register(input) {
    const device = validateDeviceInput(input);
    return this.transact((next) => {
      const old = next.get(device.installationId);
      if (old && !timingSafeEqual(Buffer.from(old.credentialHash, 'hex'), Buffer.from(device.credentialHash, 'hex'))) throw new ServiceError('device_credential_mismatch');
      if (!old && next.size >= this.maxDevices) throw new ServiceError('device_registry_full');
      next.set(device.installationId, { ...device, updatedAt: this.now(), ...(old?.receipt ? { receipt: old.receipt } : {}) });
      return { created: !old };
    });
  }

  remove(input) {
    const device = validateDeviceInput(input, true);
    return this.transact((next) => {
      const old = next.get(device.installationId);
      if (old && !timingSafeEqual(Buffer.from(old.credentialHash, 'hex'), Buffer.from(device.credentialHash, 'hex'))) throw new ServiceError('device_credential_mismatch');
      next.delete(device.installationId);
    });
  }

  recordReceipt(input) {
    if (!exactObject(input, ['installationId', 'credential', 'revision', 'checkedAt', 'appliedAt', 'result'])) throw new ServiceError('invalid_device_request');
    const identity = validateIdentity({ installationId: input.installationId, credential: input.credential });
    const receipt = validateReceipt({ revision: input.revision, checkedAt: input.checkedAt, appliedAt: input.appliedAt, result: input.result }, this.now());
    return this.transact((next) => {
      const old = authenticate(next, identity);
      if (old.receipt && (receipt.checkedAt < old.receipt.checkedAt || (receipt.checkedAt === old.receipt.checkedAt && receipt.appliedAt <= old.receipt.appliedAt))) return { recorded: false };
      next.set(identity.installationId, { ...old, receipt, updatedAt: this.now() });
      return { recorded: true };
    });
  }

  async receipt(input) {
    const identity = validateIdentity(input);
    await this.queue;
    const device = authenticate(this.devices, identity);
    if (this.now() - device.updatedAt >= DEVICE_TTL_MS) throw new ServiceError('device_not_registered');
    // Return a value copy so callers cannot mutate persisted state in memory.
    return device.receipt ? { ...device.receipt } : null;
  }

  removeUnregistered(token, timestamp) {
    return this.transact((next) => {
      for (const [id, device] of next) {
        // A newer re-registration may have occurred while APNs was responding.
        if (device.deviceToken === token && (!Number.isFinite(timestamp) || device.updatedAt <= timestamp)) next.delete(id);
      }
    });
  }

  tokens() {
    return [...new Set([...this.devices.values()].filter((device) => this.now() - device.updatedAt < DEVICE_TTL_MS).map((device) => device.deviceToken))];
  }
}

// Coalesce newer revisions while a bounded broadcast is in progress. APNs acceptance
// only asks the app to refresh; no server response claims an alarm was cancelled.
export class RevisionBroadcaster {
  constructor({ registry, dispatcher, concurrency = 4, log = () => {} }) {
    this.registry = registry;
    this.dispatcher = dispatcher;
    this.concurrency = concurrency;
    this.log = log;
    this.pending = null;
    this.running = null;
    this.stopped = false;
  }
  enqueue(revision) {
    if (!this.dispatcher || this.stopped) return Promise.resolve();
    this.pending = revision;
    if (!this.running) this.running = this.drain().finally(() => {
      this.running = null;
      // A revision may arrive in the microtask between drain completing and this
      // finalizer. Keep that last update instead of leaving it pending forever.
      if (this.pending && !this.stopped) void this.enqueue(this.pending);
    });
    return this.running;
  }
  async drain() {
    while (this.pending && !this.stopped) {
      const revision = this.pending;
      this.pending = null;
      const tokens = this.registry.tokens();
      let cursor = 0, accepted = 0, failed = 0;
      await Promise.all(Array.from({ length: Math.min(this.concurrency, tokens.length) }, async () => {
        while (cursor < tokens.length && !this.pending && !this.stopped) {
          const token = tokens[cursor++];
          try {
            const result = await this.dispatcher.send(token, { revision });
            if (result.ok) accepted += 1; else failed += 1;
            if (result.unregistered) await this.registry.removeUnregistered(token, result.timestamp);
          } catch { failed += 1; }
        }
      }));
      this.log({ event: 'push_batch', accepted, failed });
    }
  }
  async stop() {
    this.stopped = true;
    this.pending = null;
    this.dispatcher?.close();
    await this.running;
  }
}
