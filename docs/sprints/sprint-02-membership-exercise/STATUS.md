# Sprint 2: Membership & Exercise Library — engineering status

> **Status: ACCEPTED (2026-09-26).** Reviewer approval was relayed by the product owner, and the signed-in UI
> click-through passed. See [ACCEPTANCE.md](ACCEPTANCE.md). Tag `sprint-02-accepted`.

- **Baseline:** Roadmap v1.2, Section 9 (D1–D4, Acceptance Slices 1–2, Tasks 2.0–2.14).
- **Environment:**
  - Hosted dev project `bacalsys-dev` (`sfptojkkmjggssqzyseo`), PostgreSQL **17.6**.
  - Offline harness: PGlite, PostgreSQL **18.3**.
  - Docker is unavailable, so `supabase test db` and the local stack were **not run** (same as Sprint 1).

## 1. Tasks 2.0–2.14

| Task | Status | Deliverable / evidence |
|---|---|---|
| 2.0 Guarded fixture cleanup | ✅ | `scripts/test/cleanup-fixtures.mjs`, `fixture-cleanup-lib.mjs`, `fixtures.mjs`. See details below. |
| 2.1 `coach_assignments` schema | ✅ | Migration `20260926051838_coach_assignments`: 4 RESTRICT FKs, `coach_not_self`, `valid_assignment_window`, `one_active_primary_coach_per_athlete`, RLS, audit trigger, `app_private.is_active_member()` |
| 2.2 `coaches:assign` + assign RPC | ✅ | Migrations `…051843_sprint2_permission_matrix` and `…051848_assign_primary_coach`. The wrapper is `public.assign_primary_coach()` → `app_private.assign_primary_coach_internal()`, covering spec steps 1–10. |
| 2.3 Scope helpers | ✅ | Migration `…051853_coaching_scope_helpers`: `current_coach_can_view`, `former_coach_can_view` (half-open), `can_assign_training_to`. All three are active-member guarded. |
| 2.4 pgTAP coaching suite | ✅ | `supabase/tests/007_coach_assignments.test.sql`, **76** assertions (82 after Task 2.14) |
| 2.5 Hosted Slice 1 | ✅ | §6: **31/31** API checks plus helper checks on real rows |
| 2.6 Coach assignment & My Athletes UI | ✅ built · ⏳ signed-in click-through pending | `src/app/(officer)/coach-assignment.tsx`, `src/app/(coach)/my-athletes.tsx`, `src/features/coaching/coach-roster.ts` (Jest) |
| 2.7 Exercise schema + seeds | ✅ | Migration `…051858_exercise_library`: creator/status CHECKs, both slug indexes, **32** official seeds covering all 6 categories |
| 2.8 Column grants + RLS + workflow RPCs | ✅ | Migration `…051903_exercise_workflow`: `submit_custom_exercise` and `review_custom_exercise`, both wrapper → internal |
| 2.9 Catalog & search UI | ✅ built · ⏳ click-through pending | `src/app/(athlete)/exercises/index.tsx`, `src/features/exercises/exercise-form.ts` (Jest) |
| 2.10 Custom exercise modal + review queue | ✅ built · ⏳ click-through pending | `src/components/CustomExerciseModal.tsx`, `src/app/(officer)/exercise-approvals.tsx` |
| 2.11 pgTAP exercise suite | ✅ | `supabase/tests/008_exercise_library.test.sql`, **67** assertions |
| 2.12 Hosted Slice 2 | ✅ | §7: **33/33** API checks |
| 2.13 Full regression + this report | ✅ | §5 |
| 2.14 ADR-003 resolution (Option A-revised) | ✅ | See below |

**Task 2.14 details:**

- **Migration.** Forward migration `20260926072909_fail_closed_has_permission.sql` (CLI-generated name) replaces two
  functions:
  - `app_private.has_permission`: the position branch joins `profiles` and requires `status = 'active'`. The
    system-role branch is unchanged, and there is **no** top-level `is_active_member()` short-circuit.
  - `public.get_my_access_context`: non-active callers get `positions: []` and no position-derived permissions. Active
    system-role permissions and `is_system_admin` are still reported.
- **Function attributes.** Both functions stay `SECURITY DEFINER SET search_path = ''`, and the REVOKE/GRANT
  statements are restated. Hosted ACL: PUBLIC and anon have no EXECUTE on either function; authenticated has EXECUTE.
- **Migration history.** Accepted migrations 001–007 and the six earlier Sprint 2 migrations are unchanged. Function
  signatures are unchanged, so `src/types/database.ts` is unaffected.
- **Tests.** Regression tests were added to the three suites the plan names:
  - `002_rbac_access_context` gained **12** (16 → 28);
  - `005_walking_skeleton_rls` gained **16** (30 → 46);
  - `007_coach_assignments` gained **6** (76 → 82).
- **Failing first.** With the migration held back, offline pgTAP failed:
  - 002: 6 failures;
  - 007: 4 failures;
  - 005: aborted, because the suspended VP's `approve_member` **succeeded** (F-S2-03 reproduced).

  With the migration in place, all 304 pass.
- **Coverage map:**

  | Requirement | Assertions |
  |---|---|
  | Suspended VP cannot approve members | 005 #33, #38 |
  | Suspended VP cannot create invitations | 005 #34 |
  | Suspended VP cannot list pending members | 005 #32 |
  | Suspended VP has no audit-log access unless an active system role grants it | 002 #16; 005 #35, #42–43 |
  | Suspended Coach loses organization-wide profile permissions | 005 #39–41; 007 #78 |
  | Suspended organizational member gets no position-derived permissions | 002 #15, #17, #20–21, #25; 007 #76–77, #79 |
  | Inactive or suspended user with an active System Administrator role keeps system-role authority | 002 #18–19, #22–24 |
  | Active users keep their existing behavior | 002 #26 (reinstatement); 005 #44–46; 007 #80–81; all pre-existing assertions |
  | Sprint 2 coach and exercise authorization stays green | 007 #1–75 and 008 #1–67, offline and hosted |
- **Hosted evidence:** migration applied (hosted version `20260926073438`); F-S2-03 probe re-run (§9); hosted pgTAP
  304/304; Sprint 1 E2E 24/24; Slices 1 and 2 re-run (§6, §7); advisors re-run (§8).

**Task 2.0 details:**

- Environment check:
  - local stacks always pass;
  - a remote project needs the exact-URL opt-in `FIXTURE_CLEANUP_ALLOWED_URL`, and is refused if its ref is in
    `FIXTURE_CLEANUP_PROTECTED_REFS` or `NODE_ENV=production`.
- Data guard:
  - only accounts carrying **both** tags are candidates: e-mail `@e2e.bacalsys.local` **and** metadata
    `bacalsys_test_fixture=true`, plus the exact Sprint 1 legacy E2E pattern;
  - the batch aborts if a candidate holds VP, President or a system role;
  - batch size is capped;
  - a fixture that any real record depends on is kept;
  - it runs in one transaction and is audited.
- 9 node tests run against a freshly migrated database.
- Hosted run: refusals verified, and a rolled-back dry run. See details below.

## 2. Migrations created (forward-only; 001–007 untouched)

| Local file (CLI-generated name) | Hosted version |
|---|---|
| `20260926051838_coach_assignments.sql` | `20260926052908` |
| `20260926051843_sprint2_permission_matrix.sql` | `20260926052926` |
| `20260926051848_assign_primary_coach.sql` | `20260926052946` |
| `20260926051853_coaching_scope_helpers.sql` | `20260926052955` |
| `20260926051858_exercise_library.sql` | `20260926054116` |
| `20260926051903_exercise_workflow.sql` | `20260926054143` |
| `20260926072909_fail_closed_has_permission.sql` (Task 2.14) | `20260926073438` (recorded as `fail_closed_has_permission`) |

Hosted versions are assigned by `apply_migration`, as in Sprint 1 (refinement R-07). No `workout_sessions`,
`session_feedback`, `session_private_feedback` or workout-assignment tables were created.

## 3. Schema / RPC / RLS changes

**Tables**

- **`public.coach_assignments`**:
  - columns per Section 9 §1, plus a consistency CHECK (`ended_by` only on closed rows);
  - FK and lookup indexes;
  - RLS: `SELECT` only. A row is visible when `is_active_member()` holds **and** the caller is its coach, its athlete,
    or holds `coaches:assign` in the same organization;
  - clients hold **no** INSERT, UPDATE or DELETE grant;
  - audit trigger.
- **`public.exercises`**:
  - columns and constraints per Section 9 §3, plus vocabulary CHECKs (Feature 3.1), a rejection-reason consistency
    CHECK and a slug-default trigger;
  - column grants: `INSERT (content columns + created_by)`, `UPDATE (name, description, measurement_types,
    equipment_needed)`; no DELETE;
  - the five RLS policies from §5, each wrapped in `(SELECT …)` for per-statement evaluation;
  - audit trigger.

**RPCs**

All wrappers are `SECURITY INVOKER` with `search_path = ''`; all internals are `SECURITY DEFINER` with
`search_path = ''`.

| Public wrapper | Internal (`app_private`) | Granted to |
|---|---|---|
| `assign_primary_coach(uuid, uuid, text)` | `assign_primary_coach_internal` | authenticated only |
| `submit_custom_exercise(uuid)` | `submit_custom_exercise_internal` | authenticated only |
| `review_custom_exercise(uuid, text, text)` | `review_custom_exercise_internal` | authenticated only |

**Helpers** (`app_private`, `STABLE SECURITY DEFINER`, granted to authenticated for future RLS):

- `is_active_member()`
- `current_coach_can_view(uuid)`
- `former_coach_can_view(uuid, timestamptz)`
- `can_assign_training_to(uuid)`

**Client**

- `src/types/database.ts` regenerated from hosted.
- Route guards (UX only): `(officer)` opens for any of `members:approve`, `coaches:assign` or `exercises:approve`, and
  every officer screen re-checks its own permission with `<Redirect>`. `(coach)` opens for the Coach position.
- Home screen links, a `Chip` component, and `describeError` overrides.

## 4. D1–D4 permission verification

| Decision | Matrix (pinned by `006_permission_matrix`) | Behavior verified |
|---|---|---|
| **D1** `workout:assign` | Leader, Coach, VP, President. Never Athlete (006 #15). | `can_assign_training_to` (007 #64–75, offline and hosted):<br>• Coach: current athletes only;<br>• former Coach: no;<br>• Leader, VP, President: organization-wide, but not cross-org and not pending members;<br>• Athlete: no;<br>• suspended VP: no.<br>Also checked on real hosted rows (§6). |
| **D2** coach scope | Coach has no `training:view_org` (006 #13) | `current_coach_can_view` / `former_coach_can_view`, including the half-open boundaries (007 #29–52). RLS "My Athletes": A returned, B absent. Suspended coach: all false (007 #61–63). |
| **D3** `coaches:assign` | VP and President only; `members:assign_president` and `permissions:manage` are President only (006 #16–17) | Rejected with 42501 for Athlete, Coach, Leader, anon, suspended VP (wrapper **and** internal) and suspended President (007 #9–15; hosted Slice 1 #3–5). Since Task 2.14, `has_permission('coaches:assign')` is also false for a suspended VP (007 #79). |
| **D4** `exercises:approve` | Coach, VP, President; not Leader or Athlete (006 #18). `exercises:review` renamed (006 #19). | Leader has no queue and gets 42501; suspended Coach has no queue and gets 42501 (wrapper and internal); Coach approves; VP and President reject (008 #35–47, #55; hosted Slice 2 #19–29) |

## 5. Regression results (final run after Task 2.14, 2026-09-26)

| Check | Result |
|---|---|
| `npm run verify` (typecheck, lint, Jest, script tests, offline pgTAP) | ✅ exit 0 |
| TypeScript `tsc --noEmit` | ✅ 0 errors |
| ESLint (`expo lint`, including F-08 rule) | ✅ 0 problems |
| Jest | ✅ **39/39** (5 suites; +12 in `exercise-form` and `coach-roster`) |
| Script tests (`node --test`, Task 2.0) | ✅ **9/9** |
| pgTAP offline (fresh PGlite rebuild, 14 migrations + seed) | ✅ **304/304** (8 files). Before Task 2.14 it was 270/270. |
| pgTAP **hosted** (real pgTAP, rolled back) | ✅ **304/304**: 001 17, 002 28, 003 25, 004 15, 005 46, 006 24, 007 82, 008 67 |
| Sprint 1 regression `npm run e2e:skeleton:hosted` | ✅ **24/24**, re-run after Task 2.14 |
| Sprint 2 hosted Slices, re-run after Task 2.14 | ✅ Slice 1 **31/31**, Slice 2 **33/33** (fixture run `s2r1790408636790`; §6, §7) |
| Web production build (`npm run build:web`) | ✅ export and bundle check pass (backend = hosted URL). Not re-run for Task 2.14, which made no client change. |
| Web smoke test (local serve, signed out) | ✅ `/`, `/coach-assignment`, `/exercises` and `/my-athletes` all redirect to Sign in; 0 console errors. Not re-run for Task 2.14. |
| Android dev-client boot | ⚪ **not run** this sprint. No native dependency was added; last verified at the Sprint 1 gate. |
| iOS | ⚪ waived (W-01, Sprint 1) |

## 6. Hosted Acceptance Slice 1 evidence

Command: `npm run e2e:sprint2:hosted -- slice1`. Fixture run `s2r1790400994456` used tagged fixtures A, B, X and Y. X and
Y were granted the Coach position by an audited operator SQL step (actor `migration`), because no position-assignment
RPC exists yet. **31/31 passed:**

- The President holds `coaches:assign`. Coach X holds the Coach position without it.
- Coach, Athlete and anon calls to `assign_primary_coach` → 42501.
- `rpc/assign_primary_coach_internal` → PGRST202 (not in the Data API). Schema `app_private` → PGRST106 (not exposed).
- President assigns A → X. Exactly one active row, coach X, `assigned_by` = President.
- Coach X "My Athletes": A returned (1 row, with name). B absent (0 rows).
- Same coach → 55000 (no-op). Self-coaching → 22023. Non-coach target → 22023.
- President reassigns A → Y:
  - 2 rows (history preserved);
  - the X row has `ended_at` set and `ended_by` = President;
  - Y is the sole active coach;
  - Y's `started_at` equals X's `ended_at`.
- Former X: "My Athletes" empty, but still sees their own closed row. Y: "My Athletes" = A. A sees their 2 rows. B sees
  0 rows.
- Audit rows: insert (X), update closing X (actor President), insert (Y).
- Direct INSERT, UPDATE and DELETE by the President → 42501. Anon read → 42501.

Helper check on those real rows (SQL, impersonating each user, rolled back; window **4.463 s**):

| Caller | Check | Result |
|---|---|---|
| Former coach X | `current_coach_can_view(A)` | false |
| Former coach X | `former_coach_can_view(A, started_at)` | true |
| Former coach X | `former_coach_can_view(A, ended_at − 1s)` | true |
| Former coach X | `former_coach_can_view(A, ended_at)` | false |
| Former coach X | `former_coach_can_view(A, ended_at + 1h)` | false |
| Former coach X | `can_assign_training_to(A)` | false |
| Current coach Y | `current_coach_can_view(A)` | true |
| Current coach Y | `current_coach_can_view(B)` | false |
| Current coach Y | `former_coach_can_view` over X's period | false |
| Current coach Y | `can_assign_training_to(A)` | true |
| Current coach Y | `can_assign_training_to(B)` | false |
| Athlete A | `can_assign_training_to(B)` | false |

An earlier run (`s2r1790400932224`) passed 31/31 but had a 0.998 s window; see F-S2-02. Hosted pgTAP 007 covers the
same slice in-database: 76/76 before Task 2.14, 82/82 after.

**Re-run after Task 2.14.** Fixture run `s2r1790408636790` used fresh tagged fixtures, with the same audited operator
step granting Coach. **31/31 passed.** The helper check on the new real rows (rolled back; window **4.017 s**) matches
the table above:

| Caller | Check | Result |
|---|---|---|
| Former coach X | `current_coach_can_view(A)` | false |
| Former coach X | `current_coach_can_view(B)` | false |
| Former coach X | `former_coach_can_view(A, …)`: `started_at` / `ended_at − 1s` / `ended_at` / `ended_at + 1h` | true / true / false / false |
| Current coach Y | `current_coach_can_view(A)` | true |
| Current coach Y | `can_assign_training_to(A)` | true |

Active Coach X's access context is unchanged by ADR-003: positions Athlete and Coach; permissions `exercises:approve`,
`members:view_all`, `skills:verify` and `workout:assign`.

## 7. Hosted Acceptance Slice 2 evidence

Command: `npm run e2e:sprint2:hosted -- slice2`, same fixtures. **33/33 passed:**

- **Catalog.** Members see ≥ 32 official seeds. Anon catalog read → 42501.
- **Private draft.** Athlete A creates "Weighted Ring Dips s2r…":
  - status `private`, `is_official` false, slug derived;
  - A sees 1 row; B and Coach X see 0 rows;
  - direct UPDATE of `status` or `is_official` → 42501; INSERT with an approved status → 42501; INSERT in another
    member's name → 42501;
  - the creator can edit the draft; a foreign edit affects 0 rows;
  - reviewing a private exercise (private → approve) → 55000; a non-creator submit → 42501.
- **Submission.**
  - The submit RPC returns `pending_approval`. Later edits affect 0 rows.
  - The approver's queue returns 1 row; an ordinary member still sees 0.
  - Athlete review → 42501. Reject without a reason → 22023. Unknown action → 22023.
- **Approval.**
  - Coach X approves: `approved`, `is_official` true, `reviewed_by` = X, `reviewed_at` set.
  - A, B, Y and the President each see it (1 row).
  - Approved → submit → 55000. Re-review → 55000.
- **Rejection branch.**
  - The President rejects a second exercise with "Form cues unclear"; the RPC returns `rejected` with the reason.
  - The creator sees the reason. An ordinary member sees 0 rows. It leaves the review queue.
- **Audit.** Create, submit and approval (actor Coach X) are recorded.

Suspended-member cases (a suspended creator can't see, edit, submit or create; a suspended Coach has no queue and can't
approve) aren't reachable with an active fixture over the API. They are verified in hosted pgTAP 008 (#39–42, #62–65).

**Re-run after Task 2.14.** Same fixture run `s2r1790408636790`. **33/33 passed.** Approved exercise `52a0a29b…`;
rejected exercise `33666239…`.

## 8. Supabase advisor findings (after all migrations; re-run after Task 2.14)

The re-run after Task 2.14 shows the same set: no new security or performance finding. `unused_index` is now 10 INFO
rather than 14.

- **Security:**
  - `0029 authenticated_security_definer_function_executable` WARN × 4. These are the Sprint 1 `SECURITY DEFINER` RPCs
    (`approve_member`, `create_invitation`, `get_my_access_context`, `list_pending_members`), and they are intentional:
    each authorizes internally. The new Sprint 2 wrappers are `SECURITY INVOKER` and are not flagged.
  - `auth_leaked_password_protection` WARN. Known plan limitation (Sprint 1).
  - **No new security finding from Sprint 2.**
- **Performance:**
  - `multiple_permissive_policies` WARN on `exercises` SELECT. These are the three policies §5 specifies; accepted
    per spec, see refinement R-08.
  - `unused_index` INFO × 14, which is expected on a low-traffic dev project.
  - No unindexed foreign keys.

## 9. Security / privacy findings

- **F-S2-03 (High): RESOLVED by Task 2.14** (ADR-003 Option A-revised, Accepted and Implemented).
  - **Symptom.** The Sprint 1 surfaces didn't fail closed for suspended members. The original probe found that a
    suspended VP could list and approve members, create invitations and read 167 audit rows, and a suspended Coach
    could read 23 profiles.
  - **Root cause.** The verbatim `has_permission()` ignored `profiles.status`.
  - **Probe re-run.** The same probe ran on hosted before and after the migration, each run self-contained and
    rolled back. Fresh fixtures:
    - a suspended VP;
    - a suspended Coach;
    - a suspended Coach who also holds an active System Administrator role;
    - a pending applicant.

    After the run, no probe users or invitations remained.

    | Probe | Before migration | After migration |
    |---|---|---|
    | Suspended VP `list_pending_members()` | **succeeded** | rejected **42501** |
    | Suspended VP `approve_member()` | **succeeded**; applicant became `active` | rejected **42501**; applicant stays `pending_approval` |
    | Suspended VP `create_invitation()` | **succeeded** | rejected **42501** |
    | Suspended VP `audit_logs` rows | **171** | **0** |
    | Suspended VP profiles visible | **25** | **1** (self) |
    | Suspended VP `get_my_access_context()` | VP + 11 permissions | positions `[]`, permissions `[]`, not admin |
    | Suspended VP `assign_primary_coach()` (Sprint 2) | 42501 | 42501 |
    | Suspended Coach profiles visible | **25** | **1** (self) |
    | Suspended Coach access context | Coach + 4 permissions | `[]` / `[]` / not admin |
    | Suspended Coach exercises visible | 0 | 0 |
    | Suspended Coach + active System Administrator: `system_roles:view`, `audit:view` | true, true | **true, true** (break-glass kept) |
    | Suspended Coach + active System Administrator: `skills:verify` (position) / `members:approve` | true / false | **false** / false |
    | Suspended Coach + active System Administrator: audit rows | 171 | 168 (system-role `audit:view`) |
    | Suspended Coach + active System Administrator: profiles visible | 25 | 1 |
    | Suspended Coach + active System Administrator: access context | Coach + 8 permissions, admin | positions `[]`, 4 system permissions, `is_system_admin: true` |

    The before and after audit counts differ by 3: the pre-fix run's own approval and invitation were audited inside
    its rolled-back transaction.
  - Every Sprint 2 surface already failed closed through `is_active_member()`, and still does.
- Private implementations aren't reachable through the Data API (PGRST202 and PGRST106 on hosted). `anon` has no
  privilege on any table (001 #13).
- No service-role key or DB password is stored or used by the client or the scripts. Fixture passwords are random,
  kept in a local state file under the OS temp directory, and never printed.
- No sensitive or private feedback data exists in Sprint 2. The coach-assignment `notes` field is visible to the
  parties and to `coaches:assign` holders only.

## 10. Bugs discovered and regression tests

| ID | Class | Fix | Regression |
|---|---|---|---|
| F-S2-01 | Bug (test): RESTRICT SQLSTATE is 23503 on PostgreSQL 17 and 23001 on 18 | Version-agnostic assertion | 007 #56–57, both engines |
| F-S2-02 | Bug (test harness): Slice 1 window under 1 s | Hold the assignment 3 s | Hosted helper check (§6) |
| (build) | Nested data-modifying CTEs are not allowed in subqueries (same rule as Sprint 1 F-05) | `pg_temp.affected()` / `insert_id()` helpers in 008 | 008 runs 67/67 on both engines |
| (build) | The generated `Insert` type requires `slug` (NOT NULL, trigger default) | Client sends the same derived slug | Jest `draftToInsert` |

## 11. ADRs and refinements raised

- **ADR-003 (Accepted — Implemented):** fail-closed permissions for inactive members. Option A-revised, reviewer-approved
  and relayed by the product owner; implemented in Task 2.14.
- **Refinements R-01…R-10** and **5 open questions:** see [findings/refinements.md](findings/refinements.md).
  Notably:
  - R-01: `exercises:review` renamed to `exercises:approve`;
  - R-04: `SECURITY INVOKER` wrappers mean the internals are granted to `authenticated`, which departs from the Sprint 1
    convention to follow the Section 9 spec;
  - R-05: fail-closed tightenings beyond the spec.

## 12. Unverified acceptance criteria / remaining gaps

1. **Signed-in UI click-through (Tasks 2.6, 2.9, 2.10): ✅ PASSED**, performed by the product owner on the deployed build (commit `63d1aee`), all steps including the rejection path. Original note: I don't enter passwords or session
   tokens into a page that sends them to a remote host, so the signed-in screens were verified by typecheck, Jest logic
   tests and the signed-out smoke test only. Suggested steps, on the web build after deploy:
   1. As President, open *Assign coaches*. Assign a member who holds the Coach position to an athlete, then change it.
      Expect the success message and "since …".
   2. As that coach, open *My athletes*. Expect the athlete listed.
   3. As an athlete, open *Exercise library* → *New custom exercise* → save → *Submit for review*.
   4. As a Coach, VP or President, open *Review custom exercises* → approve, or reject with a reason.
   5. As the athlete, expect the badge to become *Community*, or the rejection reason.
2. ~~ADR-003 decision~~: **closed.** ADR-003 is Accepted and implemented in Task 2.14 (§1, §9).
3. **Not deployed or committed:** changes are in the working tree only. Pushing to `main` redeploys GitHub Pages.
   The database changes, including Task 2.14, **are** applied to hosted `bacalsys-dev`.
4. **Android dev-client boot:** not re-run this sprint (no native change).
5. **Local-stack runs** (`supabase test db`, `npm run e2e:skeleton`): not run, because Docker is unavailable.
6. **Row-lock concurrency** in `assign_primary_coach` (`FOR UPDATE`): not exercised by a concurrent test. The
   single-active invariant is also enforced by the unique index (007 #58).
7. **Hosted test data.** Counted after the Task 2.14 re-runs:
   - **24** accounts match the cleanup predicate (three Sprint 2 fixture runs plus the Sprint 1 E2E accounts);
   - 6 coach assignments;
   - 4 custom exercises;
   - kept: 3 other accounts and 32 official seeds.

   An earlier rolled-back dry run, made before the Task 2.14 re-runs, would have removed 18 accounts, 4 assignments
   and 2 exercises while keeping the 3 real accounts and the seeds. Re-run the dry run before executing, because the
   counts have grown since.

   The cleanup has **not** been executed; that's the product owner's call, possibly after review. The command is:

   ```bash
   FIXTURE_CLEANUP_ALLOWED_URL=https://sfptojkkmjggssqzyseo.supabase.co npm run fixtures:cleanup -- --target https://sfptojkkmjggssqzyseo.supabase.co --out cleanup.sql
   ```

   Then run `cleanup.sql` in the SQL editor.
