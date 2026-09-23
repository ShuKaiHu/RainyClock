import { Firestore } from '@google-cloud/firestore';
import { ServiceError } from './errors.js';
import { createFirestoreStore } from './store.js';

// Shared by the Job and the request-only service. Validation happens before
// any client is built so a misconfigured deployment fails at startup rather
// than on the first request. The membership databases live in the same
// project; the explicit database id and the demo- rule under the emulator
// are what keep this service from ever touching them.
const PROJECT_ID = /^[a-z][a-z0-9-]{4,61}[a-z0-9]$/;
const DATABASE_ID = /^[a-z][a-z0-9-]{2,61}[a-z0-9]$/;
const NAMESPACE = /^[a-zA-Z0-9_-]{1,100}$/;

export function firestoreConfiguration(env = process.env) {
  const projectId = env.DAYOFF_FIRESTORE_PROJECT || env.GOOGLE_CLOUD_PROJECT;
  const emulatorHost = env.FIRESTORE_EMULATOR_HOST || null;
  if (typeof projectId !== 'string' || !PROJECT_ID.test(projectId) || (emulatorHost && !projectId.startsWith('demo-'))) {
    throw new ServiceError('unsafe_firestore_project');
  }
  // DATABASE_ID cannot match "(default)": the shared default database is never
  // an acceptable fallback for this service.
  const databaseId = env.DAYOFF_FIRESTORE_DATABASE;
  if (typeof databaseId !== 'string' || !DATABASE_ID.test(databaseId)) throw new ServiceError('invalid_configuration');
  const namespace = env.DAYOFF_NAMESPACE ?? 'dayoff_production_v1';
  if (!NAMESPACE.test(namespace)) throw new ServiceError('invalid_configuration');
  return { projectId, databaseId, namespace, emulatorHost };
}

// A blank value counts as unset so a copied .env.example with empty lines
// runs on its defaults; anything else must be a whole number in range.
export function integerSetting(env, name, fallback, min, max) {
  const value = env[name]?.trim() || String(fallback);
  if (!/^\d+$/.test(value) || Number(value) < min || Number(value) > max) throw new ServiceError('invalid_configuration');
  return Number(value);
}

export function createStoreFromEnv(env = process.env) {
  const { projectId, databaseId, namespace, emulatorHost } = firestoreConfiguration(env);
  const firestore = new Firestore({ projectId, databaseId, ...(emulatorHost ? { host: emulatorHost, ssl: false } : {}) });
  return { store: createFirestoreStore({ firestore, namespace }), close: () => firestore.terminate() };
}
