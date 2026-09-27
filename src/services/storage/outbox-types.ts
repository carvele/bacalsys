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
 * The server identity a session acquires once `start_workout_session`
 * resolves (online, or via a replayed offline `START_SESSION`): its real
 * `session_id`, and the `workout_item_id -> session_exercise_id` mapping
 * every subsequent `RECORD_SET` needs to resolve `p_session_exercise_id`.
 *
 * F-S4-02 (Reviewer gate rework): this MUST be durable, not merely held in an
 * in-process `Map` — a `RECORD_SET` or `SUBSTITUTE_EXERCISE` mutation can
 * still be `pending` in `offline_mutations` long after its session's
 * `START_SESSION` row has already synced and been marked `synced`, so an
 * app-process restart has no other way to recover it.
 */
export interface SessionHandshake {
  sessionId: string;
  exerciseMapping: Record<string, string>;
}

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
  /**
   * F-S4-02: durably records the server handshake for a session, keyed by
   * `session_correlation_id`, so it survives an app/process restart —
   * upserts (a session has exactly one handshake, written once).
   */
  saveHandshake(sessionCorrelationId: string, handshake: SessionHandshake): Promise<void>;
  /** F-S4-02: reads the durable handshake back, or null if this session never got one (still fully offline, or never started). */
  getHandshake(sessionCorrelationId: string): Promise<SessionHandshake | null>;
}
