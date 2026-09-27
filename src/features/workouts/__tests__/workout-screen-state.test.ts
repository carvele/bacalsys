import { resolveWorkoutScreenState } from '../workout-screen-state';

/**
 * F-S4-02 (second narrow re-review): proves the start-error-outranks-spinner
 * priority directly, independent of `workout/active.tsx`'s native/query
 * dependencies.
 */
describe('resolveWorkoutScreenState (F-S4-02 second narrow re-review)', () => {
  const base = {
    hasVersionId: true,
    isAwaitingStart: false,
    startError: null as string | null,
    hierarchyLoading: false,
    hierarchyError: false,
    stepsCount: 3,
  };

  it('shows loading when there is no versionId yet', () => {
    expect(resolveWorkoutScreenState({ ...base, hasVersionId: false })).toEqual({ kind: 'loading' });
  });

  it('surfaces a start/persistence error even while still awaiting start (the bug this fixes)', () => {
    const result = resolveWorkoutScreenState({
      ...base,
      isAwaitingStart: true,
      startError: 'storage unavailable',
    });
    expect(result).toEqual({ kind: 'start-error', message: 'storage unavailable' });
  });

  it('shows the starting spinner while awaiting start with no error yet', () => {
    expect(resolveWorkoutScreenState({ ...base, isAwaitingStart: true, startError: null })).toEqual({
      kind: 'starting',
    });
  });

  it('shows the starting spinner while the hierarchy is loading, even if not (yet) awaiting start', () => {
    expect(resolveWorkoutScreenState({ ...base, hierarchyLoading: true })).toEqual({ kind: 'starting' });
  });

  it('never shows a stale error once the session is ready (isAwaitingStart false)', () => {
    // A start error can never coexist with isAwaitingStart: false in the real
    // screen (setSessionId is only ever called via onReady, which only fires
    // when onError did not), but the function stays fail-safe either way:
    // once isAwaitingStart is false, the start-error branch cannot fire.
    expect(
      resolveWorkoutScreenState({ ...base, isAwaitingStart: false, startError: 'leftover error' }),
    ).not.toEqual({ kind: 'start-error', message: 'leftover error' });
  });

  it('shows the hierarchy error once start has succeeded', () => {
    expect(resolveWorkoutScreenState({ ...base, hierarchyError: true })).toEqual({ kind: 'hierarchy-error' });
  });

  it('shows empty once start has succeeded and the routine has no exercises', () => {
    expect(resolveWorkoutScreenState({ ...base, stepsCount: 0 })).toEqual({ kind: 'empty' });
  });

  it('shows ready once start and hierarchy have both succeeded and there are steps', () => {
    expect(resolveWorkoutScreenState(base)).toEqual({ kind: 'ready' });
  });
});
