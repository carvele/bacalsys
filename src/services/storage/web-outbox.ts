import { MAX_SYNC_ATTEMPTS } from './outbox-types';
import type { NewOfflineMutation, OfflineMutation, OutboxStorage } from './outbox-types';

/**
 * Sprint 4 · Task 4.9. Web durable outbox: IndexedDB (persistent across
 * reloads, per-origin). A volatile in-memory adapter is used ONLY under Jest
 * (`process.env.NODE_ENV === 'test'`) — jsdom has no IndexedDB, and this
 * module is never used to back a production build's persistence, only its
 * own unit tests. Selected on web by Metro's `.web.ts` resolution via
 * `outbox-storage.web.ts`.
 */
const DB_NAME = 'bacalsys_offline';
const STORE = 'offline_mutations';
const DB_VERSION = 1;
const isTestEnv = process.env.NODE_ENV === 'test';

// ---------------------------------------------------------------------------
// In-memory adapter (Jest only).
// ---------------------------------------------------------------------------
let memoryStore = new Map<string, OfflineMutation>();
/** Test-only: clears the in-memory store between test cases. */
export function __resetInMemoryOutboxForTests() {
  memoryStore = new Map();
}

// ---------------------------------------------------------------------------
// IndexedDB adapter (real web builds).
// ---------------------------------------------------------------------------
function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(STORE)) {
        database.createObjectStore(STORE, { keyPath: 'id' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('Failed to open the offline outbox database'));
  });
}

function withStore<T>(mode: IDBTransactionMode, fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return openDb().then(
    (database) =>
      new Promise<T>((resolve, reject) => {
        const tx = database.transaction(STORE, mode);
        const request = fn(tx.objectStore(STORE));
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error('Offline outbox request failed'));
      }),
  );
}

async function getAll(): Promise<OfflineMutation[]> {
  if (isTestEnv) return [...memoryStore.values()];
  return withStore('readonly', (store) => store.getAll());
}

async function put(mutation: OfflineMutation): Promise<void> {
  if (isTestEnv) {
    memoryStore.set(mutation.id, mutation);
    return;
  }
  await withStore('readwrite', (store) => store.put(mutation));
}

async function getOne(id: string): Promise<OfflineMutation | undefined> {
  if (isTestEnv) return memoryStore.get(id);
  return withStore('readonly', (store) => store.get(id));
}

const sortForQueue = (a: OfflineMutation, b: OfflineMutation) =>
  a.createdAt === b.createdAt ? a.id.localeCompare(b.id) : a.createdAt.localeCompare(b.createdAt);

export const webOutbox: OutboxStorage = {
  async init() {
    if (isTestEnv) return;
    await openDb();
  },

  async enqueue(m: NewOfflineMutation) {
    await put({ ...m, attemptCount: 0, lastAttemptAt: null, lastError: null, syncStatus: 'pending' });
  },

  async listPending() {
    const all = await getAll();
    return all.filter((m) => m.syncStatus === 'pending').sort(sortForQueue);
  },

  async listBySessionCorrelation(sessionCorrelationId) {
    const all = await getAll();
    return all.filter((m) => m.sessionCorrelationId === sessionCorrelationId).sort(sortForQueue);
  },

  async markSyncing(id) {
    const m = await getOne(id);
    if (!m) return;
    await put({ ...m, syncStatus: 'syncing', lastAttemptAt: new Date().toISOString() });
  },

  async markSynced(id) {
    const m = await getOne(id);
    if (!m) return;
    await put({ ...m, syncStatus: 'synced' });
  },

  async markFailed(id, error) {
    const m = await getOne(id);
    if (!m) return;
    const attempts = m.attemptCount + 1;
    await put({
      ...m,
      attemptCount: attempts,
      lastError: error,
      lastAttemptAt: new Date().toISOString(),
      syncStatus: attempts >= MAX_SYNC_ATTEMPTS ? 'failed_permanent' : 'pending',
    });
  },

  async resetStaleSyncing() {
    const all = await getAll();
    await Promise.all(
      all.filter((m) => m.syncStatus === 'syncing').map((m) => put({ ...m, syncStatus: 'pending' })),
    );
  },

  async markSessionSynced(sessionCorrelationId) {
    const all = await getAll();
    await Promise.all(
      all
        .filter((m) => m.sessionCorrelationId === sessionCorrelationId && m.syncStatus !== 'synced')
        .map((m) => put({ ...m, syncStatus: 'synced' })),
    );
  },

  async retry(id) {
    const m = await getOne(id);
    if (!m) return;
    await put({ ...m, syncStatus: 'pending', attemptCount: 0, lastError: null });
  },
};
