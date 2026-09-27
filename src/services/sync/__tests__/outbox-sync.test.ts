import { onlineManager } from '@tanstack/react-query';

import { webOutbox, __resetInMemoryOutboxForTests } from '../../storage/web-outbox';
import { createOfflineOutboxService } from '../outbox-sync';

jest.mock('@/lib/supabase', () => ({ supabase: { rpc: jest.fn() } }));
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { supabase } = require('@/lib/supabase') as { supabase: { rpc: jest.Mock } };

/**
 * Sprint 4 · Task 4.10 acceptance test (Section 11): offline start -> offline
 * sets -> reconnect while still active -> START sync with exercise_mapping ->
 * granular set sync -> disconnect again -> terminal bundle -> exactly one
 * session. `webOutbox`'s in-memory adapter (NODE_ENV === 'test') stands in
 * for the durable journal; `processQueue()` is invoked directly to simulate
 * each reconnection instead of driving real NetInfo events. `onlineManager`
 * is forced offline throughout so enqueue*() never auto-triggers its own
 * background processQueue() call racing the test's explicit ones.
 */
describe('OfflineOutboxService (Task 4.10)', () => {
  beforeEach(() => {
    __resetInMemoryOutboxForTests();
    supabase.rpc.mockReset();
    onlineManager.setOnline(false);
  });

  it('full offline -> reconnect -> offline again -> terminal bundle lifecycle produces exactly one session', async () => {
    const service = createOfflineOutboxService(webOutbox);
    await webOutbox.init();

    // 1. Offline: the athlete starts and logs one set entirely offline.
    await service.enqueueGranular({
      id: 'corr-1',
      sessionCorrelationId: 'corr-1',
      mutationType: 'START_SESSION',
      entityId: 'version-1',
      payload: { workout_version_id: 'version-1' },
    });
    await service.enqueueGranular({
      id: 'set-1',
      sessionCorrelationId: 'corr-1',
      mutationType: 'RECORD_SET',
      entityId: 'item-1',
      payload: { workout_item_id: 'item-1', set_data: { set_number: 1, actual_reps: 10, is_completed: true } },
    });

    let pending = await service.pendingForSession('corr-1');
    expect(pending.map((m) => m.mutationType)).toEqual(['START_SESSION', 'RECORD_SET']);
    expect(supabase.rpc).not.toHaveBeenCalled();

    // 2. Reconnect: START_SESSION dispatches first (FIFO + causal dependency),
    //    handshaking session_id + exercise_mapping before RECORD_SET can resolve.
    supabase.rpc.mockImplementation((fn: string) => {
      if (fn === 'start_workout_session') {
        return Promise.resolve({ data: { session_id: 'server-session-1', exercise_mapping: { 'item-1': 'session-exercise-1' } }, error: null });
      }
      if (fn === 'record_session_set') {
        return Promise.resolve({ data: { set_id: 'set-id-1', set_number: 1 }, error: null });
      }
      return Promise.resolve({ data: null, error: new Error(`unexpected rpc ${fn}`) });
    });
    await service.processQueue();

    expect(supabase.rpc).toHaveBeenNthCalledWith(
      1,
      'start_workout_session',
      expect.objectContaining({ p_workout_version_id: 'version-1', p_idempotency_key: 'corr-1' }),
    );
    expect(supabase.rpc).toHaveBeenNthCalledWith(
      2,
      'record_session_set',
      expect.objectContaining({ p_session_id: 'server-session-1', p_session_exercise_id: 'session-exercise-1', p_idempotency_key: 'set-1' }),
    );
    pending = await service.pendingForSession('corr-1');
    expect(pending.every((m) => m.syncStatus === 'synced')).toBe(true); // both granular rows synced

    // 3. Disconnect again at completion: the session ends offline, coalescing
    //    into a single SYNC_BUNDLE (the already-synced granular rows are gone).
    await service.enqueueBundle('corr-1', {
      session_correlation_id: 'corr-1',
      existing_session_id: 'server-session-1',
      workout_version_id: 'version-1',
      status: 'completed',
      started_at: '2026-01-01T00:00:00.000Z',
      completed_at: '2026-01-01T00:20:00.000Z',
      sets: [],
    } as any);

    supabase.rpc.mockClear(); // isolate the assertions below to this final reconnection
    supabase.rpc.mockImplementation((fn: string) => {
      if (fn === 'sync_offline_session_bundle') {
        return Promise.resolve({ data: { status: 'synced', session_id: 'server-session-1' }, error: null });
      }
      return Promise.resolve({ data: null, error: new Error(`unexpected rpc ${fn}`) });
    });
    await service.processQueue();

    // Exactly ONE call this pass: the coalesced bundle, never a replay of the
    // already-synced START_SESSION/RECORD_SET granular mutations.
    expect(supabase.rpc).toHaveBeenCalledTimes(1);
    expect(supabase.rpc).toHaveBeenCalledWith('sync_offline_session_bundle', expect.objectContaining({ p_idempotency_key: expect.any(String) }));
    pending = await service.pendingForSession('corr-1');
    expect(pending.every((m) => m.syncStatus === 'synced')).toBe(true);
  });

  it('causal dependency blocking: a RECORD_SET never dispatches before its session has a resolved session_id', async () => {
    const service = createOfflineOutboxService(webOutbox);
    await webOutbox.init();

    await service.enqueueGranular({
      id: 'corr-2',
      sessionCorrelationId: 'corr-2',
      mutationType: 'START_SESSION',
      entityId: 'version-1',
      payload: { workout_version_id: 'version-1' },
    });
    await service.enqueueGranular({
      id: 'set-2',
      sessionCorrelationId: 'corr-2',
      mutationType: 'RECORD_SET',
      entityId: 'item-1',
      payload: { workout_item_id: 'item-1', set_data: { set_number: 1, actual_reps: 5, is_completed: true } },
    });

    // START_SESSION itself fails (server unreachable / rejected).
    supabase.rpc.mockResolvedValue({ data: null, error: { message: 'network error' } });
    await service.processQueue();

    expect(supabase.rpc).toHaveBeenCalledTimes(1); // only START_SESSION was attempted; RECORD_SET blocked behind it
    const pending = await service.pendingForSession('corr-2');
    expect(pending.find((m) => m.mutationType === 'START_SESSION')?.syncStatus).toBe('pending');
    expect(pending.find((m) => m.mutationType === 'RECORD_SET')?.syncStatus).toBe('pending');
    expect(pending.find((m) => m.mutationType === 'START_SESSION')?.attemptCount).toBe(1);
  });

  it('a dead-lettered mutation stops retrying after MAX_SYNC_ATTEMPTS and can be manually retried', async () => {
    const service = createOfflineOutboxService(webOutbox);
    await webOutbox.init();
    await service.enqueueGranular({
      id: 'corr-3',
      sessionCorrelationId: 'corr-3',
      mutationType: 'START_SESSION',
      entityId: 'version-1',
      payload: { workout_version_id: 'version-1' },
    });
    supabase.rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    // Drives storage.markFailed() directly 5 times (its own attempt-count
    // bookkeeping, not processQueue()'s backoff timing, is what dead-letters
    // a mutation — exercised separately from the reconnection scenario above).
    for (let i = 0; i < 5; i++) {
      const [m] = await service.pendingForSession('corr-3');
      await service._storage.markFailed(m.id, 'boom');
    }
    const afterExhaustion = await service.pendingForSession('corr-3');
    expect(afterExhaustion[0].syncStatus).toBe('failed_permanent');
    expect(afterExhaustion[0].attemptCount).toBeGreaterThanOrEqual(5);

    await service.retry('corr-3');
    const afterRetry = await service.pendingForSession('corr-3');
    expect(afterRetry[0].syncStatus).toBe('pending');
    expect(afterRetry[0].attemptCount).toBe(0);
  });
});
