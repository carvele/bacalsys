# F-S5-05 — The Workout Player's online start cancelled itself: the session was created server-side but the screen never left "Starting your workout…"

- **Class:** Bug (High for the athlete: an online workout could never begin from the UI).
- **Found by:** the Reviewer's mandatory Android smoke gate F-S5-G01 (`sprint-05` acceptance round 2) — the first time this path was driven on a real device with a live backend.
- **Origin:** *latent since Sprint 4* (accepted). The effect is line-for-line identical in `sprint-04-accepted`; Sprint 5's only change to it was passing the occurrence id. Sprint 4's own Android evidence proved boot/launch only, and its hosted slices drove the RPCs directly, so nothing exercised this React effect against a real backend until now. This is stated plainly rather than attributed to Sprint 5.

## Symptom

On the Android dev client, signed in as a disposable athlete: Today's training → **Start workout** opens the Workout screen, which shows the spinner **"Starting your workout…"** indefinitely (observed for 6+ minutes). Meanwhile the server had done everything correctly: `app_private.idempotency_keys` held a `completed` `START_SESSION` row whose response carried the `session_id`, the `exercise_mapping` and the `assignment_occurrence_id`; the occurrence was `in_progress` with exactly one linked session. The athlete could not proceed, and a retry would have been blocked by the one-active-session rule.

## Root cause

`workout/active.tsx` started the session in a `useEffect` whose dependency list included `activeSession` (the Zustand store's `active`). The effect's first run calls `begin()`, which writes `active` into the store **synchronously**. That changes a dependency, so React re-ran the effect and executed the previous run's cleanup, `cancelled = true` — while that run's `start_workout_session` request was **still in flight**. When the response arrived, `if (cancelled) return;` discarded it, so `setSessionId` was never called and `isAwaitingStart` stayed `true` forever. The same flag also swallowed a *failed* start (`setError` was skipped), so an error would have hung the spinner too.

The re-run itself was harmless (it early-returns because `active` is now set); the defect was that cancellation was bound to the effect's own re-runs instead of to the screen's lifetime.

## Fix

Extracted the start logic into `src/features/workouts/use-session-start.ts` (`useSessionStart`, every side-effecting dependency injected so it is testable in Jest — the screen itself pulls in native modules Jest cannot load) and changed cancellation semantics:

- a start's result is discarded **only when the screen unmounts** (`mountedRef`, cleared by an effect with an empty dependency list);
- a single start is guaranteed by `startedRef`, not by the dependency list.

`workout/active.tsx` now calls the hook with the real connectivity, Supabase RPC and outbox (`sessionStartDeps`). Behaviour for the offline path, the occurrence-linked 3-arg RPC, the durable-handshake ordering (F-S4-02) and the error priority (`resolveWorkoutScreenState`) is unchanged. No migration, RPC, RLS, permission or `OutboxStorage` change.

## Regression test (failing-first)

`src/features/workouts/__tests__/use-session-start.test.tsx` (5 tests). The hook was first extracted **with the buggy effect copied verbatim**; against it:

| Test | Before the fix | After |
|---|---|---|
| in-flight online start resolves → session becomes ready | ❌ `sessionId` stayed `null` | ✅ |
| a failed start surfaces its error instead of hanging | ❌ `onStartError` never called | ✅ |
| starts exactly once across re-renders | ✅ | ✅ |
| result is dropped only on a real unmount | ✅ | ✅ |
| offline: journals the start with the occurrence id, no server call | ✅ | ✅ |

## Verification

- Jest **15 suites / 150 tests** (was 14 / 145); typecheck 0 errors; lint 0; `npm run verify` green (pgTAP 15 files / 646, unchanged); `npm run build:web` passes.
- On the Android emulator with the fix: Start workout → the player opens directly into the exercise (screenshot `android-04-player-renders-AFTER-fix.png` vs `android-03-player-stuck-on-spinner-BEFORE-fix.png`); the server shows the occurrence `in_progress`, one linked session, versions equal.
