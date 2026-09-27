import { beginOnlineSession, type OnlineStartHandshake } from '../session-start';

/**
 * F-S4-02 (Reviewer narrow re-review): proves the online-start ordering
 * invariant directly, independent of `workout/active.tsx`'s other concerns.
 */
describe('beginOnlineSession (F-S4-02 narrow re-review)', () => {
  const handshake: OnlineStartHandshake = { sessionId: 'session-1', exerciseMapping: { 'item-1': 'session-exercise-1' } };

  it('does not expose the session as ready until persistHandshake resolves', async () => {
    let resolvePersist!: () => void;
    const persistHandshake = jest.fn(
      () =>
        new Promise<void>((resolve) => {
          resolvePersist = resolve;
        }),
    );
    const onReady = jest.fn();
    const onError = jest.fn();

    const promise = beginOnlineSession(handshake, { persistHandshake, onReady, onError });

    // The durable write is still in flight: onReady must NOT have fired yet.
    await Promise.resolve(); // let any queued microtasks (but not the pending persist) flush
    expect(onReady).not.toHaveBeenCalled();

    resolvePersist();
    await promise;

    expect(onReady).toHaveBeenCalledWith(handshake);
    expect(onError).not.toHaveBeenCalled();
  });

  it('never exposes the session as ready if persistHandshake rejects (fails closed)', async () => {
    const failure = new Error('storage unavailable');
    const persistHandshake = jest.fn().mockRejectedValue(failure);
    const onReady = jest.fn();
    const onError = jest.fn();

    await beginOnlineSession(handshake, { persistHandshake, onReady, onError });

    expect(onReady).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledWith(failure);
  });

  it('calls persistHandshake with the exact handshake before doing anything else', async () => {
    const calls: string[] = [];
    const persistHandshake = jest.fn(async (h: OnlineStartHandshake) => {
      calls.push(`persist:${h.sessionId}`);
    });
    const onReady = jest.fn((h: OnlineStartHandshake) => calls.push(`ready:${h.sessionId}`));
    const onError = jest.fn();

    await beginOnlineSession(handshake, { persistHandshake, onReady, onError });

    expect(calls).toEqual(['persist:session-1', 'ready:session-1']);
  });
});
