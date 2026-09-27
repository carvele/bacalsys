# Sprint 4: Workout Player & Durable SQLite Offline Outbox — engineering status

> **Status: F-S4-02 SECOND NARROW RE-REVIEW FIX COMPLETE — READY FOR RE-REVIEW.** Not yet accepted; no tag. Per the standing
> workflow, the Executor never self-approves. This report and [ACCEPTANCE.md](ACCEPTANCE.md) are the evidence package
> for the ChatGPT Reviewer's implementation/evidence acceptance review.
>
> **Reviewer gate history:**
> 1. Implementation submitted for review (commits through `435337c`).
> 2. Reviewer verdict: **FAIL — targeted rework required.** F-S4-02: the offline outbox's server handshake
>    (`session_id` + `exercise_mapping`) was held only in an in-process `Map`, not durably persisted — a `RECORD_SET`
>    or `SUBSTITUTE_EXERCISE` mutation still `pending` after its session's `START_SESSION` row had already synced
>    could not recover across an app/process restart, eventually dead-lettering. Section 11 architecture, F-S4-01,
>    F-S4-P13, F-S4-P14, permissions, RLS and server mutation semantics were explicitly NOT reopened, and were not
>    touched by this fix.
> 3. F-S4-02 fixed (commit `03e634f`): the handshake is now part of the durable `OutboxStorage` contract itself
>    (`session_handshakes` — a SQLite table / a second IndexedDB store), never an in-process cache. Two new Jest
>    tests reproduce the Reviewer's exact restart scenario; a mutation-testing pass confirmed they fail against the
>    original bug and pass against the fix.
> 4. Reviewer narrow re-review verdict: **FAIL — one remaining race.** The storage/service layer was sound, but
>    `workout/active.tsx` called `setSessionId()` (synchronously exposing the player as ready) **before** awaiting
>    `persistHandshake()`, and never handled a rejection — a narrower instance of the same defect class, purely in
>    the UI's own ordering.
> 5. Fixed (commit `4b7da12`): the ordering/fail-closed invariant was extracted into its own testable function,
>    `beginOnlineSession()`; `active.tsx` now awaits the durable write before exposing the session as ready, and
>    fails closed (surfaces an error, never calls `setSessionId`) if it rejects. 3 new Jest tests prove the ordering
>    and the fail-closed behavior directly; mutation-tested against the original ordering.
> 6. Reviewer's second narrow re-review verdict: **FAIL — one final integration defect.** The ordering/fail-closed
>    fix itself was confirmed correct (`onError` fires, `setSessionId` never called), but because `sessionId` stays
>    `null` on failure, `isAwaitingStart` also stays `true` — and `active.tsx` checked that (→ spinner) **before**
>    checking whether a start error existed, so the error `<Notice>` was unreachable. The athlete saw an indefinite
>    "Starting your workout…" spinner instead of the promised error.
> 7. Fixed (commit below): the render-state priority was extracted into its own testable function,
>    `resolveWorkoutScreenState()` (`src/features/workouts/workout-screen-state.ts`), which checks a start error
>    **before** the spinner. `active.tsx` now renders that error (with a "Go back" action) instead of the spinner,
>    without ever re-invoking `start_workout_session`. 8 new Jest tests prove the full state-priority ordering;
>    mutation-tested against the original (spinner-first) order. See §2 (finding) and §3 (evidence).

- **Baseline:** Roadmap v1.2 (`implementation_plan.md`) Section 11 — Sprint 4 Ordered Engineering Backlog, Schemas &
  Acceptance Slices, Tasks 4.0–4.15.
- **Environment:**
  - Hosted dev project `bacalsys-dev` (`sfptojkkmjggssqzyseo`), PostgreSQL **17.6**.
  - Offline harness: PGlite, PostgreSQL **18.3**.
  - Docker is unavailable, so `supabase test db` and the local stack were **not run** (same waiver as Sprints 1–3).
  - Android emulator: AVD `Pixel_4`.

## 1. Tasks 4.0–4.15

| Task | Status | Deliverable / evidence |
|---|---|---|
| 4.0 SDK deps & fixture cleanup | ✅ | `expo-sqlite`, `expo-audio`, `expo-haptics`, `expo-notifications` installed; `app.json` plugins added; guarded fixture cleanup (`scripts/test/cleanup-fixtures.mjs`) unchanged, still sprint-agnostic |
| 4.1 Permission catalog | ✅ | `…130227_training_view_private_feedback_permission`: `training:view_private_feedback` (VP, President only); `seed.sql` updated |
| 4.2 Execution DDL | ✅ | `…130335_workout_execution_schema`: 6 tables, `app_private.idempotency_keys`, all constraints/indexes, RLS enabled, explicit grants (SELECT only). F-S4-01 fixed in the same migration (never a separate remediation) |
| 4.3 RLS & privacy helpers | ✅ | `…130533_workout_execution_rls`: `can_view_workout_session`, `can_view_session_private_feedback`, conditional `session_modifications` policy, F-S4-P13 uniform audit redaction triggers |
| 4.4 Mutation RPCs | ✅ | `…130936_workout_execution_rpcs`: idempotency protocol, mode-aware `validate_session_set`, shared appliers (`apply_session_set`, `apply_session_substitution`, `instantiate_session_exercises`, `validate_abandonment`, `apply_session_feedback`), `start_workout_session`, `record_session_set`, `record_exercise_substitution`, `complete_workout_session` |
| 4.5 Offline bundle sync | ✅ | `…131413_sync_offline_session_bundle`: online-start continuation + brand-new-offline paths, reusing 4.4's shared appliers verbatim |
| 4.6 pgTAP schema/RLS/redaction/idempotency suite | ✅ | `supabase/tests/011_workout_sessions_schema.test.sql`, **35** assertions |
| 4.7 pgTAP RPC/locking/F-S4-P14/offline suite | ✅ | `supabase/tests/012_workout_execution_and_outbox.test.sql`, **30** assertions |
| 4.8 Hosted Execution Acceptance Slice 1 | ✅ | §6: **18/18** |
| 4.9 Local SQLite & web outbox | ✅ | `src/services/storage/{outbox-types,sqlite-outbox,web-outbox,outbox-storage(.web)}.ts`, incl. the F-S4-02 durable `session_handshakes` store |
| 4.10 OfflineOutboxService & sync bridge | ✅ | `src/services/sync/outbox-sync.ts`; Jest acceptance + F-S4-02 restart-recovery tests (§3) |
| 4.11 Rest timer hook | ✅ | `src/hooks/useRestTimer.ts`; synthesized chime asset (`scripts/assets/generate-rest-chime.mjs`) |
| 4.12 Substitution modal | ✅ | `src/components/ExerciseSubstitutionModal.tsx` |
| 4.13 Interactive Workout Player | ✅ | `src/app/(athlete)/workout/active.tsx` |
| 4.14 Summary & split feedback | ✅ | `src/app/(athlete)/workout/summary.tsx` |
| 4.15 Concurrency probes + hosted Slice 2 + regression + Android boot + this report | ✅ | §7, §8, §3, §11 |
| Reviewer gate rework (F-S4-02) | ✅ | `outbox-types.ts`/`sqlite-outbox.ts`/`web-outbox.ts`/`outbox-sync.ts`; see §2 and §3 |

## 2. Findings

- **[F-S4-01](findings/F-S4-01-session-set-load-consistency-null-load-type-loophole.md)** (Bug, Medium) — the Section
  11 `session_set_load_consistency` CHECK repeated Sprint 3's F-S3-02 three-valued-logic gap verbatim (`load_type IN
  (...)` evaluates to `NULL`, not `FALSE`, when `load_type IS NULL`, and `CHECK` passes on `NULL`). Fixed **before any
  hosted apply** — never a separate remediation migration, unlike F-S3-02/03/04 which were found across two
  submissions. `app_private.validate_session_set` and the client mirror already enforced the equivalent rule
  correctly, so no runtime data was ever at risk.
- **[F-S4-02](findings/F-S4-02-outbox-handshake-not-durable-across-restart.md)** (Bug, High — Reviewer implementation-
  acceptance gate) — the offline outbox's server handshake (`session_id` + `exercise_mapping`) was held only in an
  in-process `Map`, not durably persisted; a queued `RECORD_SET` / `SUBSTITUTE_EXERCISE` mutation still `pending`
  after its session's `START_SESSION` row had already synced could not recover across an app/process restart and
  would eventually dead-letter. Fixed by making the handshake part of the durable `OutboxStorage` contract itself
  (a `session_handshakes` SQLite table / second IndexedDB store), never an in-process cache. A **narrow re-review
  follow-up** on the same finding then caught one remaining instance of the same race purely in `active.tsx`'s own
  ordering: it exposed the Workout Player as ready (`setSessionId`, synchronous) *before* the durable write was
  awaited, and never handled a rejection. Fixed by extracting the ordering/fail-closed invariant into its own tested
  function (`beginOnlineSession()` in `session-start.ts`). A **second narrow re-review follow-up** then caught one
  more integration defect: `beginOnlineSession()`'s fail-closed behavior was itself correct (`setSessionId` never
  called on failure), but that very fact kept `isAwaitingStart` true, and `active.tsx` checked that (→ spinner)
  *before* checking whether a start error existed — so the error was set but unreachable behind an indefinite
  spinner. Fixed by extracting the render-state priority into its own tested function
  (`resolveWorkoutScreenState()` in `workout-screen-state.ts`), which checks the start error first. Section 11
  architecture, F-S4-01, F-S4-P13, F-S4-P14, permissions, RLS, server mutation semantics and the `OutboxStorage`
  design were not touched by any of the three rounds of this fix.

No ADR was needed for either finding: both are implementation corrections to how the frozen Section 11 requirement
and the client's own stated durability guarantee are realized, not behavior or scope changes.

## 3. Offline verification

`npm run verify` (typecheck + lint + Jest + `test:scripts` + `db:verify`), after the F-S4-02 second narrow re-review fix:

```
Typecheck:  0 errors
Lint:       0 errors, 0 warnings
Jest:       10 suites, 106 tests passed (+36 new: session-player.test.ts 20, outbox-sync.test.ts 5 [3 original + 2
            F-S4-02 recovery tests], session-start.test.ts 3 [F-S4-02 narrow re-review ordering/fail-closed tests],
            workout-screen-state.test.ts 8 [F-S4-02 second narrow re-review render-priority tests])
db:verify:  12 files, 508 assertions, 0 failed (unaffected — all three F-S4-02 fixes are client-only, no migration/SQL changed)
```

`db:verify` file breakdown: `001`–`010` (Sprints 1–3, unchanged, 443 total) + `011_workout_sessions_schema` (35) +
`012_workout_execution_and_outbox` (30) = 508.

Three mutation-testing passes confirmed all three rounds of the regression tests are real, not tautologies: (1)
temporarily reverting `persistHandshake`/`getHandshake` in `outbox-sync.ts` back to an in-process `Map` (the original
bug) made both `outbox-sync.test.ts` restart-recovery tests fail with precisely the Reviewer's described symptom; (2)
temporarily reverting `beginOnlineSession()` to call `onReady` before awaiting `persistHandshake` and leaving its
rejection unhandled (the first narrow-re-review bug) made all three `session-start.test.ts` tests fail; (3)
temporarily reverting `resolveWorkoutScreenState()`'s check order to spinner-before-error (the second narrow-review
bug) made exactly the one test asserting that priority fail, with the exact described symptom (`{kind: 'starting'}`
returned instead of `{kind: 'start-error', ...}`), the other 7 in that file unaffected. All three pass again once
their respective fixes are restored.

The `outbox-sync.test.ts` suite includes the Section 11 acceptance scenario verbatim: offline start → offline
`RECORD_SET` → reconnect (`processQueue()`) → `START_SESSION` dispatches first and hands back the `session_id` +
`exercise_mapping` handshake → the queued `RECORD_SET` resolves through it and dispatches → disconnect again at
completion → a single coalesced `SYNC_BUNDLE` row → exactly one session, the granular rows never replayed once
coalesced. A second test proves causal-dependency blocking (a `RECORD_SET` never dispatches ahead of its session's
unresolved `START_SESSION`); a third proves the 5-attempt dead-letter threshold and manual retry.

## 4. TypeScript, hooks, services & UI (Tasks 4.9–4.14)

- `src/types/database.ts` regenerated from hosted (all 6 execution tables, 5 new/changed RPC signatures).
- `src/features/workouts/session-player.ts` — pure logic mirroring `app_private.validate_session_set` /
  `validate_abandonment` mode-by-mode, `buildSetPayload`, `buildFeedbackPayloads` (Rule E split), `buildOfflineBundle`
  (Task 4.5's exact wire format), `summarizeActual`. **20 Jest tests.**
- `src/features/workouts/session-store.ts` — a small Zustand store holding the one active session's local draft
  (substitutions/logged sets keyed by the immutable `workout_item_id`, never a server-generated
  `session_exercise_id`) across the active-workout and summary screens, since Expo Router unmounts a screen on
  navigation. See §9's scope note on what this does and does not persist.
- `src/features/workouts/session-start.ts` — **F-S4-02 narrow re-review**: `beginOnlineSession()` isolates the
  online-start ordering/fail-closed invariant (durable handshake write must succeed before the session is exposed as
  ready) so it's directly unit-testable, independent of `workout/active.tsx`'s other concerns. **3 Jest tests.**
- `src/features/workouts/workout-screen-state.ts` — **F-S4-02 second narrow re-review**: `resolveWorkoutScreenState()`
  isolates the top-level render-state priority decision (a start/persistence error must outrank the "still starting"
  spinner, since a failed start keeps the session non-ready by design) so it's directly unit-testable, independent of
  `workout/active.tsx`'s native/query dependencies. **8 Jest tests.**
- `src/services/storage/` — `outbox-types.ts` (shared shape, incl. `SessionHandshake` and the
  `saveHandshake`/`getHandshake` contract added by F-S4-02), `sqlite-outbox.ts` (native, `expo-sqlite`; the
  `offline_mutations` table plus a `session_handshakes` table), `web-outbox.ts` (web, IndexedDB with a second
  `session_handshakes` object store; an in-memory adapter strictly under `NODE_ENV === 'test'`), `outbox-storage.ts` /
  `outbox-storage.web.ts` (Metro platform selection, matching the existing `auth-storage.ts`/`.web.ts` convention).
- `src/services/sync/outbox-sync.ts` — `OfflineOutboxService`: FIFO-per-session dispatch with causal-dependency
  blocking, exponential backoff, 5-attempt dead-letter + manual retry, the online-start reconnection handshake
  (**F-S4-02: durably persisted, never an in-process cache**), and terminal `SYNC_BUNDLE` coalescence. **5 Jest
  tests** (3 original + 2 F-S4-02 restart-recovery tests), including the full Section 11 acceptance scenario (§3).
- `src/hooks/useRestTimer.ts` — absolute wall-clock `restEndsAt`, recalculated on every `AppState` foreground
  transition (never a decrementing counter); foreground chime (`expo-audio`, a synthesized two-tone WAV generated by
  `scripts/assets/generate-rest-chime.mjs` — no third-party audio asset needed) + haptic (`expo-haptics`); a
  background date-trigger notification (`expo-notifications`) as the reliable backgrounded/locked-screen alert,
  cancelled on foreground return, skip or unmount.
- `src/components/ExerciseSubstitutionModal.tsx` — exercise search, mode and reason selection; disables the whole
  substitution action once the item has a logged set (F-S4-P14 client-side, mirroring the server's `22000`).
- `src/app/(athlete)/workout/active.tsx` — the interactive player: starts (or resumes) the session, checks
  connectivity itself for every action (online → direct RPC; offline → durable outbox), a rest-timer banner, and
  step-by-step exercise/set progression with a "Swap this exercise" action.
- `src/app/(athlete)/workout/summary.tsx` — prescribed-vs-actual per exercise, the finished/ended-early toggle with
  abandonment reason, ordinary difficulty/energy rating, and the private discomfort form with an explicit visibility
  notice. Completion routes through a direct `complete_workout_session` call when the session never went offline, or
  a coalesced `SYNC_BUNDLE` otherwise (see §9).
- `src/app/(athlete)/workouts/[id].tsx` — added a "Start workout" action linking into the player.
- `(athlete)/_layout.tsx` — two new `Stack.Screen` entries; typed routes regenerated (`npx expo customize
  tsconfig.json`, the documented workaround since routes only regenerate via `expo start` otherwise).

## 5. Database changes applied to hosted `bacalsys-dev`

All 7 migrations applied via the Supabase MCP (`training_view_private_feedback_permission`,
`workout_execution_schema`, `workout_execution_rls`, `workout_execution_rpcs`, `sync_offline_session_bundle`, and —
after the performance advisor flagged 4 uncovered foreign keys — `workout_execution_fk_indexes`). `list_migrations`
confirms all 7 land after Sprint 3's final `workout_payload_limits_and_compound_block_cardinality`.
`generate_typescript_types` re-run after the schema/RPC migrations landed.

## 6. Hosted Execution Acceptance Slice 1 — Live Player, Substitution & Split Feedback

`node --env-file=.env.hosted.local scripts/e2e/sprint4-slices.mjs slice1` — **18/18**:

1–2. The athlete starts a session from the fixture routine; `exercise_mapping` is keyed by `workout_item_id`.
3–5. Substitutes Pull-up → Parallel Bar Dip (`pain_discomfort`) before any set, logs a set, completes with split
   feedback (`difficulty_rating: 8, energy_level: 4`; `has_discomfort: true, discomfort_area: 'Left Shoulder'`).
6–8. `completed_at >= started_at`; exactly 1 substitution (`pain_discomfort`); exactly 1 private feedback row.
9–11. The current primary coach sees the session, the private feedback, and the sensitive substitution.
12–15. The Leader (`training:view_org`) sees the session and ordinary feedback, but **0 rows** of private feedback
   and **0 rows** of the sensitive substitution.
16. The former coach (tenure closed before this session) sees **0 rows**.
17–18. A `training:view_org`/`audit:view` holder queries `audit_logs`: the private-feedback event's sensitive fields
   and the substitution's `reason_code` are uniformly `[REDACTED]` (F-S4-P13).

## 7. Hosted Acceptance Slice 2 — Offline Outbox, Interrupted Connectivity & Replay Idempotency

`node --env-file=.env.hosted.local scripts/e2e/sprint4-slices.mjs slice2` — **6/6**:

1. A session starts **online**.
2–4. A single `sync_offline_session_bundle` call (simulating the interrupted-connectivity path: one substitution,
   3 sets, split feedback, `existing_session_id` set) syncs into that same session; it transitions to `completed`
   with exactly 3 sets — zero data loss.
5–6. Resending the **identical** bundle payload with the same idempotency key returns the cached success and creates
   **zero** additional sets.

## 8. Concurrency Verification Probes

`node --env-file=.env.hosted.local scripts/e2e/sprint4-slices.mjs concurrency` — **6/6**:

1–2. Two concurrent `start_workout_session` calls with the **same** idempotency key: both succeed, resolve to the
   identical `session_id` (the row-level reservation lock serializes them; no duplicate session).
3. Two concurrent `record_session_set` calls with the **same** key: exactly one set (`set_id` matches on both sides).
4. A different athlete/key starts a fully independent session concurrently, unaffected.
5. The **same** athlete attempting a second session with a **different** key is rejected with `23505` (the partial
   unique index + profile row lock).
6. `record_session_set` racing `complete_workout_session` on the same session: completion always succeeds; the
   racing set either wins cleanly before the lock, or fails closed with `22000` (terminal session immutable) — never
   a corrupted or partially-applied state either way.

## 9. Design decisions not fully specified by the frozen text

Recorded here rather than as findings, since none of them contradict Section 11 — they fill in gaps the frozen text
left open:

- **Actual-set mode exclusivity vs. presence** (`validate_session_set` / `validateActualSet`): mode exclusivity (an
  exercise's actuals may only ever carry the fields its mode supports) always applies; the PRESENCE of the mode's
  primary metric is required only when `is_completed = true`, so an athlete can log "attempted, not completed"
  without a number. `technique_practice` has no notes-only fallback (Rule E: `session_sets` carries no notes column
  at all, unlike the prescription table).
- **Client-generated ids**: correlation and idempotency keys are minted client-side via `src/lib/random-id.ts` (a
  Math.random-based RFC4122-v4-ish generator), not `expo-crypto`, since they are never used for cryptographic
  purposes and adding a native dependency purely to mint local ids was judged unnecessary scope.
- **Mixed online/offline-in-one-session completion**: summary.tsx always completes through the coalesced
  `SYNC_BUNDLE` path whenever the session ever went offline (any pending/unsynced outbox row for its correlation id
  exists) or never got an online `session_id`, regardless of connectivity at completion time — never a direct
  `complete_workout_session` call in that case. This avoids a real race the frozen spec does not itself resolve: a
  bundle unconditionally replays every substitution/set in its arrays, and an item already applied via an earlier
  successful granular RPC call (a session that went online → offline → online again mid-workout) would hit `23505`
  on replay and abort the whole bundle. The two scenarios the frozen Acceptance Slices actually specify — fully
  online, and online-start-then-offline-through-completion — are both covered without this gap (§6, §7); a session
  that alternates connectivity mid-workout is **not** exercised by either hosted slice and is called out explicitly
  as untested below, not silently assumed correct.
- **In-memory session draft**: `session-store.ts` (the athlete-facing UI draft: which exercises are on screen, what's
  been typed) does not persist across an app process kill — that remains unchanged and out of scope for this sprint.
  This is a **different** thing from the outbox's own server *handshake*, which — per the F-S4-02 fix — now IS
  durable across a restart precisely so the already-enqueued outbox rows it survives alongside can actually finish
  syncing; before that fix, this bullet's claim about outbox rows was not reliably true (see F-S4-02). Only the
  athlete's local view of an in-progress session (and any not-yet-submitted set they were mid-typing) is not
  recovered. Full
  app-relaunch mid-session recovery was judged out of scope for this sprint (see §11).
- **Circuit/AMRAP player pacing**: the player presents each prescribed item's sets in block/item order and lets the
  athlete log actual sets freely (any `set_number`, matching or not the prescribed count); it does not auto-repeat a
  circuit block's items across `circuit_rounds`, nor run an AMRAP countdown UI. The domain data model does not
  require either (an athlete can simply log more sets), and neither is exercised by the frozen Acceptance Slices.

## 10. Hosted advisors

`get_advisors` (security, performance), re-run after all 7 migrations and the full hosted E2E exercise:

- **Security**: no new findings. The 4 pre-existing `authenticated_security_definer_function_executable` warnings are
  Sprint 1/2 RPCs (intentional); the leaked-password-protection warning is pre-existing and unrelated.
- **Performance**: the advisor flagged 4 uncovered foreign keys on the new execution tables
  (`session_exercises.workout_item_id`, `session_modifications.original_workout_item_id`,
  `session_modifications.replacement_exercise_id`, `session_sets.prescribed_item_set_id`) — a genuine Sprint 4 gap,
  fixed immediately with the forward migration `workout_execution_fk_indexes` (§5), re-verified clean. The
  `unused_index` INFO items are expected pre-traffic noise on a low-volume dev database (same as Sprint 3); the
  `multiple_permissive_policies` warning on `public.exercises` predates Sprint 4 (Sprint 2's exercise workflow) and
  was not touched.

## 11. Android dev-client boot

`npx expo run:android --device Pixel_4` (AVD `Pixel_4`) — **build, install and launch succeeded**:

- Gradle build: `BUILD SUCCESSFUL`, 475 tasks; the "Using expo modules" listing confirms all 4 new native modules
  autolinked (`expo-audio` 57.0.5, `expo-haptics` 57.0.3, `expo-notifications` 57.0.21, `expo-sqlite` 57.0.3).
- The dev client (`ph.bacalsys.app`) installed and launched: `dumpsys activity activities` shows
  `topResumedActivity=ActivityRecord{… ph.bacalsys.app/.MainActivity}` in the foreground.
- `logcat` after boot: no `FATAL`, `AndroidRuntime` crash, or module-related exception. The only `E`-level lines are a
  benign, well-known Expo dev-client cosmetic race (`WindowManager: BadTokenException` from the dev-loading popup
  trying to attach before the activity is fully resumed) and frame-skip/JIT-verification timing warnings — normal
  emulator noise, not application errors.
- A first attempt (emulator not yet fully booted when Gradle finished) failed only at the `adb`-install step
  (`device 'emulator-5554' not found`); the emulator was confirmed booted (`sys.boot_completed=1`) and the run
  repeated successfully above — the APK itself built cleanly both times.
- Interactive in-app click-through on the native build (opening the Workout Player screens) was not performed this
  round — redirected to the web verification below instead. This is narrower than a full manual walkthrough, but
  confirms the concrete regression class native modules risk (a build/link/boot failure) did not occur.

## 12. Deployment & CI

- Commit [`d6732d3`](https://github.com/carvele/bacalsys/commit/d6732d3) — the full Sprint 4 implementation (database
  + client) — pushed to `main`. CI [run 36324519669](https://github.com/carvele/bacalsys/actions/runs/36324519669):
  **green**.
- Commit [`d173343`](https://github.com/carvele/bacalsys/commit/d173343) — the hosted E2E script. CI
  [run 36327084129](https://github.com/carvele/bacalsys/actions/runs/36327084129): **green**.
- Commit [`4008164`](https://github.com/carvele/bacalsys/commit/4008164) — hosted evidence, F-S4-01 finding, and the
  `workout_execution_fk_indexes` migration. CI [run 36327659766](https://github.com/carvele/bacalsys/actions/runs/36327659766):
  **green**.
- Commit [`435337c`](https://github.com/carvele/bacalsys/commit/435337c) — Android/web boot evidence. CI
  [run 36329178710](https://github.com/carvele/bacalsys/actions/runs/36329178710): **green**.
- Commit [`03e634f`](https://github.com/carvele/bacalsys/commit/03e634f) — the **F-S4-02 fix** (Reviewer gate rework).
  CI [run 36330960227](https://github.com/carvele/bacalsys/actions/runs/36330960227): **green**.
- Commit [`6f46e90`](https://github.com/carvele/bacalsys/commit/6f46e90) — F-S4-02 rework evidence (ACCEPTANCE.md +
  CI confirmation). CI [run 36331210108](https://github.com/carvele/bacalsys/actions/runs/36331210108): **green**.
- Commit [`4b7da12`](https://github.com/carvele/bacalsys/commit/4b7da12) — the **F-S4-02 narrow re-review fix**:
  `active.tsx` ordering/fail-closed correction via `beginOnlineSession()` (new `session-start.ts` + 3 Jest tests),
  the finding-doc follow-up section, and this STATUS.md/ACCEPTANCE.md update. CI
  [run 36332796594](https://github.com/carvele/bacalsys/actions/runs/36332796594): **green**.
- Commit [`455763f`](https://github.com/carvele/bacalsys/commit/455763f) — filled in the `4b7da12` commit hash/CI link
  above once available. CI [run 36332997632](https://github.com/carvele/bacalsys/actions/runs/36332997632): **green**.
- Commit `<pending>` — the **F-S4-02 second narrow re-review fix**: `active.tsx` render-priority correction via
  `resolveWorkoutScreenState()` (new `workout-screen-state.ts` + 8 Jest tests), the finding-doc follow-up section,
  and this STATUS.md/ACCEPTANCE.md update. CI run `<pending>` — to be filled in once pushed.
- **Web smoke check**: opened the live deployment (`https://carvele.github.io/bacalsys/`, rebuilt by each of the runs
  above) in a browser under the product owner's own already-signed-in session — home screen and the "Workout
  routines" → "My routines" catalog screen both render with zero console errors. No mutating action was taken (no
  routine created, no session started) since that account is the product owner's real one, not a test fixture; a
  full signed-in click-through of the new Workout Player screens is still pending the product owner, same as every
  prior sprint's standing rule against the Executor entering credentials or acting on a live personal account beyond
  a read-only check.

## 13. What was not verified

- **F-S4-02 hosted recovery probe**: not applicable / not performed. The defect and its fix are entirely about
  client-local storage surviving an app/process restart; the hosted RPC-only E2E script has no local outbox of its
  own to restart, and the server-side behavior it would otherwise exercise (idempotent `start_workout_session`,
  correct `record_session_set` resolution given a valid `session_id`) was never the problem and is already covered
  by Slice 1 and the concurrency probes. See F-S4-02's finding doc "Evidentiary note" for the full reasoning. The two
  new Jest tests, exercising the real `OutboxStorage` contract through a destroyed and recreated service instance,
  are the correct evidentiary tier for this guarantee.
- **`supabase test db` / local Docker stack**: unavailable in this environment (same waiver as Sprints 1–3).
- **Signed-in UI click-through**: not performed by the Executor; pending the product owner.
- **Hosted fixture cleanup**: the Sprint 4 tagged fixture accounts (6 profiles + 1 organization) were not removed
  after the E2E runs — same "the product owner's call" waiver as Sprints 2–3.
- **Row-lock concurrency under true simultaneous transactions**: the hosted probes fire concurrent RPC calls over
  separate PostgREST connections and assert the *outcome*, not the lock wait itself — same evidentiary standard
  accepted for Sprints 2 and 3.
- **Mixed online/offline-in-one-session completion**: see §9 — not exercised by either hosted Acceptance Slice, and a
  known (documented, not silently assumed away) gap in the bundle-replay path for that specific scenario.
- **App-process-kill mid-session recovery**: see §9 — the in-memory session draft does not survive a kill; only the
  already-enqueued durable outbox rows do.
- **Circuit-block round repetition / AMRAP countdown UI**: see §9 — the player does not auto-expand rounds or run a
  countdown; the athlete can freely log additional sets instead.
