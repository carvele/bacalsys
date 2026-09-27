import type { Json } from '@/types/database';

/**
 * Sprint 4 · Task 4.9. Shared shape for the durable local outbox journal
 * (native SQLite / web persistent storage), independent of the concrete
 * backend. Mirrors the `offline_mutations` table from Section 11.
 */
export const MUTATION_TYPES = [
  'START_SESSION',
  'RECORD_SET',
  'SUBSTITUTE_EXERCISE',
  'COMPLETE_SESSION',
  'SYNC_BUNDLE',
] as const;
export type MutationType = (typeof MUTATION_TYPES)[number];

export const SYNC_STATUSES = ['pending', 'syncing', 'synced', 'failed_permanent'] as const;
export type SyncStatus = (typeof SYNC_STATUSES)[number];

/** Consecutive failures before a mutation is parked as a dead letter. */
export const MAX_SYNC_ATTEMPTS = 5;

export interface OfflineMutation {
  id: string;
  sessionCorrelationId: string;
  mutationType: MutationType;
  /** The workout_item_id, session_id or other domain id this mutation concerns (diagnostics only). */
  entityId: string;
  payload: Json;
  createdAt: string; // ISO 8601
  attemptCount: number;
  lastAttemptAt: string | null;
  lastError: string | null;
  syncStatus: SyncStatus;
}

export type NewOfflineMutation = Pick<
  OfflineMutation,
  'id' | 'sessionCorrelationId' | 'mutationType' | 'entityId' | 'payload' | 'createdAt'
>;

/**
 * Durable outbox journal. `init()` must be called once before any other
 * method (it creates the schema; it does NOT itself perform stale-syncing
 * recovery — that is an explicit OfflineOutboxService.initialize() step so
 * storage stays a plain CRUD adapter).
 */
export interface OutboxStorage {
  init(): Promise<void>;
  enqueue(mutation: NewOfflineMutation): Promise<void>;
  /** Deterministic FIFO order: created_at ASC, id ASC. */
  listPending(): Promise<OfflineMutation[]>;
  listBySessionCorrelation(sessionCorrelationId: string): Promise<OfflineMutation[]>;
  markSyncing(id: string): Promise<void>;
  markSynced(id: string): Promise<void>;
  /** Increments attempt_count; past MAX_SYNC_ATTEMPTS the row becomes 'failed_permanent'. */
  markFailed(id: string, error: string): Promise<void>;
  /** Boot recovery: any row left 'syncing' by a crash goes back to 'pending'. */
  resetStaleSyncing(): Promise<void>;
  /** Atomically retires (marks 'synced') every row for a session_correlation_id, e.g. after a SYNC_BUNDLE success. */
  markSessionSynced(sessionCorrelationId: string): Promise<void>;
  /** Manual retry (dead-letter UI action): failed_permanent -> pending, attempt_count reset. */
  retry(id: string): Promise<void>;
}
