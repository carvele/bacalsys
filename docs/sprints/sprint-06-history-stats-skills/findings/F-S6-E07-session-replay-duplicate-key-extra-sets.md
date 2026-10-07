# F-S6-E07 — React key collision in `SessionReplayTable` when session has extra sets

- **Class:** Bug (React rendering / child reconciliation, client-only).
- **Found by:** Antigravity (Planner + Executor) while executing the interactive Android dev-client smoke test (F-S6-P10).

## Symptom

When rendering a workout replay in `SessionReplayTable` where an athlete added extra sets (e.g. `prescribedItemSetId` is null, but `setNumber` matches a prescribed set number), the JSX row key `${item.workoutItemId}-${set.setNumber}` produced duplicate React keys for child views in the set list. React Native / Hermes logged a console warning:
`Encountered two children with the same key, ...`.

## Root Cause

`workoutItemId` paired with `setNumber` is not a unique composite key when an athlete logs extra sets alongside prescribed sets. Because an extra set and a prescribed set can share the same `setNumber`, the key collided. Every row in `ReplaySet` is guaranteed to have at least one of `prescribedItemSetId` or `sessionSetId`.

## Fix

Added helper `replaySetKey(itemId: string, s: ReplaySet): string` in `src/features/history/replay.ts`:
```ts
export function replaySetKey(itemId: string, s: ReplaySet): string {
  return `${itemId}:${s.prescribedItemSetId ?? '-'}:${s.sessionSetId ?? '-'}`;
}
```
Updated `SessionReplayTable.tsx` to use `replaySetKey(item.workoutItemId, set)`.

## Regression Test

Added unit test in `src/features/history/__tests__/replay.test.ts`:
```ts
describe('replaySetKey', () => {
  it('is unique for an extra set and the prescribed set with the same number', () => {
    const prescribed = set({ setNumber: 1, prescribedItemSetId: 'wis-1', sessionSetId: null });
    const extra = set({ setNumber: 1, prescribedItemSetId: null, sessionSetId: 'ss-9' });
    expect(replaySetKey('item-1', prescribed)).not.toBe(replaySetKey('item-1', extra));
  });
});
```
Verified clean with `npm test`.
