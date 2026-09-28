import { act, renderHook } from '@testing-library/react-native';

import { useSessionStart, type SessionStartDeps } from '../use-session-start';
import { useWorkoutSessionStore } from '../session-store';

/**
 * F-S5-05 (found by the Sprint 5 Android smoke pass, F-S5-G01): the online
 * start of a Workout Player session never completed on a real device.
 *
 * `begin()` writes `active` into the store synchronously, and `active` is one of
 * the start effect's own dependencies — so the effect re-ran, its cleanup set
 * `cancelled = true` on the start that was STILL IN FLIGHT, and when the RPC
 * returned (server-side the session had already been created and linked to its
 * occurrence) the result was discarded. `setSessionId` never ran, so the screen
 * sat on "Starting your workout…" forever.
 */
describe('useSessionStart (F-S5-05)', () => {
  function makeDeps(overrides: Partial<SessionStartDeps> = {}) {
    let resolveRemote!: (v: { data: unknown; error: unknown }) => void;
    const startRemote = jest.fn(
      () =>
        new Promise<{ data: unknown; error: unknown }>((resolve) => {
          resolveRemote = resolve;
        }),
    );
    const deps: SessionStartDeps = {
      isOnline: () => true,
      startRemote,
      persistHandshake: jest.fn(async () => undefined),
      enqueueOfflineStart: jest.fn(async () => undefined),
      newIdempotencyKey: () => 'key-1',
      describeError: (e) => `described:${String(e)}`,
      ...overrides,
    };
    return { deps, startRemote, resolve: (v: { data: unknown; error: unknown }) => resolveRemote(v) };
  }

  const render = (deps: SessionStartDeps, onStartError = jest.fn(), occurrenceId?: string) =>
    renderHook(() =>
      useSessionStart({ versionId: 'version-1', occurrenceId, hierarchyLoading: false, onStartError, deps }),
    );

  beforeEach(() => useWorkoutSessionStore.getState().clear());

  it('exposes the session as ready once an in-flight online start resolves, even though begin() re-rendered the effect', async () => {
    const { deps, startRemote, resolve } = makeDeps();
    await render(deps, jest.fn(), 'occurrence-1');

    // begin() ran and the store now holds the (not yet ready) session.
    expect(useWorkoutSessionStore.getState().active?.sessionId).toBeNull();
    expect(useWorkoutSessionStore.getState().active?.assignmentOccurrenceId).toBe('occurrence-1');
    expect(startRemote).toHaveBeenCalledTimes(1);
    expect(startRemote).toHaveBeenCalledWith({
      versionId: 'version-1',
      idempotencyKey: 'key-1',
      occurrenceId: 'occurrence-1',
    });

    await act(async () => {
      resolve({ data: { session_id: 'session-1', exercise_mapping: { a: 'b' } }, error: null });
    });

    expect(useWorkoutSessionStore.getState().active?.sessionId).toBe('session-1');
    expect(useWorkoutSessionStore.getState().active?.exerciseMapping).toEqual({ a: 'b' });
    expect(deps.persistHandshake).toHaveBeenCalledTimes(1);
  });

  it('starts exactly once no matter how many times the screen re-renders', async () => {
    const { deps, startRemote, resolve } = makeDeps();
    const { rerender } = await render(deps);
    await rerender({});
    await rerender({});
    expect(startRemote).toHaveBeenCalledTimes(1);
    await act(async () => resolve({ data: { session_id: 's', exercise_mapping: {} }, error: null }));
    await rerender({});
    expect(startRemote).toHaveBeenCalledTimes(1);
  });

  it('surfaces a start error instead of hanging (never leaves the athlete on the spinner)', async () => {
    const { deps, resolve } = makeDeps();
    const onStartError = jest.fn();
    await render(deps, onStartError);
    await act(async () => resolve({ data: null, error: 'boom' }));
    expect(onStartError).toHaveBeenCalledWith('described:boom');
    expect(useWorkoutSessionStore.getState().active?.sessionId).toBeNull();
  });

  it('drops the result only when the screen is actually unmounted', async () => {
    const { deps, resolve } = makeDeps();
    const { unmount } = await render(deps);
    await unmount();
    await act(async () => resolve({ data: { session_id: 'late', exercise_mapping: {} }, error: null }));
    expect(useWorkoutSessionStore.getState().active?.sessionId).toBeNull();
  });

  it('offline: journals the start (with the occurrence id) and does not call the server', async () => {
    const { deps, startRemote } = makeDeps({ isOnline: () => false });
    await render(deps, jest.fn(), 'occurrence-9');
    expect(startRemote).not.toHaveBeenCalled();
    expect(deps.enqueueOfflineStart).toHaveBeenCalledWith(
      expect.objectContaining({ versionId: 'version-1', occurrenceId: 'occurrence-9' }),
    );
  });
});
