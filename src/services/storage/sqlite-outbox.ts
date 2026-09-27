import * as SQLite from 'expo-sqlite';

import { MAX_SYNC_ATTEMPTS } from './outbox-types';
import type { NewOfflineMutation, OfflineMutation, OutboxStorage } from './outbox-types';

/**
 * Sprint 4 · Task 4.9. Native (iOS/Android) durable outbox: `expo-sqlite`
 * on-device database `bacalsys_offline.db`. Selected for native builds by
 * `outbox-storage.ts` (Metro's `.web.ts` platform resolution picks
 * `web-outbox.ts` instead on web).
 */
const DB_NAME = 'bacalsys_offline.db';

let db: SQLite.SQLiteDatabase | null = null;
async function getDb(): Promise<SQLite.SQLiteDatabase> {
  if (!db) db = await SQLite.openDatabaseAsync(DB_NAME);
  return db;
}

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS offline_mutations (
  id TEXT PRIMARY KEY,
  session_correlation_id TEXT NOT NULL,
  mutation_type TEXT NOT NULL CHECK (mutation_type IN ('START_SESSION', 'RECORD_SET', 'SUBSTITUTE_EXERCISE', 'COMPLETE_SESSION', 'SYNC_BUNDLE')),
  entity_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_attempt_at TEXT NULL,
  last_error TEXT NULL,
  sync_status TEXT NOT NULL CHECK (sync_status IN ('pending', 'syncing', 'synced', 'failed_permanent'))
);
CREATE INDEX IF NOT EXISTS idx_offline_mutations_queue ON offline_mutations (sync_status, created_at, id);
`;

interface Row {
  id: string;
  session_correlation_id: string;
  mutation_type: string;
  entity_id: string;
  payload_json: string;
  created_at: string;
  attempt_count: number;
  last_attempt_at: string | null;
  last_error: string | null;
  sync_status: string;
}

function fromRow(r: Row): OfflineMutation {
  return {
    id: r.id,
    sessionCorrelationId: r.session_correlation_id,
    mutationType: r.mutation_type as OfflineMutation['mutationType'],
    entityId: r.entity_id,
    payload: JSON.parse(r.payload_json),
    createdAt: r.created_at,
    attemptCount: r.attempt_count,
    lastAttemptAt: r.last_attempt_at,
    lastError: r.last_error,
    syncStatus: r.sync_status as OfflineMutation['syncStatus'],
  };
}

export const sqliteOutbox: OutboxStorage = {
  async init() {
    const database = await getDb();
    await database.execAsync(SCHEMA_SQL);
  },

  async enqueue(m: NewOfflineMutation) {
    const database = await getDb();
    await database.runAsync(
      `INSERT INTO offline_mutations
         (id, session_correlation_id, mutation_type, entity_id, payload_json, created_at, attempt_count, sync_status)
       VALUES (?, ?, ?, ?, ?, ?, 0, 'pending')`,
      [m.id, m.sessionCorrelationId, m.mutationType, m.entityId, JSON.stringify(m.payload), m.createdAt],
    );
  },

  async listPending() {
    const database = await getDb();
    const rows = await database.getAllAsync<Row>(
      `SELECT * FROM offline_mutations WHERE sync_status = 'pending' ORDER BY created_at ASC, id ASC`,
    );
    return rows.map(fromRow);
  },

  async listBySessionCorrelation(sessionCorrelationId) {
    const database = await getDb();
    const rows = await database.getAllAsync<Row>(
      `SELECT * FROM offline_mutations WHERE session_correlation_id = ? ORDER BY created_at ASC, id ASC`,
      [sessionCorrelationId],
    );
    return rows.map(fromRow);
  },

  async markSyncing(id) {
    const database = await getDb();
    await database.runAsync(
      `UPDATE offline_mutations SET sync_status = 'syncing', last_attempt_at = ? WHERE id = ?`,
      [new Date().toISOString(), id],
    );
  },

  async markSynced(id) {
    const database = await getDb();
    await database.runAsync(`UPDATE offline_mutations SET sync_status = 'synced' WHERE id = ?`, [id]);
  },

  async markFailed(id, error) {
    const database = await getDb();
    const row = await database.getFirstAsync<{ attempt_count: number }>(
      `SELECT attempt_count FROM offline_mutations WHERE id = ?`,
      [id],
    );
    const attempts = (row?.attempt_count ?? 0) + 1;
    const status = attempts >= MAX_SYNC_ATTEMPTS ? 'failed_permanent' : 'pending';
    await database.runAsync(
      `UPDATE offline_mutations SET attempt_count = ?, last_error = ?, last_attempt_at = ?, sync_status = ? WHERE id = ?`,
      [attempts, error, new Date().toISOString(), status, id],
    );
  },

  async resetStaleSyncing() {
    const database = await getDb();
    await database.runAsync(`UPDATE offline_mutations SET sync_status = 'pending' WHERE sync_status = 'syncing'`);
  },

  async markSessionSynced(sessionCorrelationId) {
    const database = await getDb();
    await database.runAsync(
      `UPDATE offline_mutations SET sync_status = 'synced' WHERE session_correlation_id = ? AND sync_status <> 'synced'`,
      [sessionCorrelationId],
    );
  },

  async retry(id) {
    const database = await getDb();
    await database.runAsync(
      `UPDATE offline_mutations SET sync_status = 'pending', attempt_count = 0, last_error = NULL WHERE id = ?`,
      [id],
    );
  },
};
