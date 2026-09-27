import {
  ABANDONMENT_REASONS,
  buildFeedbackPayloads,
  buildOfflineBundle,
  buildSetPayload,
  emptyActualSet,
  emptySplitFeedback,
  isActualSetValid,
  summarizeActual,
  validateAbandonment,
  validateActualSet,
  type ActualSetDraft,
} from '../session-player';

const setWith = (overrides: Partial<ActualSetDraft>) => ({ ...emptyActualSet(), ...overrides });

describe('validateActualSet (mirrors app_private.validate_session_set)', () => {
  it('reps: a completed set needs actual_reps and nothing else', () => {
    expect(validateActualSet('reps', setWith({ actualReps: '8' }))).toBeNull();
    expect(validateActualSet('reps', emptyActualSet())).toMatch(/reps completed/);
    expect(validateActualSet('reps', setWith({ actualReps: '8', actualDurationSeconds: '10' }))).toMatch(/only reps/);
  });

  it('an INCOMPLETE set does not require the primary metric', () => {
    expect(validateActualSet('reps', setWith({ isCompleted: false }))).toBeNull();
    expect(validateActualSet('duration', setWith({ isCompleted: false }))).toBeNull();
    expect(validateActualSet('added_weight', setWith({ isCompleted: false }))).toBeNull();
  });

  it('duration/holds: a completed set needs actual_duration_seconds only', () => {
    expect(validateActualSet('duration', setWith({ actualDurationSeconds: '30' }))).toBeNull();
    expect(validateActualSet('holds', setWith({ actualDurationSeconds: '20' }))).toBeNull();
    expect(validateActualSet('holds', emptyActualSet())).toMatch(/duration completed/);
    expect(validateActualSet('holds', setWith({ actualDurationSeconds: '20', actualReps: '5' }))).toMatch(/only a duration/);
  });

  it('distance: a completed set needs actual_distance_meters, forbids reps/load', () => {
    expect(validateActualSet('distance', setWith({ actualDistanceMeters: '400' }))).toBeNull();
    expect(validateActualSet('distance', emptyActualSet())).toMatch(/distance completed/);
    expect(validateActualSet('distance', setWith({ actualDistanceMeters: '400', actualReps: '5' }))).toMatch(/no reps or load/);
  });

  it('added_weight: a completed set needs a positive added load plus reps or duration', () => {
    expect(validateActualSet('added_weight', setWith({ actualReps: '5', actualLoadKg: '10', loadType: 'added' }))).toBeNull();
    expect(validateActualSet('added_weight', setWith({ actualReps: '5', actualLoadKg: '10', loadType: 'assisted' }))).toMatch(/typed added/);
    expect(validateActualSet('added_weight', setWith({ actualLoadKg: '10', loadType: 'added' }))).toMatch(/reps or a duration/);
  });

  it('assisted_weight: a completed set needs a positive assisted load plus reps or duration', () => {
    expect(validateActualSet('assisted_weight', setWith({ actualReps: '6', actualLoadKg: '20', loadType: 'assisted' }))).toBeNull();
    expect(validateActualSet('assisted_weight', setWith({ actualReps: '6', actualLoadKg: '20', loadType: 'added' }))).toMatch(/typed assisted/);
  });

  it('until_failure: everything optional except distance', () => {
    expect(validateActualSet('until_failure', emptyActualSet())).toBeNull();
    expect(validateActualSet('until_failure', setWith({ actualDistanceMeters: '5' }))).toMatch(/no distance/);
  });

  it('technique_practice: forbids distance and load only', () => {
    expect(validateActualSet('technique_practice', emptyActualSet())).toBeNull();
    expect(validateActualSet('technique_practice', setWith({ actualLoadKg: '5', loadType: 'added' }))).toMatch(/no distance or load/);
  });

  it('range checks mirror the session_sets CHECK constraints (0-based, unlike the prescription table)', () => {
    expect(validateActualSet('reps', setWith({ actualReps: '0' }))).toBeNull();
    expect(validateActualSet('reps', setWith({ actualReps: '1001' }))).toMatch(/between 0 and 1000/);
    expect(validateActualSet('duration', setWith({ actualDurationSeconds: '-1' }))).toMatch(/between 0 and 7200/);
  });

  it('F-S4-01: a nonzero load with no load type is rejected client-side too', () => {
    expect(validateActualSet('added_weight', setWith({ actualReps: '5', actualLoadKg: '10', loadType: null }))).toMatch(/added or assisted/);
  });

  it('isActualSetValid is a boolean convenience wrapper', () => {
    expect(isActualSetValid('reps', setWith({ actualReps: '8' }))).toBe(true);
    expect(isActualSetValid('reps', emptyActualSet())).toBe(false);
  });
});

describe('buildSetPayload', () => {
  it('maps camelCase drafts to the snake_case p_set_data shape', () => {
    const payload = buildSetPayload(2, 'set-uuid', setWith({ actualReps: '10', isCompleted: true }));
    expect(payload).toEqual({
      set_number: 2,
      prescribed_item_set_id: 'set-uuid',
      actual_reps: 10,
      actual_duration_seconds: null,
      actual_distance_meters: null,
      actual_load_kg: null,
      load_type: null,
      actual_rest_seconds: null,
      rpe: null,
      is_completed: true,
    });
  });
});

describe('validateAbandonment (mirrors app_private.validate_abandonment)', () => {
  it('abandoned requires a known reason code', () => {
    expect(validateAbandonment('abandoned', null)).toMatch(/reason/);
    expect(validateAbandonment('abandoned', 'nonsense')).toMatch(/reason/);
    for (const reason of ABANDONMENT_REASONS) {
      expect(validateAbandonment('abandoned', reason)).toBeNull();
    }
  });

  it('completed forbids a reason code', () => {
    expect(validateAbandonment('completed', null)).toBeNull();
    expect(validateAbandonment('completed', 'time_constraint')).toMatch(/cannot be set/);
  });
});

describe('buildFeedbackPayloads', () => {
  it('returns null for both when nothing was entered', () => {
    expect(buildFeedbackPayloads(emptySplitFeedback())).toEqual({ feedback: null, privateFeedback: null });
  });

  it('builds ordinary feedback only when both ratings are present', () => {
    const { feedback } = buildFeedbackPayloads({ ...emptySplitFeedback(), difficultyRating: 8, energyLevel: 4 });
    expect(feedback).toEqual({ difficulty_rating: 8, energy_level: 4 });
  });

  it('builds private feedback with a required discomfort_area when has_discomfort is true', () => {
    const { privateFeedback } = buildFeedbackPayloads({
      ...emptySplitFeedback(),
      hasDiscomfort: true,
      discomfortArea: '  Left shoulder  ',
      noteToCoach: 'Felt pinching',
    });
    expect(privateFeedback).toEqual({ has_discomfort: true, discomfort_area: 'Left shoulder', note_to_coach: 'Felt pinching' });
  });

  it('a note alone (no discomfort) still produces private feedback with discomfort_area null', () => {
    const { privateFeedback } = buildFeedbackPayloads({ ...emptySplitFeedback(), noteToCoach: 'Great session' });
    expect(privateFeedback).toEqual({ has_discomfort: false, discomfort_area: null, note_to_coach: 'Great session' });
  });
});

describe('buildOfflineBundle (Task 4.5 wire format)', () => {
  it('assembles the full OfflineSessionBundle shape', () => {
    const bundle = buildOfflineBundle({
      sessionCorrelationId: 'corr-1',
      existingSessionId: 'session-1',
      workoutVersionId: 'ver-1',
      status: 'completed',
      abandonmentReasonCode: null,
      startedAt: '2026-01-01T00:00:00.000Z',
      completedAt: '2026-01-01T00:20:00.000Z',
      substitutions: [
        {
          originalWorkoutItemId: 'item-1',
          replacementExerciseId: 'ex-2',
          performedMeasurementMode: 'reps',
          reasonCode: 'equipment_unavailable',
        },
      ],
      sets: [{ workoutItemId: 'item-1', setNumber: 1, prescribedItemSetId: null, draft: setWith({ actualReps: '12' }) }],
      feedback: { difficulty_rating: 6, energy_level: 3 } as any,
      privateFeedback: null,
    });
    expect(bundle).toMatchObject({
      session_correlation_id: 'corr-1',
      existing_session_id: 'session-1',
      workout_version_id: 'ver-1',
      status: 'completed',
      abandonment_reason_code: null,
      started_at: '2026-01-01T00:00:00.000Z',
      completed_at: '2026-01-01T00:20:00.000Z',
      substitutions: [
        { original_workout_item_id: 'item-1', replacement_exercise_id: 'ex-2', performed_measurement_mode: 'reps', reason_code: 'equipment_unavailable' },
      ],
      sets: [{ workout_item_id: 'item-1', set_number: 1, prescribed_item_set_id: null, actual_reps: 12, is_completed: true }],
      feedback: { difficulty_rating: 6, energy_level: 3 },
      private_feedback: null,
    });
  });
});

describe('summarizeActual', () => {
  it('summarizes a completed set and flags an incomplete one', () => {
    expect(summarizeActual('reps', setWith({ actualReps: '10' }))).toBe('10 reps');
    expect(summarizeActual('reps', setWith({ isCompleted: false }))).toBe('not completed');
  });
});
