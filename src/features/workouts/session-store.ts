import { create } from 'zustand';

import { randomId } from '@/lib/random-id';

import type { ActualSetDraft } from './session-player';
import type { MeasurementMode } from './workout-builder';

/**
 * Sprint 4 · Tasks 4.13–4.14. Holds the one active workout session's local
 * draft across the active-workout and summary screens (Expo Router unmounts
 * a screen when navigating to the next one, so this cannot live in either
 * screen's own component state). Identifies everything by the immutable
 * `workout_item_id` — never a server-generated `session_exercise_id` — so the
 * UI works identically whether the session started online or offline; this
 * mirrors the server's own offline-bundle correlation contract (Task 4.5).
 *
 * Scope note (see Sprint 4 STATUS.md "What was not verified"): this draft is
 * in-memory only and does not survive an app process kill. The durable
 * offline outbox rows it may have already enqueued DO survive on disk and
 * still sync once the app reopens; only the athlete's own local view of an
 * in-progress session (and any not-yet-submitted set they were mid-typing) is
 * not recovered across a kill.
 */

export interface SessionSubstitution {
  originalWorkoutItemId: string;
  replacementExerciseId: string;
  replacementExerciseName: string;
  performedMeasurementMode: MeasurementMode;
  reasonCode: string;
}

export interface LoggedSet {
  workoutItemId: string;
  setNumber: number;
  prescribedItemSetId: string | null;
  draft: ActualSetDraft;
}

export interface ActiveSession {
  sessionCorrelationId: string;
  workoutVersionId: string;
  /** Sprint 5: the assigned occurrence this session executes, or null for a direct, unassigned workout. */
  assignmentOccurrenceId: string | null;
  /** Known once start_workout_session resolves — immediately online, or after a later offline replay. */
  sessionId: string | null;
  exerciseMapping: Record<string, string>;
  startedAt: string; // ISO 8601, captured once at begin()
  substitutions: Record<string, SessionSubstitution>;
  loggedSets: Record<string, LoggedSet[]>;
}

interface WorkoutSessionState {
  active: ActiveSession | null;
  begin: (workoutVersionId: string, assignmentOccurrenceId?: string | null) => string;
  setSessionId: (sessionId: string, exerciseMapping: Record<string, string>) => void;
  addSubstitution: (sub: SessionSubstitution) => void;
  addLoggedSet: (entry: LoggedSet) => void;
  clear: () => void;
}

export const useWorkoutSessionStore = create<WorkoutSessionState>((set) => ({
  active: null,

  begin: (workoutVersionId, assignmentOccurrenceId = null) => {
    const sessionCorrelationId = randomId();
    set({
      active: {
        sessionCorrelationId,
        workoutVersionId,
        assignmentOccurrenceId,
        sessionId: null,
        exerciseMapping: {},
        startedAt: new Date().toISOString(),
        substitutions: {},
        loggedSets: {},
      },
    });
    return sessionCorrelationId;
  },

  setSessionId: (sessionId, exerciseMapping) =>
    set((s) => (s.active ? { active: { ...s.active, sessionId, exerciseMapping } } : s)),

  addSubstitution: (sub) =>
    set((s) =>
      s.active
        ? { active: { ...s.active, substitutions: { ...s.active.substitutions, [sub.originalWorkoutItemId]: sub } } }
        : s,
    ),

  addLoggedSet: (entry) =>
    set((s) => {
      if (!s.active) return s;
      const list = s.active.loggedSets[entry.workoutItemId] ?? [];
      return { active: { ...s.active, loggedSets: { ...s.active.loggedSets, [entry.workoutItemId]: [...list, entry] } } };
    }),

  clear: () => set({ active: null }),
}));
