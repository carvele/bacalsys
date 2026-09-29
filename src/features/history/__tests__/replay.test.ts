import {
  SET_BADGE_LABEL,
  formatActual,
  formatLoad,
  formatTarget,
  isMedicalReason,
  replayTotals,
  sessionOutcome,
  setBadge,
  substitutionFor,
  substitutionReasonLabel,
} from '../replay';
import type { ReplayItem, ReplaySet, SessionReplay } from '@/types/skills';

const set = (overrides: Partial<ReplaySet> = {}): ReplaySet => ({
  setNumber: 1,
  prescribedItemSetId: 'wis-1',
  sessionSetId: 'ss-1',
  targetReps: null,
  targetLoadKg: null,
  targetLoadType: null,
  targetDurationSeconds: null,
  targetDistanceMeters: null,
  targetRestSeconds: null,
  targetRpe: null,
  actualReps: null,
  actualLoadKg: null,
  actualLoadType: null,
  actualDurationSeconds: null,
  actualDistanceMeters: null,
  actualRestSeconds: null,
  rpe: null,
  isCompleted: true,
  isSkipped: false,
  isExtra: false,
  ...overrides,
});

describe('formatLoad', () => {
  it('renders added / assisted / bodyweight, and nothing for a zero or null load with no type', () => {
    expect(formatLoad(10, 'added')).toBe('+10 kg');
    expect(formatLoad(5, 'assisted')).toBe('5 kg assist');
    expect(formatLoad(0, 'bodyweight')).toBe('bodyweight');
    expect(formatLoad(null, null)).toBeNull();
    expect(formatLoad(0, null)).toBeNull();
  });
});

describe('formatTarget / formatActual', () => {
  it('an extra set has no target; a fully unlogged set has no actual', () => {
    expect(formatTarget(set({ isExtra: true, prescribedItemSetId: null }))).toBe('—');
    expect(formatActual(set({ sessionSetId: null }))).toBe('—');
  });
  it('describes reps, duration, distance, load and RPE together', () => {
    expect(formatTarget(set({ targetReps: 10 }))).toBe('10 reps');
    expect(formatTarget(set({ targetDurationSeconds: 30 }))).toBe('30 s');
    expect(formatActual(set({ actualReps: 8, actualLoadKg: 20, actualLoadType: 'added', rpe: 8 }))).toBe('8 reps · +20 kg · RPE 8');
    expect(formatTarget(set({ targetDistanceMeters: 400.5 }))).toBe('400.5 m');
  });
  it('a logged but not-completed set with no metrics reads "Not completed"; a logged completed one with none reads "Done"', () => {
    expect(formatActual(set({ isCompleted: false }))).toBe('Not completed');
    expect(formatActual(set({ isCompleted: true }))).toBe('Done');
  });
  it('falls back to "As prescribed" when a prescribed set carries no numeric target (e.g. technique_practice)', () => {
    expect(formatTarget(set())).toBe('As prescribed');
  });
});

describe('setBadge', () => {
  it('an extra set is always "extra", regardless of session status', () => {
    expect(setBadge(set({ isExtra: true }), 'completed')).toBe('extra');
    expect(setBadge(set({ isExtra: true }), 'in_progress')).toBe('extra');
  });
  it('a skipped prescribed set reads "pending" while the session is still running, "skipped" once it has ended', () => {
    const skipped = set({ isSkipped: true });
    expect(setBadge(skipped, 'in_progress')).toBe('pending');
    expect(setBadge(skipped, 'completed')).toBe('skipped');
    expect(setBadge(skipped, 'abandoned')).toBe('skipped');
  });
  it('a completed prescribed set is "done"', () => {
    expect(setBadge(set(), 'completed')).toBe('done');
  });
  it('every badge has a label', () => {
    for (const b of Object.values(SET_BADGE_LABEL)) expect(typeof b).toBe('string');
  });
});

describe('substitution helpers', () => {
  it('labels known reason codes and passes unknown ones through', () => {
    expect(substitutionReasonLabel('pain_discomfort')).toBe('Pain or discomfort');
    expect(substitutionReasonLabel('equipment_unavailable')).toBe('Equipment unavailable');
    expect(substitutionReasonLabel('mystery')).toBe('mystery');
  });
  it('flags exactly the two Rule E medical reasons', () => {
    expect(isMedicalReason('pain_discomfort')).toBe(true);
    expect(isMedicalReason('injury_limitation')).toBe(true);
    expect(isMedicalReason('too_difficult')).toBe(false);
    expect(isMedicalReason('other')).toBe(false);
  });
  it('finds the substitution recorded against an item, if any', () => {
    const item: ReplayItem = {
      workoutItemId: 'wi-1',
      blockTitle: 'Main',
      orderInBlock: 1,
      prescribedExerciseName: 'Plank',
      prescribedCategory: 'core',
      prescribedMeasurementMode: 'duration',
      isSubstituted: true,
      performedExerciseName: 'Hollow Body Hold',
      performedMeasurementMode: 'duration',
      sets: [],
    };
    const replay = {
      substitutions: [{ id: 'sm-1', originalWorkoutItemId: 'wi-1', replacementExerciseName: 'Hollow Body Hold', reasonCode: 'pain_discomfort' }],
    } as unknown as SessionReplay;
    expect(substitutionFor(replay, item)?.id).toBe('sm-1');
    expect(substitutionFor({ substitutions: [] } as unknown as SessionReplay, item)).toBeUndefined();
  });
});

describe('sessionOutcome', () => {
  const base = { id: 's', athleteId: 'a', workoutVersionId: 'v', assignmentOccurrenceId: null, startedAt: '', completedAt: null };
  it('names the outcome for each terminal and non-terminal status', () => {
    expect(sessionOutcome({ ...base, status: 'completed', abandonmentReasonCode: null })).toBe('Completed');
    expect(sessionOutcome({ ...base, status: 'in_progress', abandonmentReasonCode: null })).toBe('In progress');
    expect(sessionOutcome({ ...base, status: 'abandoned', abandonmentReasonCode: 'time_constraint' })).toBe('Ended early — Ran out of time');
    expect(sessionOutcome({ ...base, status: 'abandoned', abandonmentReasonCode: null })).toBe('Ended early');
  });
});

describe('replayTotals', () => {
  it('counts prescribed sets, how many were completed, and completed extras separately', () => {
    const items: ReplayItem[] = [
      {
        workoutItemId: 'wi-1',
        blockTitle: 'Main',
        orderInBlock: 1,
        prescribedExerciseName: 'Push-up',
        prescribedCategory: 'push',
        prescribedMeasurementMode: 'reps',
        isSubstituted: false,
        performedExerciseName: 'Push-up',
        performedMeasurementMode: 'reps',
        sets: [
          set({ setNumber: 1, isSkipped: false, isExtra: false }),
          set({ setNumber: 2, isSkipped: true, isExtra: false, sessionSetId: 'ss-2', isCompleted: false }),
          set({ setNumber: 3, isSkipped: false, isExtra: true, prescribedItemSetId: null, isCompleted: true }),
        ],
      },
    ];
    expect(replayTotals(items)).toEqual({ prescribed: 2, completed: 1, extra: 1 });
  });
  it('is all zero for no items', () => {
    expect(replayTotals([])).toEqual({ prescribed: 0, completed: 0, extra: 0 });
  });
});
