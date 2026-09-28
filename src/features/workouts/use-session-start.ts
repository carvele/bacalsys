import { useEffect, useRef } from 'react';

import { beginOnlineSession, type OnlineStartHandshake } from './session-start';
import { useWorkoutSessionStore } from './session-store';

/**
 * The Workout Player's "begin (or resume) the session" effect, extracted from
 * `workout/active.tsx` so it can be exercised in Jest (the screen itself pulls
 * in native modules Jest cannot load). Every side-effecting dependency is
 * injected; `active.tsx` passes the real Supabase RPC / outbox / connectivity.
 */
export interface SessionStartDeps {
  isOnline: () => boolean;
  /** `start_workout_session` — the 3-arg form when `occurrenceId` is set, else the 2-arg form. */
  startRemote: (args: {
    versionId: string;
    idempotencyKey: string;
    occurrenceId: string | null;
  }) => Promise<{ data: unknown; error: unknown }>;
  persistHandshake: (correlationId: string, handshake: OnlineStartHandshake) => Promise<void>;
  enqueueOfflineStart: (args: { correlationId: string; versionId: string; occurrenceId: string | null }) => Promise<void>;
  newIdempotencyKey: () => string;
  describeError: (error: unknown) => string;
}

export function useSessionStart(args: {
  versionId: string | undefined;
  occurrenceId: string | undefined;
  hierarchyLoading: boolean;
  onStartError: (message: string) => void;
  deps: SessionStartDeps;
}) {
  const { versionId, occurrenceId, hierarchyLoading, onStartError, deps } = args;
  const activeSession = useWorkoutSessionStore((s) => s.active);
  const begin = useWorkoutSessionStore((s) => s.begin);
  const setSessionId = useWorkoutSessionStore((s) => s.setSessionId);

  // F-S5-05: a start's result may be discarded ONLY when the screen unmounts.
  // It must not be tied to this effect's own re-runs: `begin()` below writes
  // `active` into the store, `active` is a dependency of the effect, so the
  // effect re-runs (and its cleanup fires) while the start is still in flight.
  // `startedRef` — not the dependency list — is what guarantees a single start.
  const mountedRef = useRef(true);
  const startedRef = useRef(false);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    if (!versionId || hierarchyLoading || activeSession || startedRef.current) return;
    startedRef.current = true;
    const cancelled = () => !mountedRef.current;
    (async () => {
      const assignmentOccurrenceId = occurrenceId || null; // Sprint 5: an assigned workout carries its occurrence
      const correlationId = begin(versionId, assignmentOccurrenceId);
      const idempotencyKey = deps.newIdempotencyKey();
      if (deps.isOnline()) {
        const { data, error: startError } = await deps.startRemote({
          versionId,
          idempotencyKey,
          occurrenceId: assignmentOccurrenceId,
        });
        if (cancelled()) return;
        if (startError) {
          onStartError(deps.describeError(startError));
        } else {
          const result = data as { session_id: string; exercise_mapping: Record<string, string> };
          // F-S4-02 (narrow re-review): ordering/fail-closed invariant lives
          // in session-start.ts, tested independently of this screen's other
          // concerns — see beginOnlineSession's own doc comment.
          await beginOnlineSession(
            { sessionId: result.session_id, exerciseMapping: result.exercise_mapping ?? {} },
            {
              persistHandshake: (h) => deps.persistHandshake(correlationId, h),
              onReady: (h) => {
                if (!cancelled()) setSessionId(h.sessionId, h.exerciseMapping);
              },
              onError: (err) => {
                if (!cancelled()) onStartError(deps.describeError(err));
              },
            },
          );
        }
      } else {
        await deps.enqueueOfflineStart({ correlationId, versionId, occurrenceId: assignmentOccurrenceId });
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [versionId, hierarchyLoading, activeSession]);
}
