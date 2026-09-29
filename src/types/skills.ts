import type { Database } from '@/types/database';

/**
 * Sprint 6 · Task 6.10 — client models for training history, session replay,
 * summary statistics and the calisthenics skill trees.
 *
 * Table rows are the generated Supabase types. The RPC results that arrive as
 * untyped `jsonb` (session replay, summary metrics, mutation receipts) are
 * validated by the hand-written parsers below rather than a schema library:
 * the roadmap allows no new framework without an ADR, and these shapes are small
 * and fixed by the migrations. A parser never throws on a missing optional
 * field; it throws only when the payload is not the expected kind of object at
 * all, so a screen fails loudly instead of rendering garbage.
 */

type Tables = Database['public']['Tables'];
export type SkillRow = Tables['skills']['Row'];
export type SkillProgressionRow = Tables['skill_progressions']['Row'];
export type AthleteSkillStatusRow = Tables['athlete_skill_status']['Row'];
export type SkillAttemptRow = Tables['skill_attempts']['Row'];
export type SkillAchievementRow = Tables['skill_achievements']['Row'];

export const SKILL_CATEGORIES = ['push', 'pull', 'core', 'legs', 'hand_balancing', 'other'] as const;
export type SkillCategory = (typeof SKILL_CATEGORIES)[number];
export const SKILL_CATEGORY_LABEL: Record<SkillCategory, string> = {
  push: 'Push',
  pull: 'Pull',
  core: 'Core',
  legs: 'Legs',
  hand_balancing: 'Hand balancing',
  other: 'Other',
};
export const skillCategoryLabel = (c: string) => SKILL_CATEGORY_LABEL[c as SkillCategory] ?? c;

export const ATTEMPT_STATUSES = ['pending_review', 'approved', 'rejected'] as const;
export type AttemptStatus = (typeof ATTEMPT_STATUSES)[number];
export const ACHIEVEMENT_STATUSES = ['active', 'expired', 'revoked'] as const;
export type AchievementStatus = (typeof ACHIEVEMENT_STATUSES)[number];

// -- Session replay (public.get_session_replay) -------------------------------------------------

export interface ReplaySet {
  setNumber: number;
  prescribedItemSetId: string | null;
  sessionSetId: string | null;
  targetReps: number | null;
  targetLoadKg: number | null;
  targetLoadType: string | null;
  targetDurationSeconds: number | null;
  targetDistanceMeters: number | null;
  targetRestSeconds: number | null;
  targetRpe: number | null;
  actualReps: number | null;
  actualLoadKg: number | null;
  actualLoadType: string | null;
  actualDurationSeconds: number | null;
  actualDistanceMeters: number | null;
  actualRestSeconds: number | null;
  rpe: number | null;
  isCompleted: boolean;
  /** A prescribed set that was never logged, or was logged as not completed. */
  isSkipped: boolean;
  /** An athlete-added set with no prescription (session_sets.prescribed_item_set_id IS NULL). */
  isExtra: boolean;
}

export interface ReplayItem {
  workoutItemId: string;
  blockTitle: string;
  orderInBlock: number;
  prescribedExerciseName: string;
  prescribedCategory: string;
  prescribedMeasurementMode: string;
  isSubstituted: boolean;
  performedExerciseName: string | null;
  performedMeasurementMode: string | null;
  sets: ReplaySet[];
}

export interface ReplaySubstitution {
  id: string;
  originalWorkoutItemId: string;
  replacementExerciseName: string;
  reasonCode: string;
}

export interface SessionReplay {
  session: {
    id: string;
    athleteId: string;
    workoutVersionId: string;
    assignmentOccurrenceId: string | null;
    status: string;
    startedAt: string;
    completedAt: string | null;
    abandonmentReasonCode: string | null;
  };
  feedback: { difficultyRating: number; energyLevel: number } | null;
  /** null when the viewer may not read it (Rule E) — never an empty object. */
  privateFeedback: { hasDiscomfort: boolean; discomfortArea: string | null; noteToCoach: string | null } | null;
  substitutions: ReplaySubstitution[];
  items: ReplayItem[];
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const obj = (v: unknown, what: string): Obj => {
  if (!isObj(v)) throw new Error(`${what} is not an object`);
  return v;
};
const str = (v: unknown): string | null => (typeof v === 'string' ? v : null);
const reqStr = (v: unknown, what: string): string => {
  if (typeof v !== 'string') throw new Error(`${what} is missing`);
  return v;
};
/** Postgres numerics can arrive as numbers or numeric strings. */
const num = (v: unknown): number | null => {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) return Number(v);
  return null;
};
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

export function parseReplaySet(raw: unknown): ReplaySet {
  const s = obj(raw, 'replay set');
  return {
    setNumber: num(s.set_number) ?? 0,
    prescribedItemSetId: str(s.prescribed_item_set_id),
    sessionSetId: str(s.session_set_id),
    targetReps: num(s.target_reps),
    targetLoadKg: num(s.target_load_kg),
    targetLoadType: str(s.target_load_type),
    targetDurationSeconds: num(s.target_duration_seconds),
    targetDistanceMeters: num(s.target_distance_meters),
    targetRestSeconds: num(s.target_rest_seconds),
    targetRpe: num(s.target_rpe),
    actualReps: num(s.actual_reps),
    actualLoadKg: num(s.actual_load_kg),
    actualLoadType: str(s.actual_load_type),
    actualDurationSeconds: num(s.actual_duration_seconds),
    actualDistanceMeters: num(s.actual_distance_meters),
    actualRestSeconds: num(s.actual_rest_seconds),
    rpe: num(s.rpe),
    isCompleted: s.is_completed === true,
    isSkipped: s.is_skipped === true,
    isExtra: s.is_extra === true,
  };
}

export function parseSessionReplay(raw: unknown): SessionReplay {
  const r = obj(raw, 'session replay');
  const s = obj(r.session, 'replay session');
  const fb = isObj(r.feedback) ? r.feedback : null;
  const pf = isObj(r.private_feedback) ? r.private_feedback : null;
  return {
    session: {
      id: reqStr(s.id, 'session id'),
      athleteId: reqStr(s.athlete_id, 'athlete id'),
      workoutVersionId: reqStr(s.workout_version_id, 'workout version id'),
      assignmentOccurrenceId: str(s.assignment_occurrence_id),
      status: reqStr(s.status, 'session status'),
      startedAt: reqStr(s.started_at, 'started_at'),
      completedAt: str(s.completed_at),
      abandonmentReasonCode: str(s.abandonment_reason_code),
    },
    feedback: fb ? { difficultyRating: num(fb.difficulty_rating) ?? 0, energyLevel: num(fb.energy_level) ?? 0 } : null,
    privateFeedback: pf
      ? { hasDiscomfort: pf.has_discomfort === true, discomfortArea: str(pf.discomfort_area), noteToCoach: str(pf.note_to_coach) }
      : null,
    substitutions: arr(r.substitutions).map((x) => {
      const o = obj(x, 'substitution');
      return {
        id: reqStr(o.id, 'substitution id'),
        originalWorkoutItemId: reqStr(o.original_workout_item_id, 'original item'),
        replacementExerciseName: str(o.replacement_exercise_name) ?? 'Another exercise',
        reasonCode: str(o.reason_code) ?? 'other',
      };
    }),
    items: arr(r.items).map((x) => {
      const o = obj(x, 'replay item');
      return {
        workoutItemId: reqStr(o.workout_item_id, 'item id'),
        blockTitle: str(o.block_title) ?? '',
        orderInBlock: num(o.order_in_block) ?? 0,
        prescribedExerciseName: str(o.prescribed_exercise_name) ?? 'Exercise',
        prescribedCategory: str(o.prescribed_category) ?? '',
        prescribedMeasurementMode: str(o.prescribed_measurement_mode) ?? 'reps',
        isSubstituted: o.is_substituted === true,
        performedExerciseName: str(o.performed_exercise_name),
        performedMeasurementMode: str(o.performed_measurement_mode),
        sets: arr(o.sets).map(parseReplaySet),
      };
    }),
  };
}

// -- Summary metrics (public.get_my_athlete_summary / get_athlete_summary) ------------------------

export interface CategoryVolume {
  category: string;
  sets: number;
  reps: number;
  durationSeconds: number;
}

export interface AthleteSummary {
  athleteId: string;
  timezone: string;
  windowStart: string;
  windowEnd: string;
  scheduledWorkouts: number;
  completedWorkouts: number;
  partiallyCompletedWorkouts: number;
  abandonedWorkouts: number;
  missedWorkouts: number;
  /** null when nothing was due in the window — never 0 %. */
  adherenceRate: number | null;
  totalSessionsCompleted: number;
  totalSessionsAbandoned: number;
  totalCompletedSets: number;
  totalReps: number;
  totalDurationSeconds: number;
  volumeByCategory: CategoryVolume[];
}

export function parseAthleteSummary(raw: unknown): AthleteSummary {
  const s = obj(raw, 'athlete summary');
  return {
    athleteId: reqStr(s.athlete_id, 'athlete id'),
    timezone: str(s.timezone) ?? 'Asia/Manila',
    windowStart: reqStr(s.window_start, 'window_start'),
    windowEnd: reqStr(s.window_end, 'window_end'),
    scheduledWorkouts: num(s.scheduled_workouts) ?? 0,
    completedWorkouts: num(s.completed_workouts) ?? 0,
    partiallyCompletedWorkouts: num(s.partially_completed_workouts) ?? 0,
    abandonedWorkouts: num(s.abandoned_workouts) ?? 0,
    missedWorkouts: num(s.missed_workouts) ?? 0,
    adherenceRate: num(s.adherence_rate),
    totalSessionsCompleted: num(s.total_sessions_completed) ?? 0,
    totalSessionsAbandoned: num(s.total_sessions_abandoned) ?? 0,
    totalCompletedSets: num(s.total_completed_sets) ?? 0,
    totalReps: num(s.total_reps) ?? 0,
    totalDurationSeconds: num(s.total_duration_seconds) ?? 0,
    volumeByCategory: arr(s.volume_by_category).map((x) => {
      const o = obj(x, 'category volume');
      return {
        category: str(o.category) ?? 'other',
        sets: num(o.sets) ?? 0,
        reps: num(o.reps) ?? 0,
        durationSeconds: num(o.duration_seconds) ?? 0,
      };
    }),
  };
}

// -- Skill mutation receipts ------------------------------------------------------------------------

export interface ReviewReceipt {
  attemptId: string;
  status: 'approved' | 'rejected';
  achievementId: string | null;
}

export function parseReviewReceipt(raw: unknown): ReviewReceipt {
  const r = obj(raw, 'review receipt');
  const status = reqStr(r.status, 'status');
  if (status !== 'approved' && status !== 'rejected') throw new Error(`unexpected review status ${status}`);
  return { attemptId: reqStr(r.attempt_id, 'attempt id'), status, achievementId: str(r.achievement_id) };
}
