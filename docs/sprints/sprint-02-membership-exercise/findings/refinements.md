# Sprint 2: backlog refinements and open questions

These add implementation detail without changing the architecture. Each is listed for the Planner and Reviewer, and
none blocks Sprint 2.

## Refinements implemented

| ID | Refinement | Why |
|---|---|---|
| R-01 | Renamed the Sprint 1 placeholder permission `exercises:review` to **`exercises:approve`** in place, so VP and President keep the grant. | D4 names `exercises:approve`. The placeholder was never referenced by any function or policy (drift guard 006 #23–24). |
| R-02 | Added the D3 President-only permissions `members:assign_president` and `permissions:manage` to the catalog, granted to President only. | This makes D3 verifiable now (006 #17). No RPC uses them yet; their enforcement surfaces arrive with position management. |
| R-03 | The permission catalog lives in a **migration**, and position mappings are repeated idempotently in `seed.sql`. | Hosted projects never run `seed.sql`, while fresh local databases have no positions until the seed runs. Both paths converge (006 golden matrix passes on both). |
| R-04 | Public wrappers are `SECURITY INVOKER` as specified, so each `app_private.*_internal` is **granted to `authenticated`**. Sprint 1 internals were never granted. | This follows Section 9 §2 verbatim. The internals stay unreachable from clients, because `app_private` isn't exposed (hosted: PGRST202 and PGRST106), and each internal re-derives the caller from `auth.uid()` and re-checks active membership and permission. The wrappers also pin `search_path = ''`. |
| R-05 | Stricter than the spec, all fail-closed:<br>• `assign_primary_coach` also requires the **caller** to be in the athlete's organization;<br>• `can_assign_training_to` requires an **active** target;<br>• `coach_assignments` is readable only by the parties or by `coaches:assign` holders in the same organization (not Leaders);<br>• `exercises` INSERT is column-granted;<br>• there is no DELETE on `exercises`;<br>• vocabulary, rejection-reason and review-field CHECKs;<br>• the default slug is derived from the name. | This is defense in depth. Every rule is pinned by pgTAP. |
| R-06 | Test files are named `007_coach_assignments.test.sql` and `008_exercise_library.test.sql`, not `coach_assignments_test.sql` and `exercise_library_test.sql`. | The repository convention (`NNN_name.test.sql`) is what the offline harness and CI pick up. |
| R-07 | Local migration files use CLI-generated timestamps. Hosted `apply_migration` records its own versions (for example `20260926052908`) under the local filename. | This matches how Sprint 1 was applied. The first hosted Sprint 2 migration (`coach_assignments`) was sent without some header comment lines; its DDL is identical, as verified by pgTAP 007 on hosted. |
| R-08 | `exercises` has three permissive SELECT policies, as specified in Section 9 §5. The advisor raises `multiple_permissive_policies` (performance WARN). | This was kept verbatim. Merging them into one equivalent policy would clear the WARN; that's a possible later refinement. |
| R-09 | Task order: 2.7 and 2.8 (the DB layers) were applied before the 2.6 UI, so the client types were generated once. | There's no dependency inversion: 2.6 depends only on 2.1–2.3. |
| R-10 | CI now runs `npm run test:scripts` (the fixture-cleanup suite), and `npm run verify` includes it. | Task 2.0 regression coverage. |

## Open questions for the Planner

1. ~~**ADR-003** (see F-S2-03): make `has_permission()` fail closed for inactive members.~~ **Decided:** Option
   A-revised was accepted, and Task 2.14 implemented it.
2. `current_coach_can_view` checks only the assignment and active membership. Should a coach whose **Coach position has
   ended** keep current-coach visibility until reassigned? The current behavior follows the spec (the assignment
   governs).
3. **Self-approval**: a Coach who creates a custom exercise can approve it themselves, because D4 grants
   `exercises:approve` with no separation-of-duties rule. Should that be forbidden?
4. **D2 member directory**: Coach keeps `members:view_all`, the "basic member identity" needed to name their athletes.
   Training data is scoped by `coach_assignments` only.
5. `assign_primary_coach` requires the target to hold the **Coach** position (spec step 4), and the `(coach)` route group
   is shown by that position. This is target eligibility and UX, not caller authorization, which stays
   permission-based per D3. Confirm this reading.
