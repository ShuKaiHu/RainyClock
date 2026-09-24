import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { ServiceError, safeErrorCode } from './errors.js';
import { isoTimestamp } from './parser.js';
import { broadcastRevision } from './broadcast.js';

const MAX_DEVICES = 10_000;
// Firestore transactions queue behind each other on contention; past this
// many in flight a burst is refused rather than allowed to pile up.
const MAX_IN_FLIGHT = 128;
const DEVICE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const CLOCK_SKEW_MS = 300_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HEX = /^[a-f0-9]{64}$/i;
const digest = (value) => createHash('sha256').update(value).digest('hex');
const taipeiDay = (value) => new Date(value + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);
const sameHash = (a, b) => timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
const devicePath = (installationId) => `devices/${installationId}`;

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

function authenticate(device, identity) {
  if (!device) throw new ServiceError('device_not_registered');
  if (!sameHash(device.credentialHash, identity.credentialHash)) throw new ServiceError('device_credential_mismatch');
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
  constructor({ store, now = Date.now, maxDevices = MAX_DEVICES }) {
    this.store = store;
    this.now = now;
    this.maxDevices = maxDevices;
    this.pendingWrites = 0;
  }

  // Nothing is loaded up front any more; kept so call sites need no change.
  async initialize() {}

  // Everything a write does against the store counts as in flight, a
  // pre-read included: the bound is on the burst, not on the transaction.
  inFlight(work) {
    if (this.pendingWrites >= MAX_IN_FLIGHT) return Promise.reject(new ServiceError('device_registry_busy'));
    this.pendingWrites += 1;
    return work().finally(() => { this.pendingWrites -= 1; });
  }

  transact(operation) {
    return this.inFlight(() => this.store.runTransaction(operation));
  }

  // Validation moved from startup to every read: a document the store hands
  // back is checked before its credential hash or receipt is trusted, and an
  // expired registration is absent whatever the TTL janitor has got to.
  storedDevice(doc) {
    if (doc === null) return null;
    const now = this.now();
    if (!doc || !UUID.test(doc.installationId) || !HEX.test(doc.deviceToken) || !HEX.test(doc.credentialHash) || !Number.isFinite(doc.updatedAt) || doc.updatedAt > now + CLOCK_SKEW_MS) throw new ServiceError('invalid_device_storage');
    let receipt;
    if (doc.receipt !== undefined) {
      try { receipt = validateReceipt(doc.receipt, now); }
      catch { throw new ServiceError('invalid_device_storage'); }
    }
    if (now - doc.updatedAt >= DEVICE_TTL_MS) return null;
    return { installationId: doc.installationId, deviceToken: doc.deviceToken, credentialHash: doc.credentialHash, updatedAt: doc.updatedAt, ...(receipt ? { receipt } : {}) };
  }

  stamp(device) {
    const now = this.now();
    return { ...device, updatedAt: now, expiresAt: new Date(now + DEVICE_TTL_MS) };
  }

  register(input) {
    const device = validateDeviceInput(input);
    const path = devicePath(device.installationId);
    return this.inFlight(async () => {
      await this.admit(path);
      return this.store.runTransaction(async (tx) => {
        const old = this.storedDevice(await tx.get(path));
        if (old && !sameHash(old.credentialHash, device.credentialHash)) throw new ServiceError('device_credential_mismatch');
        tx.set(path, this.stamp({ ...device, ...(old?.receipt ? { receipt: old.receipt } : {}) }));
        return { created: !old };
      });
    });
  }

  // The cap is counted before the transaction, never inside it: Firestore
  // serialises a transaction over the result of its aggregation, so every
  // concurrent create would invalidate every other and a burst of new phones
  // would rerun each other into 503s. Counted outside, two creates that both
  // see one free slot both succeed; a few over the cap is the accepted cost.
  // Registrations past their 90 days may still be on disk until the TTL
  // policy sweeps them; they must not hold a slot against new phones.
  async admit(path) {
    if (this.storedDevice(await this.store.get(path))) return;
    const live = await this.store.count('devices', { where: [{ field: 'updatedAt', op: '>', value: this.now() - DEVICE_TTL_MS }] });
    if (live >= this.maxDevices) throw new ServiceError('device_registry_full');
  }

  remove(input) {
    const device = validateDeviceInput(input, true);
    return this.transact(async (tx) => {
      const old = this.storedDevice(await tx.get(devicePath(device.installationId)));
      if (!old) return;
      if (!sameHash(old.credentialHash, device.credentialHash)) throw new ServiceError('device_credential_mismatch');
      tx.delete(devicePath(device.installationId));
    });
  }

  recordReceipt(input) {
    if (!exactObject(input, ['installationId', 'credential', 'revision', 'checkedAt', 'appliedAt', 'result'])) throw new ServiceError('invalid_device_request');
    const identity = validateIdentity({ installationId: input.installationId, credential: input.credential });
    const receipt = validateReceipt({ revision: input.revision, checkedAt: input.checkedAt, appliedAt: input.appliedAt, result: input.result }, this.now());
    return this.transact(async (tx) => {
      const old = authenticate(this.storedDevice(await tx.get(devicePath(identity.installationId))), identity);
      if (old.receipt && (receipt.checkedAt < old.receipt.checkedAt || (receipt.checkedAt === old.receipt.checkedAt && receipt.appliedAt <= old.receipt.appliedAt))) return { recorded: false };
      tx.set(devicePath(identity.installationId), this.stamp({ ...old, receipt }));
      return { recorded: true };
    });
  }

  async receipt(input) {
    const identity = validateIdentity(input);
    const device = authenticate(this.storedDevice(await this.store.get(devicePath(identity.installationId))), identity);
    // Return a value copy so callers cannot mutate persisted state in memory.
    return device.receipt ? { ...device.receipt } : null;
  }

  async removeUnregistered(token, timestamp) {
    const rows = await this.store.list('devices', { where: [{ field: 'deviceToken', op: '==', value: token }] });
    for (const { path } of rows) {
      await this.transact(async (tx) => {
        const device = await tx.get(path);
        // A newer re-registration may have occurred while APNs was responding.
        if (device && device.deviceToken === token && (!Number.isFinite(timestamp) || device.updatedAt <= timestamp)) tx.delete(path);
      });
    }
  }

  // Tests and local mode only; the Job pages through devices instead. No limit:
  // expired documents can outnumber the cap until the TTL policy sweeps them,
  // and a limit would hide live registrations behind them.
  async tokens() {
    const now = this.now();
    const rows = await this.store.list('devices');
    const live = rows.map(({ data }) => data).filter((device) => typeof device.deviceToken === 'string' && Number.isFinite(device.updatedAt) && now - device.updatedAt < DEVICE_TTL_MS);
    return [...new Set(live.map((device) => device.deviceToken))];
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
    this.owner = randomUUID();
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
  // The same paged, claimed pass the Job runs, so what the tests drive is what
  // ships. A newer pending revision stops the current pass at its next
  // checkpoint, as the old per-token loop did.
  async drain() {
    while (this.pending && !this.stopped) {
      const revision = this.pending;
      this.pending = null;
      try {
        await broadcastRevision({ store: this.registry.store, registry: this.registry, dispatcher: this.dispatcher, revision, owner: this.owner, concurrency: this.concurrency, pageSize: 200, leaseMs: 120_000, deadlineAt: Infinity, isCancelled: () => this.stopped || this.pending !== null, now: this.registry.now, log: this.log });
      } catch (error) {
        this.log({ event: 'push_batch_failed', code: safeErrorCode(error) });
      }
    }
  }
  async stop() {
    this.stopped = true;
    this.pending = null;
    this.dispatcher?.close();
    await this.running;
  }
}
