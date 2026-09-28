# Sprint 5: Assignments & Database-Level Scheduling — engineering status

> **Status: ACCEPTED — CLOSED (2026-09-28).** The Reviewer's verdict, relayed by the product owner: *"Sprint 5
> implementation gate: ACCEPTED — CLOSED."* Accepted head: `f87d807a7486af31e3cb9939c616b90783a52e82`, tagged
> `sprint-05-accepted`. The Reviewer independently confirmed CI run 36441645436 (both jobs green), the round-2 commit's
> scope, the Android screenshots, the hosted occurrence/session link and the F-S5-05 fix; F-S5-03 and F-S5-04 remain
> non-blocking backlog refinements, and Sprint 4 is not reopened. The Reviewer also ruled that submitting the Assign
> modal, a full on-device workout, the Rule C panel, Android-offline, iOS and hosted-fixture cleanup are **not** Sprint 5
> blockers (they stay listed in §13 as unverified).
>
> *History.* Round 1 returned *REWORK REQUIRED — verification-only* with a single blocking item, F-S5-G01
> (Android dev-client feature verification). §11.1 is that evidence. The smoke pass found one real bug —
> [F-S5-05](findings/F-S5-05-online-start-cancelled-by-its-own-rerender.md), latent since Sprint 4 — which is fixed with a
> failing-first regression test. No database, RLS, permission or architecture change was made in round 2. Per the
> standing workflow the Executor never self-approves; [ACCEPTANCE.md](ACCEPTANCE.md) carries the gate rows.
>
> **Baseline:** `sprint-04-accepted` (commit `6731f31`). Roadmap v1.2 Section 12, Tasks 5.0–5.15, implemented as frozen.
> D1–D5 and Sprints 1–4 were not reopened; no ADR was needed (see §2 and §9).

- **Environment:**
  - Hosted dev project `bacalsys-dev` (`sfptojkkmjggssqzyseo`), PostgreSQL **17.6**; `pg_cron` **1.6.4** (installed by
    the scheduling migration, see [F-S5-02](findings/F-S5-02-pg-cron-not-installed-on-hosted.md)).
  - Offline harness: PGlite, PostgreSQL **18.3**, with a `cron.schedule()` shim (Task 5.0).
  - Docker is unavailable, so `supabase test db` and the local stack were **not run** (same waiver as Sprints 1–4).
  - Android emulator: AVD `Pixel_4`.

## 1. Tasks 5.0–5.15

| Task | Status | Deliverable / evidence |
|---|---|---|
| 5.0 Harness shim | ✅ | `scripts/db/supabase-shim.sql`: `cron` schema, `cron.job`, `cron.schedule()` (pg_cron's upsert-by-name semantics). Baseline re-verified green (508) before any migration was written |
| 5.1 Assignment DDL & lifecycle trigger | ✅ | `20260928051523_workout_assignments_schema`: idempotency types expanded by exactly the 3 scoped values; `workout_assignments`, `assignment_targets`, `recurring_schedules` (weekday CHECK, timezone trigger 22023), `assignment_occurrences` (6 states, `completed_at` consistency, per-athlete-per-day unique); `workout_sessions.assignment_occurrence_id` FK **ON DELETE RESTRICT** + partial unique index; `enforce_occurrence_lifecycle` trigger; SELECT-only grants, RLS enabled |
| 5.2 RLS & row-scope helpers | ✅ | `…051529_workout_assignments_rls`: `can_view_assignment`, `can_view_assignment_target` (target-safe), `can_view_assignment_occurrence` (half-open former-coach window); leadership resolved from `workout_assignments.organization_id`, never from a profile column |
| 5.3 Scheduling engine & pg_cron | ✅ | `…051534_assignment_cron_scheduling`: `generate_assignment_occurrences` (shared per-assignment horizon), `generate_recurring_occurrences`, `mark_overdue_assignments_as_missed` (`actor_type='cron'`), the two frozen cron jobs |
| 5.4 Create / cancel RPCs | ✅ | `…051540_workout_assignments_rpcs`: `create_workout_assignment`, `cancel_workout_assignment` (+ `can_manage_assignment`, `normalize_days_of_week`) |
| 5.5 Rule C RPC | ✅ | `…051549_assignment_version_migration`: `migrate_assignment_version` — three mutually exclusive choices |
| 5.6 Session & bundle occurrence handshake | ✅ | `…051559_workout_session_occurrence_handshake`: 2-arg + 3-arg `start_workout_session` wrappers over ONE 3-arg private implementation; `complete_workout_session` occurrence transition; `sync_offline_session_bundle` with structural late-sync reconciliation and the offline-resilience fallbacks |
| 5.7 pgTAP schema/RLS suite | ✅ | `013_workout_assignments_schema.test.sql`, **53** assertions |
| 5.8 pgTAP scheduling/lifecycle suite | ✅ | `014_assignment_scheduling_and_lifecycle.test.sql`, **61**; plus `015_assignment_offline_reconciliation.test.sql`, **24** (offline half, split out for size) |
| 5.9 Hosted Slice 1 | ✅ | §6: **23/23** |
| 5.10 Timezone & date utilities | ✅ | `src/lib/date-tz.ts` — **14 Jest tests** |
| 5.11 AssignWorkoutModal | ✅ | `src/components/AssignWorkoutModal.tsx` + pure logic `features/assignments/assignment-form.ts` (**11 tests**) |
| 5.12 Rule C UI | ✅ | `src/components/VersionAdoptionPanel.tsx` wired into `workouts/version.tsx`; `features/assignments/version-migration.ts` (**5 tests**) |
| 5.13 Athlete home "Today's training" | ✅ | `src/components/TodaysTrainingCard.tsx`; `features/assignments/occurrences.ts` (**6 tests**); the Workout Player takes `occurrenceId` |
| 5.14 Coach roster integration | ✅ | `src/app/(coach)/my-athletes.tsx`: upcoming count + next date per athlete, per-athlete "Assign workout"; "Assign to athletes" on the routine detail screen |
| 5.15 Concurrency probes + hosted Slice 2/3 + regression + Android boot + this report | ✅ (Android: §11) | §7, §8, §3, §11 |

## 2. Findings (one file each in [findings/](findings/))

| # | Class | Summary |
|---|---|---|
| [F-S5-01](findings/F-S5-01-racing-start-must-fail-22000-not-23505.md) | Bug | Appending the frozen occurrence checks behind Sprint 4's profile lock would make a racing different-key start fail `23505`, not the mandated `22000`. Fixed by resolving assignment → occurrence **before** the profile lock, in both the online and offline paths (also avoids a start-vs-bundle lock inversion). |
| [F-S5-02](findings/F-S5-02-pg-cron-not-installed-on-hosted.md) | Backlog Refinement | `pg_cron` was available but not installed on hosted; the migration enables it (only when available) ahead of the unchanged fail-loud `0A000` guard. |
| [F-S5-03](findings/F-S5-03-offline-bundle-vs-rule-c-version-drift.md) | Backlog Refinement (**open decision for the Planner**) | An offline workout whose `upcoming` occurrence was Rule-C-migrated while the athlete was offline fails `22000` (literal frozen contract). Options A/B/C written up; none taken. |
| [F-S5-04](findings/F-S5-04-recurring-schedule-timezone-copy-can-go-stale.md) | Backlog Refinement | `recurring_schedules.timezone` is a write-time copy; the generator reads the authoritative `organizations.timezone`, so behaviour is correct. |

| [F-S5-05](findings/F-S5-05-online-start-cancelled-by-its-own-rerender.md) | Bug (found by the Android smoke gate F-S5-G01; **latent since Sprint 4**) | The Workout Player's start effect depended on `activeSession`; `begin()` changed it, the effect's own cleanup cancelled the in-flight start, and the response (session already created server-side) was discarded — the screen hung on "Starting your workout…". Fixed by extracting `useSessionStart` (cancellation only on unmount; `startedRef` guarantees one start) with 5 failing-first tests. |

No finding needed an ADR; no ADR was created and no deviation from Section 12's architecture was made.

## 3. Offline verification

`npm run verify` (typecheck + lint + Jest + `test:scripts` + `db:verify`), final run on the code commit:

```
Typecheck:  0 errors
Lint:       0 errors, 0 warnings
Jest:       14 suites, 145 tests passed   (baseline 10 / 106 → +4 suites, +39 tests)
test:scripts (node:test): 2 suites, 9 tests passed (unchanged)
db:verify:  15 files, 646 assertions, 0 failed (baseline 12 / 508 → +3 files, +138 assertions)
```

New Jest: `date-tz` 14, `assignment-form` 11, `version-migration` 5, `occurrences` 6, plus 2 bundle-occurrence tests in
`session-player.test.ts` and 1 assigned-vs-direct `START_SESSION` dispatch test in `outbox-sync.test.ts`.
New pgTAP: `013` 53, `014` 61, `015` 24. The existing `012` was edited in one place only: its structural lock check
referenced the old 2-arg `start_workout_session_internal` signature that Section 12 explicitly forward-migrates.

Web bundle: `npm run build:web` ✅ (exports the new screens; backend check passes).

**Mutation testing** (the Sprint 3/4 convention — break the implementation, confirm the matching test goes red;
the migrations were restored byte-for-byte afterwards): seven invariants were mutated and **all seven are caught**:
occurrence-must-be-`upcoming` (014 #28, #31), direct `missed → terminal` (013 #22), former-coach window (013 #31),
14-day horizon (014 #7, #15, #16), post-deadline reconciliation (015 aborts on the trigger), target-safe RLS
(013 #29, #30), creator-shortcut cancellation authority (014 #43, #44). One mutation initially **escaped** (dropping the
"`missed → terminal` is prohibited" branch, because the linked-session requirement independently blocked it); that
exposed a missing test — *a direct `missed → completed` must fail even when a valid pre-deadline linked session
exists* — which was added (013 #22) and now catches it.

## 4. Database & client changes

**Database** (all forward-only; no applied migration edited):

- Tables: `workout_assignments`, `assignment_targets`, `recurring_schedules`, `assignment_occurrences`; FK
  `fk_workout_sessions_assignment_occurrence` (RESTRICT) and `uq_workout_sessions_assignment_occurrence`.
- Public wrappers (all `SECURITY INVOKER`): `create_workout_assignment`, `cancel_workout_assignment`,
  `migrate_assignment_version`, `start_workout_session` (×2). Internals (`SECURITY DEFINER`, `search_path=''`):
  the matching `app_private.*_internal` functions, `can_manage_assignment`, the RLS helpers, the generator, the
  overdue job, `complete_assignment_occurrence`, `normalize_days_of_week`, and the two trigger functions.
- Signature inventory (asserted in pgTAP 013 and on hosted): **2** public `start_workout_session` signatures,
  **exactly 1** `app_private.start_workout_session_internal(uuid, uuid, uuid)`.

**Client:**

- `src/lib/date-tz.ts`; `src/features/assignments/{assignment-form,version-migration,occurrences,use-org-timezone}.ts`.
- `AssignWorkoutModal`, `VersionAdoptionPanel`, `TodaysTrainingCard`; `(coach)/my-athletes.tsx`, `workouts/[id].tsx`,
  `workouts/version.tsx`, `(athlete)/index.tsx` updated.
- Occurrence identity threaded end to end: `session-store` (`assignmentOccurrenceId`), player route params
  (`versionId` + `occurrenceId`), `START_SESSION` outbox payload → 3-arg RPC when assigned (2-arg otherwise), and the
  `OfflineSessionBundle` wire format's nullable `assignment_occurrence_id`. `OutboxStorage`/SQLite/IndexedDB were not
  touched.
- `src/types/database.ts` regenerated from the hosted project after the migrations.

## 5. Hosted migration status (`bacalsys-dev`)

Applied via the Supabase MCP, in order (`list_migrations` confirms all six land after Sprint 4's
`workout_execution_fk_indexes`):

| Repository file | Hosted migration | Hosted version |
|---|---|---|
| `20260928051523_workout_assignments_schema.sql` | `workout_assignments_schema` | `20260928054523` |
| `20260928051529_workout_assignments_rls.sql` | `workout_assignments_rls` | `20260928054542` |
| `20260928051534_assignment_cron_scheduling.sql` | `assignment_cron_scheduling` | `20260928054600` |
| `20260928051540_workout_assignments_rpcs.sql` | `workout_assignments_rpcs` | `20260928054642` |
| `20260928051549_assignment_version_migration.sql` | `assignment_version_migration` | `20260928054704` |
| `20260928051559_workout_session_occurrence_handshake.sql` | `workout_session_occurrence_handshake` | `20260928054755` |

The hosted copies carry the SQL statements without the explanatory header comments (comments were omitted only to keep
the tool payload small; the executable statements are identical to the repository files, which pgTAP builds from).
Post-apply verification on hosted: `cron.job` = the two frozen jobs; 2 public / 1 private start signatures; RLS on all
four tables; no client INSERT/UPDATE/DELETE grant on any of them; **0** `SECURITY DEFINER` functions without a pinned
`search_path`.

## 6. Hosted Acceptance Slice 1 — creation, multi-targeting, recurrence, RLS reach

`node --env-file=.env.hosted.local scripts/e2e/sprint5-slices.mjs slice1` — **23/23** (fixtures: two Coaches, three
Athletes, a Former Coach, Leader, Vice President, a Leader in a second organization — registered by the script, approved
by the seeded President, wired up by the operator SQL step it prints):

1–2. A Leader creates a recurring Mon/Wed/Fri assignment (`days_of_week [5,1,3,1]` sent) for Athletes A and B with a
   coach note — 12 occurrences (6 days × 2 athletes) for the real 14-day window.
3–5. A Coach creates a single-date assignment for their own athlete tomorrow; replaying the same key returns the same
   assignment; the same key with a different payload fails `42501`.
6–10. Both assignments active and pinned to the sealed version; `assignment_targets` = 3 rows; the schedule stores
   `{1,3,5}`, `Asia/Manila`, active; each athlete holds exactly the Mon/Wed/Fri dates of `[today, today+13]`;
   `due_datetime` = the next local midnight.
11–16. Athlete A sees only their own occurrences; Athlete B only their own Mon/Wed/Fri occurrences and **only their own
   target row**; Athlete A's coach sees A's target row but **not B's** on the shared assignment (target-safe RLS); B's
   coach sees only B's row.
17. A leader from **another organization** receives **0 rows** of assignments, targets, schedules and occurrences.
18–20. A past-dated assignment falls inside the **former coach's** closed window: they see **0 assignments / 0
   targets** and exactly that one occurrence.
21–23. An athlete cannot create (`42501`); a coach cannot assign to an athlete they do not coach (`42501`); a direct
   client `INSERT` into `workout_assignments` is rejected (`42501`).

## 7. Hosted Acceptance Slice 2 — occurrence execution, overdue cron, cancellation immutability

`slice2` (**11/11**, re-run once after a script tweak that pins versions explicitly), then the operator ran
`SELECT app_private.mark_overdue_assignments_as_missed();`, then `slice2b` (**12/12**):

- Today's occurrence: `upcoming → in_progress → completed`, `completed_at` populated; a client UPDATE/DELETE of it
  changes nothing.
- Yesterday's unstarted occurrence became `missed`, audited `actor_type = 'cron'`, `actor_user_id = NULL`; today's
  completed occurrence was untouched.
- The recurring assignment was cancelled by its coach (replay returns the cached result): every today/future `upcoming`
  occurrence was deleted, while the **past history seeded onto it — an overdue `upcoming`, a `missed` and a `completed`
  occurrence — survived untouched** (F-S5-P12); the schedule is inactive; the cancellation is audited `actor_type =
  'user'`; a start on it fails `22000`.
- **Privileged-path proof** (run as the owner role in the SQL editor): `UPDATE` of the completed occurrence →
  `22000 Historical occurrence in terminal status completed is immutable`; `DELETE` → `22000 Cannot delete historical
  occurrence with status completed`; a direct `missed → completed` → `22000 … direct missed to terminal is prohibited`;
  all three rows unchanged.

`slice3` — **13/13** (Rule C): `selected_upcoming_assignments` moved exactly the two selected occurrences to V2 while
the **assignment default stayed V1** and the unselected occurrence stayed on V1; `version_migrated` audited with the
choice, old/new versions and the migrated ids; an **in-progress** and a **completed** occurrence in a selection each fail
`22000`; the session stayed pinned; `future_assignments_only` moved the assignment default to V2 with every existing
occurrence still on V1; `template_only` changed nothing; a coach without scope over the target cannot migrate (`42501`).

## 8. Concurrency verification probes (hosted)

**Client-driven** (`sprint5-slices.mjs concurrency`, two authenticated sessions, real overlapping HTTP calls) — **9/9**:

1. Two concurrent `CREATE_ASSIGNMENT` with the same key → the identical assignment; exactly one assignment, one occurrence.
2. Two concurrent assigned `START` with the same key → the identical session; exactly one session linked.
3. Two concurrent assigned `START` with **different keys** → exactly one success, the other **`22000`** (4/4 rounds).
4. **START vs CANCELLATION** (6 rounds): 5× start-first (its `in_progress` occurrence survives cancellation), 1×
   cancel-first (occurrence deleted; START fails `22000`) — **both legal serializations observed**, no inconsistent state.
5. Two concurrent `CANCEL` (5a) and two concurrent `MIGRATE` (5b) with the same key → both return the cached logical
   success; exactly one `version_migrated` audit row.

**Service-side** — the overdue job and the generator are not callable by any client role, and the SQL tooling
serializes calls, so two ordinary sessions can never overlap. These probes use `pg_cron` itself: a one-off probe job
runs in its **own background session**, takes the lock under test and holds it (`pg_sleep`, transaction open) while a
second session races it ([sprint5-cron-races.sql](../../../scripts/e2e/sprint5-cron-races.sql)). Every job was
unscheduled afterwards; `cron.job` holds only the two production jobs.

| Probe | Held by | Racer | Observed |
|---|---|---|---|
| **R3a** START vs overdue job | overdue job holds the occurrence lock (25 s) | START, different session | START **blocked 16.1 s**, then failed **`22000`** ("…is missed and can no longer be started") |
| **R3b** START vs overdue job | START holds the occurrence lock, uncommitted | the real overdue job | the row still read `upcoming` to the second session; the job returned in **1 ms** having moved **0** rows (`SKIP LOCKED`); afterwards the occurrence is `in_progress`, 1 linked session, **0** cron audit rows for it |
| **R5a** generator vs cancellation | cancel holds the assignment `FOR UPDATE` | the real generator | generator saw `active`, **waited 5.4 s**, then created **0** rows for the cancelled assignment (10 went to an unlocked one) |
| **R5b** generator vs cancellation | generator holds `FOR SHARE` | a leader's cancel | cancel **waited 31.6 s**, then deleted **14** rows (the original 4 + the 10 the generator had just created); 0 left |

Two probe attempts were invalid and were redone, not counted: an early attempt used two sequential SQL calls
(no overlap), and one R3b attempt failed because a leftover in-progress session (from that first non-overlapping
attempt) tripped the one-active-session rule inside the probe job — visible in `cron.job_run_details`, cleaned up,
re-run cleanly.

## 9. Design decisions not fully specified by the frozen text

Recorded here (none contradicts Section 12) rather than as findings:

- **Start ordering** — see F-S5-01.
- **Create validation order**: template exists (`P0002`) → version belongs to the template (`22023`) → sealed (`22000`) →
  viewable by the caller (`42501`) → template-source rules (org template = caller's organization; private template = every
  target is its creator) → per-athlete scope + organization (`42501`) → schedule shape (`22023`).
- **Offline-bundle outcomes for a brand-new session that names an occurrence** — linked when `upcoming`; reconciled
  when `missed` and `scheduled_at ≤ started_at < due_datetime`; otherwise the workout is **preserved as a direct
  session and the occurrence is left exactly as it was**: occurrence deleted, assignment **cancelled** (even if a
  past occurrence row was preserved), missed with a post-deadline **or pre-schedule** start, or an occurrence that
  already has its own execution (in_progress/terminal). Another athlete's occurrence is `42501`; a version differing
  from the occurrence's pinned version is `22000` (F-S5-03). The frozen text names the deleted-occurrence and
  post-deadline cases; the rest apply the same "never dead-letter athlete data, never alter cancelled-assignment
  adherence" principle.
- **`missed → missed`** (a no-op UPDATE of a missed row) is also rejected `22000` — "terminal history immutable"
  read strictly; nothing legitimate updates a missed row without changing its status.
- **Direct-start idempotency hash** becomes `version:direct` (per the frozen formula), so a `START_SESSION` key minted
  *before* this deploy and retried *after* it would fail `42501`; only requests straddling the deploy are affected and
  clients mint a fresh key per start.
- **Timezone**: the generator/cancellation/lifecycle read `organizations.timezone` (F-S5-04). The horizon
  `[org_today, org_today+13]` is generated from an integer offset series, avoiding a `timestamptz` round-trip through the
  session time zone. One shared `generate_assignment_occurrences(assignment_id)` serves both the RPC and the nightly job.
- **Past `target_date`** is accepted by the RPC (the frozen text sets no rule); the UI only offers today or later. The
  hosted slices rely on it to fixture overdue and former-coach scenarios through the real RPC.
- **Cancel / migrate on a non-active assignment** → `22000`; occurrence ids passed with `template_only` /
  `future_assignments_only` → `22023` (mutually exclusive choices); duplicate ids are de-duplicated; the cancel audit
  records `deleted_occurrences`; start/bundle responses gained additive fields (`assignment_occurrence_id`,
  `occurrence_link`).
- **Athlete picker**: coaches see their current athletes; leadership sees the union of those and the roster they can read.
- **Today's training** shows the org-local today (plus an overdue occurrence still `in_progress`); a `missed`/`abandoned`
  occurrence shows its status chip with no action.

## 10. Hosted advisors

- **Security:** no new findings. The 4 `authenticated_security_definer_function_executable` warnings and the
  leaked-password-protection warning all predate Sprint 5 (Sprint 1 RPCs and an Auth setting); every new public wrapper is
  `SECURITY INVOKER`, so none is flagged.
- **Performance:** no missing-FK-index warnings (the `workout_version_id` FK on occurrences was indexed in the schema
  migration). The remaining items are informational `unused_index` notes on the brand-new tables (expected until traffic)
  and the pre-existing `exercises` multiple-permissive-policies warning.

## 11. Android dev-client boot & web check

Sprint 5 adds **no native module**, so the Sprint 4 dev client's native layer is unchanged; the gate is that the
current code still builds, installs and launches.

- `npx expo run:android --device Pixel_4`: Gradle **BUILD SUCCESSFUL** (3m 51s), APK installed, launched through the
  dev-client deep link. `dumpsys activity`: `ph.bacalsys.app/.MainActivity` is the **resumed activity**; the app process
  is alive with the React Native / Hermes libraries loaded and the dev-launcher services initialized; the `crash` log
  buffer contains **0** entries for `ph.bacalsys.app`. (The `Fatal signal 6` traces in logcat belong to the emulator's own
  `com.android.bluetooth` process.)
- **Not achieved — stated plainly:** I could not obtain a visual confirmation that the new JS *rendered* on the
  emulator. A first adb screenshot was solid black (the emulator display was asleep); after waking it, the emulator
  showed Android's own *"Process system isn't responding"* dialog — the `system` process, not our app — because Gradle,
  Metro and the offline test runs were starving it. On the product owner's instruction to **use the web app instead**
  ("use weeb instead"), the Android visual check was dropped and the background tasks stopped. Android evidence is
  therefore build / install / launch / no-crash only — the same standard Sprint 4's boot check reported — and an
  interactive on-device pass remains pending.
- **Web (read-only, deployed build of the code commit, product owner's own signed-in session):**
  `https://carvele.github.io/bacalsys/` renders the athlete home with the new **Today's training** card in its live-query
  empty state (*"No workouts scheduled for today. Your coach's assignments will appear here."*) — no error notice, **0
  console errors** — i.e. the occurrences query against the new tables succeeded under RLS for the President account.
  No routine, assignment or session was created and nothing was signed into or out of; a full signed-in click-through of
  the new screens is still pending the product owner. Local `npm run build:web` also passed (§3).

### 11.1 Round 2 — F-S5-G01 Android feature smoke (interactive, on the emulator, against `bacalsys-dev`)

Reviewer requirement: a disposable identity (not a personal account), the app visibly rendering signed in, Today's
training from the occurrence query, an assigned occurrence opening the player with its occurrence identity, and at least
one authorized assignment surface rendered *and* interacted with, with screenshots and a logcat result. Screenshots are
in [evidence/](evidence/).

- **Setup.** AVD `Pixel_4`, dev client built in round 1, Metro started with the **hosted** URL and public anon key
  exported for that process (the repo's `.env.local` points at `127.0.0.1:54321`, a local stack that does not exist here;
  it produced a generic "Something went wrong" on the first sign-in attempt and is unchanged). Identities: the tagged,
  disposable e2e fixtures `athletea…` and `coacha…` (`@e2e.bacalsys.local`). **The product owner typed both sign-ins**;
  the Executor did not enter credentials.
- **Athlete pass.**

  | Check | Result | Evidence |
  |---|---|---|
  | App renders (signed out) with no red screen | ✅ | `android-01-login-rendered.png` |
  | Signed-in athlete home renders; **Today's training** lists today's occurrences (Upcoming / Completed, version chips, coach note) from the live occurrence query under RLS | ✅ | `android-02-athlete-home-todays-training.png` |
  | **Start workout** on an upcoming occurrence opens the player | ❌ first attempt — hung on the spinner ([F-S5-05](findings/F-S5-05-online-start-cancelled-by-its-own-rerender.md)); ✅ after the fix, the player opens into the exercise (Push-up, *Set 1 · target 14 reps*) | `android-03-…BEFORE-fix.png`, `android-04-…AFTER-fix.png` |
  | The player is bound to the tapped occurrence (occurrence identity) | ✅ server-side: occurrence `88ef979a…` `in_progress`, **exactly 1** linked session (`assignment_occurrence_id` set), session version = occurrence version, athlete has exactly 1 active session. (The route param is not logged; the persisted link is the proof.) | query result quoted in F-S5-05 / ACCEPTANCE #30 |
  | Today's training reflects state change | ✅ the same occurrence now shows **In progress** with **Resume workout** | `android-05-todays-training-in-progress-resume.png` |

- **Coach pass (Coach A).**

  | Check | Result | Evidence |
  |---|---|---|
  | Coach home renders (Coaching, Officer tools) | ✅ | `android-06-coach-home.png` |
  | My athletes: per-athlete upcoming count and next date (57 / 15 upcoming, next *Mon, Sep 28*) and an **Assign workout** button each | ✅ | `android-07-my-athletes-roster.png` |
  | **AssignWorkoutModal** renders (routine picker, athlete picker preselected to the tapped athlete, Schedule, Version, Notes) | ✅ | `android-08-assign-workout-modal.png` |
  | Interaction: choose a routine, add a second athlete (*2 selected*), Single date (defaults to the organization's today, 2026-09-28), version chips Latest/v3/v2/v1, toggle **Recurring** → weekday chips, start/end date, "scheduled two weeks ahead in Asia/Manila" hint | ✅ | `android-09`, `android-10`, `android-11` |

- **Logcat.** The `crash` buffer holds **0** entries for `ph.bacalsys.app` across the whole session. `ReactNativeJS`
  errors: none after the final reload (~14:56 UTC). One `ReferenceError: Property 'sessionStartDeps' doesn't exist`
  (14:53:07 UTC) is **not** an app defect: Fast Refresh hot-loaded `active.tsx` while I was mid-edit on the F-S5-05 fix,
  before the constant was added. The emulator's own System UI showed one "isn't responding" dialog at first launch
  (Metro/emulator cold start on a 2 GB AVD), dismissed with *Wait*; it did not recur.
- **Fix verified.** Jest **15 suites / 150 tests** (was 14 / 145), Node **2 / 9**, typecheck 0, lint 0, offline pgTAP
  **15 files / 646** (unchanged), `npm run build:web` passes — all re-run after the fix.
- **Executor-side data actions (disclosed).** The failed first attempt left the athlete with an orphaned `in_progress`
  session; I closed it through the real `complete_workout_session` RPC (status `abandoned`, 0 sets → occurrence
  `abandoned`) by setting the athlete's JWT claims in a hosted SQL transaction — the same technique as the pgTAP `act`
  helper, no password involved. It is disposable fixture data. The second occurrence's session (`dfab087d…`) was left
  `in_progress` by the pass and is likewise fixture data.
- **Not covered by this pass (stated plainly).** (a) The Rule C `VersionAdoptionPanel` was **not** exercised on the
  device — the Reviewer accepted either surface, and `AssignWorkoutModal` was. (b) The Assign modal was **not
  submitted**, so create-from-UI on Android is unproven; creation is proven by hosted Slice 1 and the RPC tests. (c) In
  the player I did not log a set or finish the workout on the device (a stray Back key left the player before the set
  logged), so the on-device `in_progress → terminal` path is unproven; the server-side transition is proven by pgTAP
  014, hosted Slice 2, and by the RPC closing the orphan above. (d) Offline mode on the device was not exercised (the
  hook's offline branch is covered by a Jest test). (e) iOS not run.

## 12. Deployment & CI

- Commit `abbc332` (database layer), `607a28d` (hosted scripts), `761af0b` (client) pushed to `main`. CI
  [run 36408260792](https://github.com/carvele/bacalsys/actions/runs/36408260792) on `761af0b`: **green** (typecheck, lint,
  Jest, script tests, database verification, Pages build & deploy).
- Commit `a0662dc` (STATUS, ACCEPTANCE, findings) — CI [run 36431053884](https://github.com/carvele/bacalsys/actions/runs/36431053884): **green**.
- Commit `50add04` (CI-recording follow-up) — CI [run 36431535224](https://github.com/carvele/bacalsys/actions/runs/36431535224): **green**.
- **Round 2:** commit `f87d807` (F-S5-05 fix + its tests, Android smoke evidence, STATUS/ACCEPTANCE/finding) — CI
  [run 36441645436](https://github.com/carvele/bacalsys/actions/runs/36441645436): **green** — *Typecheck, lint, unit +
  database tests* ✅ and *Build & deploy to GitHub Pages* ✅ (both completed).
- Sprint 5 commits since `sprint-04-accepted` (`6731f31`): `abbc332`, `607a28d`, `761af0b`, `a0662dc`, `50add04`,
  `f87d807` (+ the docs-only commit that records this line).

## 13. What was not verified

- **`supabase test db` / local stack**: Docker unavailable — waived (Sprints 1–4).
- **Signed-in UI click-through**: *round 2 covered* Today's training, the player start, the coach roster and
  `AssignWorkoutModal` on Android (§11.1), signed in by the product owner. **Still not exercised on a device:** the Rule C
  `VersionAdoptionPanel`, submitting the Assign modal, logging a set / finishing a workout from the player, and offline
  mode. Web click-through by a signed-in human is likewise not done.
- **Hosted fixture cleanup** not executed (product owner's call); the sprint's hosted fixtures and assignments remain.
- **Mixed online/offline-in-one-session completion** and **process-kill draft recovery**: unchanged Sprint 4 gaps.
- **F-S5-03** (offline workout vs Rule C version drift): implemented as the literal frozen contract; the fallback
  option awaits a Planner decision.
- **iOS**: not run (no device/simulator in this environment).
