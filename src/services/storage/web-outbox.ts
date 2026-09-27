import { MAX_SYNC_ATTEMPTS } from './outbox-types';
import type { NewOfflineMutation, OfflineMutation, OutboxStorage, SessionHandshake } from './outbox-types';

/**
 * Sprint 4 · Task 4.9. Web durable outbox: IndexedDB (persistent across
 * reloads, per-origin). A volatile in-memory adapter is used ONLY under Jest
 * (`process.env.NODE_ENV === 'test'`) — jsdom has no IndexedDB, and this
 * module is never used to back a production build's persistence, only its
 * own unit tests. Selected on web by Metro's `.web.ts` resolution via
 * `outbox-storage.web.ts`.
 *
 * F-S4-02: `session_handshakes` is a second, independent object store (and,
 * under Jest, a second in-memory map) — the server handshake for a session
 * must survive exactly as durably as its outbox rows do, and independently of
 * the in-process `OfflineOutboxService` instance that first received it.
 */
const DB_NAME = 'bacalsys_offline';
const MUTATIONS_STORE = 'offline_mutations';
const HANDSHAKES_STORE = 'session_handshakes';
const DB_VERSION = 2;
const isTestEnv = process.env.NODE_ENV === 'test';

interface HandshakeRecord extends SessionHandshake {
  sessionCorrelationId: string;
}

// ---------------------------------------------------------------------------
// In-memory adapter (Jest only).
// ---------------------------------------------------------------------------
let memoryStore = new Map<string, OfflineMutation>();
let memoryHandshakes = new Map<string, SessionHandshake>();
/** Test-only: clears the in-memory stores between test cases. */
export function __resetInMemoryOutboxForTests() {
  memoryStore = new Map();
  memoryHandshakes = new Map();
}

// ---------------------------------------------------------------------------
// IndexedDB adapter (real web builds).
// ---------------------------------------------------------------------------
function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(MUTATIONS_STORE)) {
        database.createObjectStore(MUTATIONS_STORE, { keyPath: 'id' });
      }
      if (!database.objectStoreNames.contains(HANDSHAKES_STORE)) {
        database.createObjectStore(HANDSHAKES_STORE, { keyPath: 'sessionCorrelationId' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('Failed to open the offline outbox database'));
  });
}

function withStore<T>(storeName: string, mode: IDBTransactionMode, fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return openDb().then(
    (database) =>
      new Promise<T>((resolve, reject) => {
        const tx = database.transaction(storeName, mode);
        const request = fn(tx.objectStore(storeName));
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error('Offline outbox request failed'));
      }),
  );
}

async function getAll(): Promise<OfflineMutation[]> {
  if (isTestEnv) return [...memoryStore.values()];
  return withStore(MUTATIONS_STORE, 'readonly', (store) => store.getAll());
}

async function put(mutation: OfflineMutation): Promise<void> {
  if (isTestEnv) {
    memoryStore.set(mutation.id, mutation);
    return;
  }
  await withStore(MUTATIONS_STORE, 'readwrite', (store) => store.put(mutation));
}

async function getOne(id: string): Promise<OfflineMutation | undefined> {
  if (isTestEnv) return memoryStore.get(id);
  return withStore(MUTATIONS_STORE, 'readonly', (store) => store.get(id));
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

  async saveHandshake(sessionCorrelationId, handshake) {
    if (isTestEnv) {
      memoryHandshakes.set(sessionCorrelationId, handshake);
      return;
    }
    const record: HandshakeRecord = { sessionCorrelationId, ...handshake };
    await withStore(HANDSHAKES_STORE, 'readwrite', (store) => store.put(record));
  },

  async getHandshake(sessionCorrelationId) {
    if (isTestEnv) return memoryHandshakes.get(sessionCorrelationId) ?? null;
    const record = await withStore<HandshakeRecord | undefined>(HANDSHAKES_STORE, 'readonly', (store) =>
      store.get(sessionCorrelationId),
    );
    if (!record) return null;
    return { sessionId: record.sessionId, exerciseMapping: record.exerciseMapping };
  },
};
