import { mkdir, open, rename, stat, readFile, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';
import { ServiceError } from './errors.js';

export async function readJSON(path, maxBytes) {
  try {
    if ((await stat(path)).size > maxBytes) throw new ServiceError('invalid_stored_state');
    return JSON.parse(await readFile(path, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new ServiceError('invalid_stored_state');
  }
}

export async function writeJSON(path, value, maxBytes) {
  const serialized = JSON.stringify(value);
  if (Buffer.byteLength(serialized) > maxBytes) throw new ServiceError('stored_state_too_large');
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.tmp`;
  let handle;
  try {
    handle = await open(temporary, 'w', 0o600);
    await handle.writeFile(serialized);
    await handle.sync();
    await handle.close();
    handle = null;
    await rename(temporary, path);
  } catch {
    throw new ServiceError('storage_unavailable');
  } finally {
    await handle?.close().catch(() => {});
    await unlink(temporary).catch(() => {});
  }
}
