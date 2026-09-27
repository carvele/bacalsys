import { onlineManager } from '@tanstack/react-query';

import type { Json } from '@/types/database';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { supabase } from '@/lib/supabase';

import { outboxStorage } from '../storage/outbox-storage';
import { MAX_SYNC_ATTEMPTS, type MutationType, type NewOfflineMutation, type OfflineMutation, type OutboxStorage } from '../storage/outbox-types';

/**
 * Sprint 4 · Task 4.10 — OfflineOutboxService.
 *
 * Online mutations are dispatched directly by the caller through the granular
 * RPCs (start/record/substitute/complete); this service exists strictly for
 * the OFFLINE path: durable local journaling, deterministic FIFO replay with
 * causal-dependency blocking, the online-start reconnection handshake, and
 * terminal SYNC_BUNDLE coalescence.
 *
 *   1. enqueueGranular()  — durably journals one offline mutation (start,
 *      substitute or record-set) while the session is still in progress.
 *   2. enqueueBundle()    — called once, when an offline session reaches a
 *      terminal state: writes a single SYNC_BUNDLE row. From then on the sync
 *      loop dispatches ONLY that row for the session's correlation id; the
 *      granular rows it covers are retired together on success and are never
 *      independently replayed.
 *   3. processQueue()     — FIFO per session_correlation_id, one mutation type
 *      at a time; a failure blocks that session's later mutations (their
 *      dependency isn't satisfied yet) without blocking other sessions.
 *
 * Each mutation's own `id` doubles as its idempotency key. A START_SESSION
 * row is naturally one-per-session, so its id can BE the
 * session_correlation_id; every other row (including SYNC_BUNDLE, so it never
 * collides with that same session's START_SESSION row) gets its own fresh id
 * at enqueue time (src/lib/random-id.ts) — session_correlation_id lives
 * separately as the grouping FIELD on every row, and again inside the
 * bundle payload itself.
 */

const isDueForRetry = (m: OfflineMutation) => {
  if (m.attemptCount === 0 || !m.lastAttemptAt) return true;
  const backoffMs = Math.min(30_000, 1000 * 2 ** m.attemptCount);
  return Date.now() - new Date(m.lastAttemptAt).getTime() >= backoffMs;
};

export interface SessionHandshake {
  sessionId: string;
  /** workout_item_id -> session_exercise_id, from start_workout_session's response. */
  exerciseMapping: Record<string, string>;
}

export function createOfflineOutboxService(storage: OutboxStorage = outboxStorage) {
  let processing = false;
  let unsubscribeOnline: (() => void) | null = null;
  const handshakes = new Map<string, SessionHandshake>();
  const listeners = new Set<() => void>();

  const notify = () => listeners.forEach((l) => l());

  /** Called by the session hook whenever a session_id + exercise_mapping becomes known (online start, or a replayed offline START_SESSION). */
  function persistHandshake(sessionCorrelationId: string, handshake: SessionHandshake) {
    handshakes.set(sessionCorrelationId, handshake);
  }
  function getHandshake(sessionCorrelationId: string) {
    return handshakes.get(sessionCorrelationId);
  }

  async function initialize() {
    await storage.init();
    // Startup stale-syncing recovery: a crash mid-dispatch leaves orphaned 'syncing' rows.
    await storage.resetStaleSyncing();
    unsubscribeOnline = onlineManager.subscribe((isOnline) => {
      if (isOnline) void processQueue();
    });
    if (onlineManager.isOnline()) void processQueue();
  }

  function dispose() {
    unsubscribeOnline?.();
    unsubscribeOnline = null;
  }

  async function enqueueGranular(args: {
    id: string;
    sessionCorrelationId: string;
    mutationType: Extract<MutationType, 'START_SESSION' | 'RECORD_SET' | 'SUBSTITUTE_EXERCISE'>;
    entityId: string;
    payload: Json;
  }) {
    const mutation: NewOfflineMutation = { ...args, createdAt: new Date().toISOString() };
    await storage.enqueue(mutation);
    notify();
    if (onlineManager.isOnline()) void processQueue();
  }

  /** Enqueues the single coalesced SYNC_BUNDLE row for a session reaching a terminal state offline. */
  async function enqueueBundle(sessionCorrelationId: string, bundle: Json) {
    await storage.enqueue({
      id: randomId(),
      sessionCorrelationId,
      mutationType: 'SYNC_BUNDLE',
      entityId: sessionCorrelationId,
      payload: bundle,
      createdAt: new Date().toISOString(),
    });
    notify();
    if (onlineManager.isOnline()) void processQueue();
  }

  function resolveSessionId(mutation: OfflineMutation): string | null {
    const payload = mutation.payload as Record<string, unknown>;
    if (typeof payload.session_id === 'string') return payload.session_id;
    return getHandshake(mutation.sessionCorrelationId)?.sessionId ?? null;
  }

  async function dispatchOne(mutation: OfflineMutation): Promise<{ ok: true } | { ok: false; error: string }> {
    try {
      switch (mutation.mutationType) {
        case 'START_SESSION': {
          const payload = mutation.payload as { workout_version_id: string };
          const { data, error } = await supabase.rpc('start_workout_session', {
            p_workout_version_id: payload.workout_version_id,
            p_idempotency_key: mutation.id,
          });
          if (error) throw error;
          const result = data as { session_id: string; exercise_mapping: Record<string, string> };
          persistHandshake(mutation.sessionCorrelationId, {
            sessionId: result.session_id,
            exerciseMapping: result.exercise_mapping ?? {},
          });
          return { ok: true };
        }
        case 'SUBSTITUTE_EXERCISE': {
          const sessionId = resolveSessionId(mutation);
          if (!sessionId) return { ok: false, error: 'Waiting for the session to sync first.' };
          const payload = mutation.payload as {
            original_workout_item_id: string;
            replacement_exercise_id: string;
            performed_measurement_mode: string;
            reason_code: string;
          };
          const { error } = await supabase.rpc('record_exercise_substitution', {
            p_session_id: sessionId,
            p_original_workout_item_id: payload.original_workout_item_id,
            p_replacement_exercise_id: payload.replacement_exercise_id,
            p_performed_measurement_mode: payload.performed_measurement_mode,
            p_reason_code: payload.reason_code,
            p_idempotency_key: mutation.id,
          });
          if (error) throw error;
          return { ok: true };
        }
        case 'RECORD_SET': {
          const sessionId = resolveSessionId(mutation);
          if (!sessionId) return { ok: false, error: 'Waiting for the session to sync first.' };
          const payload = mutation.payload as { workout_item_id: string; set_data: Json };
          const sessionExerciseId = getHandshake(mutation.sessionCorrelationId)?.exerciseMapping[payload.workout_item_id];
          if (!sessionExerciseId) return { ok: false, error: 'Waiting for the exercise mapping to sync first.' };
          const { error } = await supabase.rpc('record_session_set', {
            p_session_id: sessionId,
            p_session_exercise_id: sessionExerciseId,
            p_set_data: payload.set_data,
            p_idempotency_key: mutation.id,
          });
          if (error) throw error;
          return { ok: true };
        }
        case 'SYNC_BUNDLE': {
          const { error } = await supabase.rpc('sync_offline_session_bundle', {
            p_bundle: mutation.payload,
            p_idempotency_key: mutation.id,
          });
          if (error) throw error;
          return { ok: true };
        }
        case 'COMPLETE_SESSION': {
          // Never enqueued directly by the client (a terminal transition while
          // offline always produces a SYNC_BUNDLE instead); handled here only
          // for schema symmetry / defensive completeness.
          const sessionId = resolveSessionId(mutation);
          if (!sessionId) return { ok: false, error: 'Waiting for the session to sync first.' };
          const payload = mutation.payload as {
            status: 'completed' | 'abandoned';
            abandonment_reason_code: string | null;
            feedback: Json | null;
            private_feedback: Json | null;
          };
          const { error } = await supabase.rpc('complete_workout_session', {
            p_session_id: sessionId,
            p_status: payload.status,
            // The generated RPC arg types don't mark these nullable, but the
            // server column/param accepts NULL regardless (no default was declared).
            p_abandonment_reason_code: payload.abandonment_reason_code as string,
            p_feedback: payload.feedback as Json,
            p_private_feedback: payload.private_feedback as Json,
            p_idempotency_key: mutation.id,
          });
          if (error) throw error;
          return { ok: true };
        }
        default:
          return { ok: false, error: `Unknown mutation type ${mutation.mutationType as string}` };
      }
    } catch (err) {
      return { ok: false, error: describeError(err) };
    }
  }

  async function processQueue(): Promise<void> {
    if (processing) return;
    processing = true;
    try {
      const pending = await storage.listPending();
      const order: string[] = [];
      const groups = new Map<string, OfflineMutation[]>();
      for (const m of pending) {
        if (!groups.has(m.sessionCorrelationId)) order.push(m.sessionCorrelationId);
        groups.set(m.sessionCorrelationId, [...(groups.get(m.sessionCorrelationId) ?? []), m]);
      }

      for (const correlationId of order) {
        const mutations = groups.get(correlationId)!;
        // A SYNC_BUNDLE covers every other pending row for this session: dispatch it alone.
        const bundle = mutations.find((m) => m.mutationType === 'SYNC_BUNDLE');
        const queue = bundle ? [bundle] : mutations;

        for (const mutation of queue) {
          if (!isDueForRetry(mutation)) continue;
          await storage.markSyncing(mutation.id);
          const result = await dispatchOne(mutation);
          if (result.ok) {
            if (mutation.mutationType === 'SYNC_BUNDLE') {
              await storage.markSessionSynced(correlationId);
            } else {
              await storage.markSynced(mutation.id);
            }
          } else {
            await storage.markFailed(mutation.id, result.error);
            notify();
            break; // Causal dependency blocking: later mutations in THIS session wait; other sessions proceed.
          }
        }
      }
      notify();
    } finally {
      processing = false;
    }
  }

  async function retry(id: string) {
    await storage.retry(id);
    notify();
    if (onlineManager.isOnline()) void processQueue();
  }

  async function pendingForSession(sessionCorrelationId: string) {
    return storage.listBySessionCorrelation(sessionCorrelationId);
  }

  function subscribe(listener: () => void) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  return {
    initialize,
    dispose,
    enqueueGranular,
    enqueueBundle,
    persistHandshake,
    getHandshake,
    processQueue,
    retry,
    pendingForSession,
    subscribe,
    /** Test-only escape hatch to inspect dead letters etc. without a UI. */
    _storage: storage,
  };
}

export type OfflineOutboxService = ReturnType<typeof createOfflineOutboxService>;

/** App-wide singleton. Call `.initialize()` once at app startup. */
export const offlineOutboxService = createOfflineOutboxService();

export { MAX_SYNC_ATTEMPTS };
