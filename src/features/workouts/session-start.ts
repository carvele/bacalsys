/**
 * F-S4-02 (Reviewer narrow re-review). Encapsulates the online-start ordering
 * invariant on its own, independent of `workout/active.tsx`'s other concerns
 * (hierarchy fetch, rest timer, etc. — the rest timer alone pulls in
 * expo-audio/expo-haptics/expo-notifications, native modules Jest cannot
 * load), so this one, specific correctness property is directly testable:
 *
 *   start_workout_session succeeds
 *   → persist session_id + exercise_mapping durably
 *   → ONLY once that persistence succeeds, expose the session as ready
 *   → if the durable write rejects, the session is NEVER exposed as ready
 *
 * `setSessionId` (Zustand) is synchronous, so calling it before the durable
 * write resolves would let the Workout Player act on a session whose
 * recovery identity might never have been persisted — the exact race the
 * Reviewer's narrow re-review found in the original ordering.
 */
export interface OnlineStartHandshake {
  sessionId: string;
  exerciseMapping: Record<string, string>;
}

export async function beginOnlineSession(
  handshake: OnlineStartHandshake,
  deps: {
    persistHandshake: (handshake: OnlineStartHandshake) => Promise<void>;
    /** Called only after persistHandshake resolves — this is what makes the session "ready". */
    onReady: (handshake: OnlineStartHandshake) => void;
    /** Called instead of onReady if persistHandshake rejects. The session is never exposed as ready. */
    onError: (error: unknown) => void;
  },
): Promise<void> {
  try {
    await deps.persistHandshake(handshake);
  } catch (error) {
    deps.onError(error);
    return;
  }
  deps.onReady(handshake);
}
