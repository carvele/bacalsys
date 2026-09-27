# F-S4-02 — The offline outbox's server handshake was memory-only, not durable across a restart

- **Class:** Bug (the client implementation did not satisfy the durability guarantee STATUS.md itself claimed).
- **Severity:** High.
- **Found during:** the ChatGPT Reviewer's Sprint 4 implementation/evidence gate (first submission).

## Symptom

`OfflineOutboxService` (`src/services/sync/outbox-sync.ts`) persisted the server
handshake acquired from a successful `start_workout_session` call — the real
`session_id` and the `workout_item_id -> session_exercise_id` mapping every
subsequent `record_session_set` call needs — only in an in-process `Map`:

```ts
const handshakes = new Map<string, SessionHandshake>();
function persistHandshake(sessionCorrelationId, handshake) {
  handshakes.set(sessionCorrelationId, handshake);
}
```

Neither `sqlite-outbox.ts` nor `web-outbox.ts` persisted `session_id` or
`exercise_mapping` anywhere. A queued `RECORD_SET` or `SUBSTITUTE_EXERCISE`
mutation's own durable row contains only prescription identity
(`workout_item_id`), never the server's `session_id` — by design (Task 4.5's
whole point is correlating by immutable prescription ids, never a
server-generated id the client couldn't have known offline). Resolving that
dependency at dispatch time therefore depended entirely on the in-memory Map.

Concrete failure path:

```
Workout starts online
→ server returns session_id + exercise_mapping
→ handshake exists only in memory
→ athlete goes offline
→ RECORD_SET is durably written to the outbox (SQLite/IndexedDB)
→ app process is killed
→ app restarts (a fresh OfflineOutboxService instance, fresh empty Map)
→ the RECORD_SET row is still 'pending' on disk
→ its session's START_SESSION row is already 'synced' — nothing left to replay it
→ resolveSessionId() returns null
→ RECORD_SET fails "Waiting for the session to sync first"
→ repeats every retry; after 5 attempts it dead-letters permanently
```

This directly contradicted the STATUS.md claim that "the durable outbox rows
it may have already enqueued survive on disk and still sync once the app
reopens" — that was true only as long as the *same* `OfflineOutboxService`
instance (and therefore its in-memory Map) was never destroyed, which a real
app process restart always does.

## Root cause

The handshake is genuinely *acquired* durably (the `START_SESSION` row and its
RPC response are real), but the *decision of where to keep the acquired
identity* used an in-process cache instead of the same storage layer as
everything else the outbox already treats as durable. The existing Jest
acceptance test never caught this because it kept and reused the same service
instance across its whole disconnect/reconnect sequence — it never destroyed
and recreated the service (or its would-be in-memory state) between the
`START_SESSION` success and the dependent mutation's dispatch.

## Fix

The handshake is now part of the `OutboxStorage` contract itself
(`src/services/storage/outbox-types.ts`), keyed by `session_correlation_id`,
implemented identically to `offline_mutations`' own durability:

- **`sqlite-outbox.ts`**: a new `session_handshakes` table
  (`session_correlation_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
  exercise_mapping_json TEXT NOT NULL`), upserted via `INSERT ... ON CONFLICT
  DO UPDATE`.
- **`web-outbox.ts`**: a second IndexedDB object store `session_handshakes`
  (`DB_VERSION` bumped to 2, created in `onupgradeneeded` alongside
  `offline_mutations`), plus a second in-memory `Map` for the `NODE_ENV ===
  'test'` path — the exact same pattern already used for `offline_mutations`.
- **`outbox-sync.ts`**: `OfflineOutboxService` no longer holds ANY in-process
  handshake state. `persistHandshake()` and `getHandshake()` write/read
  straight through `storage.saveHandshake()` / `storage.getHandshake()`.
  `resolveSessionId()` is now `async` and always resolves via durable storage,
  so it behaves identically whether called by the service instance that
  originally received the handshake or a brand-new one created after a
  restart. The `START_SESSION` dispatch path now `await`s the durable write
  *before* returning success, so a crash between "handshake acquired" and
  "row marked synced" can never leave a synced `START_SESSION` with no
  recoverable handshake.

No separate "recovery" or "rehydration" step was needed at startup: because
resolution is always on-demand against durable storage, a fresh service
instance recovers automatically the next time it dispatches a dependent
mutation — this is the "deterministically reconstruct it" option the Reviewer
offered, realized by simply never caching the identity anywhere else.

## Regression coverage

`src/services/sync/__tests__/outbox-sync.test.ts` — two new tests, mirroring
the Reviewer's mandated scenario exactly:

- **RECORD_SET recovery**: enqueue `START_SESSION` + a dependent `RECORD_SET`
  offline; reconnect — `START_SESSION` succeeds (handshake durably written),
  `RECORD_SET`'s own dispatch is made to fail this one time (simulating the
  process dying mid-dispatch); a **brand-new** `OfflineOutboxService` instance
  is created against the *same* backing storage (`webOutbox`'s module-level
  store, standing in for on-disk persistence exactly as it does in every other
  test in the file) and `processQueue()` is run again: `RECORD_SET` now
  dispatches successfully using the recovered `session_id` /
  `session_exercise_id`, `start_workout_session` is never called a second time
  (no duplicate session), and the mutation does not dead-letter.
- **SUBSTITUTE_EXERCISE recovery**: the equivalent case, since the fix does
  not treat the two mutation types differently — both resolve their
  `session_id` through the identical durable `getHandshake()` path.

A mutation-testing pass (temporarily reverting `persistHandshake`/
`getHandshake` back to an in-process `Map`, matching the original bug exactly)
confirmed both new tests fail against the reverted code with precisely the
Reviewer's described symptom (`record_session_set` / `record_exercise_substitution`
never called, 0 invocations) and pass again once the fix is restored — the
regression tests are real, not tautologies.

`npm run verify` re-run in full: typecheck 0 errors, lint 0 errors/warnings,
Jest **95/95** (93 + 2 new), offline pgTAP **508/508** (unaffected — this is a
client-only fix; no migration or SQL changed).

## Evidentiary note: no hosted probe

This defect and its fix are entirely about *client-local* storage surviving
an app/process restart. The hosted RPC-only E2E script
(`scripts/e2e/sprint4-slices.mjs`) has no local outbox of its own to restart —
it calls the same RPCs the client would, which were never the problem here
(the server-side idempotency/session-lookup behavior these tests rely on was
already covered by Slice 1 and the concurrency probes). The Jest tests above,
exercising the real `OutboxStorage` contract end-to-end through a destroyed
and recreated service instance, are the correct evidentiary tier for this
specific guarantee — the native `expo-sqlite` implementation cannot be
exercised inside Jest at all (no native module bridge), so its correctness
rests on exact structural symmetry with the already-tested `offline_mutations`
persistence pattern plus the Sprint 4 Android dev-client boot confirming
`expo-sqlite` itself initializes correctly in this app.

## Narrow re-review follow-up: the online-start UI ordering itself

The Reviewer's first re-review of this fix found the storage/service layer
above sound, but caught one remaining instance of the same class of race in
the UI code that CALLS `persistHandshake()`: `src/app/(athlete)/workout/active.tsx`
called Zustand's `setSessionId()` — which synchronously makes the Workout
Player usable — **before** `await`ing `persistHandshake()`, not after:

```ts
setSessionId(result.session_id, result.exercise_mapping ?? {});
await offlineOutboxService.persistHandshake(correlationId, { ... });
```

Since `setSessionId` is synchronous, this exposed the player as ready before
the durable write was guaranteed to have succeeded — and if `persistHandshake`
itself ever rejected (e.g. the on-device SQLite write failing), the player had
already been promoted to ready with no durable recovery identity at all,
reintroducing a narrower version of the same defect purely in the UI's own
ordering.

**Fix**: extracted the invariant into its own pure function,
`src/features/workouts/session-start.ts` — `beginOnlineSession()` — so it is
directly testable independent of the screen's other concerns (hierarchy
fetch, the rest timer, which pulls in native modules Jest cannot load).
`active.tsx` now calls it, awaiting the durable write and calling
`setSessionId` (`onReady`) only once it resolves; if it rejects, `setSessionId`
is never called and the error is surfaced (`onError`) instead — the player
stays in its "starting" state (`isAwaitingStart` stays true) rather than
silently becoming usable.

**Regression coverage**: `src/features/workouts/__tests__/session-start.test.ts`
(3 new tests) proves directly: (1) `onReady` does not fire until
`persistHandshake` resolves — asserted while its promise is still pending;
(2) if `persistHandshake` rejects, `onReady` is never called and `onError` is,
instead; (3) the call order is `persist` then `ready`, never the reverse. A
mutation-testing pass (reverting `beginOnlineSession` to the original buggy
order, with `onReady` called first and the rejection unhandled) confirmed all
three tests fail against it and pass again once fixed.

`npm run verify` re-run in full: typecheck 0 errors, lint 0 errors/warnings,
Jest **98/98** (95 + 3 new), offline pgTAP **508/508** (unaffected — UI-only
fix, no migration or SQL changed).

## Classification note

No ADR was needed: this is a correction to the client implementation's
durability behavior, not a change to Section 11's architecture, the RLS/audit
model, F-S4-P13, F-S4-P14, permissions, or any server mutation semantics —
none of which were touched.
