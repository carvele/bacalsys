/**
 * F-S4-02 (Reviewer's second narrow re-review). Decides which top-level state
 * `workout/active.tsx` should render, as a small pure function independent of
 * the screen's native/query dependencies, so the priority ordering between
 * "still starting" and "the start failed" is directly testable.
 *
 * The bug this fixes: `onError` correctly calls `setError(...)` and correctly
 * never calls `setSessionId(...)` when the durable handshake write fails —
 * but `sessionId` staying `null` also keeps `isAwaitingStart` true, and the
 * screen checked `isAwaitingStart` (→ spinner) BEFORE checking whether a
 * start error existed. The athlete saw an indefinite "Starting your
 * workout…" spinner with the error notice unreachable beneath it.
 *
 * Fix: a start/persistence error, while still awaiting start, must outrank
 * the spinner. It must NOT trigger a new `start_workout_session` call (that
 * would risk a duplicate server session over what may be a purely
 * client-storage failure) — this function only decides what to render; it
 * never re-triggers the start flow.
 */
export type WorkoutScreenState =
  | { kind: 'loading' }
  | { kind: 'start-error'; message: string }
  | { kind: 'starting' }
  | { kind: 'hierarchy-error' }
  | { kind: 'empty' }
  | { kind: 'ready' };

export function resolveWorkoutScreenState(input: {
  hasVersionId: boolean;
  isAwaitingStart: boolean;
  startError: string | null;
  hierarchyLoading: boolean;
  hierarchyError: boolean;
  stepsCount: number;
}): WorkoutScreenState {
  if (!input.hasVersionId) return { kind: 'loading' };
  // Must be checked before the "starting" spinner below: a start/persistence
  // failure keeps `isAwaitingStart` true (by design — the session must never
  // be exposed as ready), so without this check the error is unreachable.
  if (input.isAwaitingStart && input.startError) {
    return { kind: 'start-error', message: input.startError };
  }
  if (input.hierarchyLoading || input.isAwaitingStart) return { kind: 'starting' };
  if (input.hierarchyError) return { kind: 'hierarchy-error' };
  if (input.stepsCount === 0) return { kind: 'empty' };
  return { kind: 'ready' };
}
