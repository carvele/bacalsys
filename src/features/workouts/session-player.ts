import type { Json } from '@/types/database';

import { type LoadType, type MeasurementMode, labelFor } from './workout-builder';

/**
 * Sprint 4 · Tasks 4.9–4.13. Client-side mirror of
 * `app_private.validate_session_set` / `app_private.validate_abandonment`, so
 * the Workout Player gives field-level errors before a round trip. The
 * database stays authoritative: every rule here is re-checked server-side
 * inside `record_session_set` / `complete_workout_session` /
 * `sync_offline_session_bundle`.
 *
 * Design note (mirrors the server's documented design decision — see Sprint 4
 * STATUS.md): mode exclusivity always applies, but the PRESENCE of the mode's
 * primary metric is required only when `isCompleted` is true, so an athlete
 * can log "attempted, not completed" without a number.
 */

export const ABANDONMENT_REASONS = [
  'time_constraint',
  'equipment_issue',
  'general_fatigue',
  'personal_emergency',
  'facility_closed',
  'other',
] as const;
export type AbandonmentReason = (typeof ABANDONMENT_REASONS)[number];

export const MODIFICATION_REASONS = [
  'equipment_unavailable',
  'pain_discomfort',
  'too_difficult',
  'too_easy',
  'injury_limitation',
  'personal_adjustment',
  'other',
] as const;
export type ModificationReason = (typeof MODIFICATION_REASONS)[number];

export interface ActualSetDraft {
  actualReps: string;
  actualDurationSeconds: string;
  actualDistanceMeters: string;
  actualLoadKg: string;
  loadType: LoadType | null;
  actualRestSeconds: string;
  rpe: string;
  isCompleted: boolean;
}

export const emptyActualSet = (): ActualSetDraft => ({
  actualReps: '',
  actualDurationSeconds: '',
  actualDistanceMeters: '',
  actualLoadKg: '',
  loadType: null,
  actualRestSeconds: '',
  rpe: '',
  isCompleted: true,
});

const toNumber = (s: string) => (s.trim() === '' ? null : Number(s));

/** Mirrors app_private.validate_session_set. */
export function validateActualSet(mode: MeasurementMode, s: ActualSetDraft): string | null {
  const reps = toNumber(s.actualReps);
  const duration = toNumber(s.actualDurationSeconds);
  const distance = toNumber(s.actualDistanceMeters);
  const load = toNumber(s.actualLoadKg);
  const rest = toNumber(s.actualRestSeconds);
  const rpe = toNumber(s.rpe);

  if (reps !== null && (reps < 0 || reps > 1000)) return 'Reps must be between 0 and 1000.';
  if (duration !== null && (duration < 0 || duration > 7200)) return 'Duration must be between 0 and 7200 seconds.';
  if (distance !== null && (distance < 0 || distance > 100000)) return 'Distance must be between 0 and 100000 m.';
  if (load !== null && (load < 0 || load > 500)) return 'Load must be between 0 and 500 kg.';
  if (rest !== null && (rest < 0 || rest > 1800)) return 'Rest must be between 0 and 1800 seconds.';
  if (rpe !== null && (rpe < 1 || rpe > 10)) return 'RPE must be between 1 and 10.';

  if (load !== null && load > 0 && s.loadType !== 'added' && s.loadType !== 'assisted') {
    return 'A load greater than 0 needs load type added or assisted.';
  }
  if ((load === null || load === 0) && s.loadType && s.loadType !== 'bodyweight') {
    return `Load type ${labelFor(s.loadType).toLowerCase()} needs a load greater than 0.`;
  }

  const { isCompleted } = s;
  switch (mode) {
    case 'reps':
      if (isCompleted && reps === null) return 'Enter the reps completed.';
      if (duration !== null || distance !== null || load !== null) return 'A reps set takes only reps.';
      return null;
    case 'duration':
    case 'holds':
      if (isCompleted && duration === null) return 'Enter the duration completed.';
      if (reps !== null || distance !== null || load !== null) return 'This set takes only a duration.';
      return null;
    case 'distance':
      if (isCompleted && distance === null) return 'Enter the distance completed.';
      if (reps !== null || load !== null) return 'A distance set takes no reps or load.';
      return null;
    case 'added_weight':
      if (load !== null && s.loadType !== 'added') return "An added-weight set's load must be typed added.";
      if (isCompleted && (load === null || load <= 0)) return 'Enter a load greater than 0.';
      if (isCompleted && reps === null && duration === null) return 'Enter reps or a duration alongside the load.';
      if (distance !== null) return 'An added-weight set takes no distance.';
      return null;
    case 'assisted_weight':
      if (load !== null && s.loadType !== 'assisted') return "An assisted set's load must be typed assisted.";
      if (isCompleted && (load === null || load <= 0)) return 'Enter the assistance load used.';
      if (isCompleted && reps === null && duration === null) return 'Enter reps or a duration alongside the assistance.';
      if (distance !== null) return 'An assisted set takes no distance.';
      return null;
    case 'until_failure':
      if (distance !== null) return 'An until-failure set takes no distance.';
      return null;
    case 'technique_practice':
      if (distance !== null || load !== null) return 'A technique set takes no distance or load.';
      return null;
    default:
      return 'Unknown measurement mode.';
  }
}

export const isActualSetValid = (mode: MeasurementMode, s: ActualSetDraft) => validateActualSet(mode, s) === null;

/** Builds the p_set_data jsonb payload record_session_set / a bundle's sets[] entry expect. */
export function buildSetPayload(
  setNumber: number,
  prescribedItemSetId: string | null,
  s: ActualSetDraft,
): Record<string, Json> {
  return {
    set_number: setNumber,
    prescribed_item_set_id: prescribedItemSetId,
    actual_reps: toNumber(s.actualReps),
    actual_duration_seconds: toNumber(s.actualDurationSeconds),
    actual_distance_meters: toNumber(s.actualDistanceMeters),
    actual_load_kg: toNumber(s.actualLoadKg),
    load_type: s.loadType,
    actual_rest_seconds: toNumber(s.actualRestSeconds),
    rpe: toNumber(s.rpe),
    is_completed: s.isCompleted,
  };
}

/** Mirrors app_private.validate_abandonment. Returns an error message, or null if valid. */
export function validateAbandonment(status: 'completed' | 'abandoned', reasonCode: string | null): string | null {
  if (status === 'abandoned') {
    if (!reasonCode || !(ABANDONMENT_REASONS as readonly string[]).includes(reasonCode)) {
      return 'Choose a reason for ending the workout early.';
    }
  } else if (reasonCode) {
    return 'An abandonment reason cannot be set for a completed session.';
  }
  return null;
}

export interface SplitFeedbackDraft {
  difficultyRating: number | null;
  energyLevel: number | null;
  hasDiscomfort: boolean;
  discomfortArea: string;
  noteToCoach: string;
}

export const emptySplitFeedback = (): SplitFeedbackDraft => ({
  difficultyRating: null,
  energyLevel: null,
  hasDiscomfort: false,
  discomfortArea: '',
  noteToCoach: '',
});

/** Builds the p_feedback / p_private_feedback jsonb payloads complete_workout_session expects (or null for either). */
export function buildFeedbackPayloads(f: SplitFeedbackDraft): { feedback: Json | null; privateFeedback: Json | null } {
  const feedback: Json | null =
    f.difficultyRating !== null && f.energyLevel !== null
      ? ({ difficulty_rating: f.difficultyRating, energy_level: f.energyLevel } as unknown as Json)
      : null;
  const privateFeedback: Json | null = f.hasDiscomfort
    ? ({
        has_discomfort: true,
        discomfort_area: f.discomfortArea.trim() || null,
        note_to_coach: f.noteToCoach.trim() || null,
      } as unknown as Json)
    : f.noteToCoach.trim()
      ? ({ has_discomfort: false, discomfort_area: null, note_to_coach: f.noteToCoach.trim() } as unknown as Json)
      : null;
  return { feedback, privateFeedback };
}

export interface OfflineBundleInput {
  sessionCorrelationId: string;
  existingSessionId: string | null;
  workoutVersionId: string;
  status: 'completed' | 'abandoned';
  abandonmentReasonCode: string | null;
  startedAt: string;
  completedAt: string;
  substitutions: {
    originalWorkoutItemId: string;
    replacementExerciseId: string;
    performedMeasurementMode: string;
    reasonCode: string;
  }[];
  sets: { workoutItemId: string; setNumber: number; prescribedItemSetId: string | null; draft: ActualSetDraft }[];
  feedback: Json | null;
  privateFeedback: Json | null;
}

/** Builds the p_bundle jsonb payload sync_offline_session_bundle expects (Task 4.5's wire format). */
export function buildOfflineBundle(input: OfflineBundleInput): Json {
  return {
    session_correlation_id: input.sessionCorrelationId,
    existing_session_id: input.existingSessionId,
    workout_version_id: input.workoutVersionId,
    status: input.status,
    abandonment_reason_code: input.abandonmentReasonCode,
    started_at: input.startedAt,
    completed_at: input.completedAt,
    substitutions: input.substitutions.map((s) => ({
      original_workout_item_id: s.originalWorkoutItemId,
      replacement_exercise_id: s.replacementExerciseId,
      performed_measurement_mode: s.performedMeasurementMode,
      reason_code: s.reasonCode,
    })),
    sets: input.sets.map((s) => ({
      workout_item_id: s.workoutItemId,
      ...buildSetPayload(s.setNumber, s.prescribedItemSetId, s.draft),
    })),
    feedback: input.feedback,
    private_feedback: input.privateFeedback,
  } as unknown as Json;
}

/** One-line summary of an actual set, mirrors summarizeSet's prescribed-target counterpart. */
export function summarizeActual(mode: string, s: ActualSetDraft): string {
  const parts: string[] = [];
  if (s.actualReps.trim() !== '') parts.push(`${s.actualReps} reps`);
  if (s.actualDurationSeconds.trim() !== '') parts.push(`${s.actualDurationSeconds}s`);
  if (s.actualDistanceMeters.trim() !== '') parts.push(`${s.actualDistanceMeters}m`);
  if (s.actualLoadKg.trim() !== '') parts.push(`${s.loadType === 'assisted' ? '−' : '+'}${s.actualLoadKg}kg`);
  if (!s.isCompleted) parts.push('not completed');
  return parts.length ? parts.join(' · ') : labelFor(mode);
}
