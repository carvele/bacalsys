# Sprint 3: Workout Builder with Set-Level Prescription — engineering status

> **Status: READY FOR REVIEWER GATE (rework applied).** Planning was approved by the Reviewer ("Sprint 3 planning
> verdict: ACCEPTED — READY FOR CLAUDE EXECUTION"). The first implementation-acceptance submission came back
> **REWORK REQUIRED** (F-S3-03, F-S3-04, below); both are fixed and re-verified. Sprint 3 is **not** tagged
> accepted — that requires the Reviewer's approval, relayed by the product owner.
>
> **Reviewer gate history:**
> 1. Implementation submitted (commit `da8927f`) — deployed, product owner ran the signed-in click-through, all 5
>    steps passed.
> 2. Reviewer verdict: **REWORK REQUIRED** — the payload limits and compound-block cardinality had drifted from the
>    frozen values (F-S3-03, F-S3-04). No architecture, D1–D5, RLS, immutability, grants, or org isolation was to be
>    touched.
> 3. Forward migration `20260927103524_workout_payload_limits_and_compound_block_cardinality` applied; client
>    validation, pgTAP and Jest regressions added; hosted probes and advisors re-run. See §2 and §9.

- **Baseline:** Roadmap v1.2 (`implementation_plan.md`) Section 10 — Sprint 3 Ordered Engineering Backlog, Schemas &
  Acceptance Slices, Decision D5, Tasks 3.0–3.14.
- **Environment:**
  - Hosted dev project `bacalsys-dev` (`sfptojkkmjggssqzyseo`), PostgreSQL **17.6**.
  - Offline harness: PGlite, PostgreSQL **18.3**.
  - Docker is unavailable, so `supabase test db` and the local stack were **not run** (same as Sprints 1–2).

## 1. Tasks 3.0–3.14

| Task | Status | Deliverable / evidence |
|---|---|---|
| 3.0 Migration initialization | ✅ | 8 Supabase-CLI-named migrations, `20260926120420`…`20260926120458` |
| 3.1 D5 permission catalog | ✅ | `…120420_workout_permissions`: `workouts:publish_org` (Coach, VP, President), `workouts:manage_org` (VP, President); `seed.sql` updated with the same mappings |
| 3.2 Workout hierarchy DDL | ✅ | `…120426_workout_hierarchy_schema`: 5 tables, all constraints, indexes, `updated_at` trigger, RLS enabled, explicit grants (SELECT only) |
| 3.3 Immutability triggers | ✅ | `…120431_workout_version_immutability`: sealing transition + 3 dual-ancestry descendant triggers, all `SECURITY DEFINER` (F-S3-01) |
| 3.4 Two-tier read predicates | ✅ | `…120436_workout_read_predicates_rls`: `can_view_workout_template`, `can_view_workout_version` |
| 3.5 Fail-closed RLS | ✅ | Same migration: 5 SELECT policies, all delegate to the predicates above |
| 3.6 `create_workout_template` | ✅ | `…120441_workout_create_rpc`: payload validation helpers, `build_workout_version`, `seal_workout_version`, `can_mutate_workout_template`, wrapper → internal |
| 3.7 `publish_new_workout_version` | ✅ | `…120447_workout_publish_version_rpc`: `FOR UPDATE` parent lock, D5 temporal authority, sequential versioning |
| 3.8 `clone_workout_template` | ✅ | `…120452_workout_clone_rpc`: `FOR SHARE` source lock, exercise-accessibility scan, deep copy, provenance note |
| 3.9 Visibility/metadata/archive RPCs | ✅ | `…120458_workout_visibility_metadata_rpcs`: `set_template_visibility` (full transition matrix), `update_workout_template_metadata`, `set_workout_template_archived` |
| 3.10 pgTAP schema/immutability suite | ✅ | `supabase/tests/009_workout_builder_schema.test.sql`, **62** assertions |
| 3.11 pgTAP mutation/versioning/cloning suite | ✅ | `supabase/tests/010_workout_cloning_and_versioning.test.sql`, **75** assertions |
| 3.12 Hosted Acceptance Slice 1 | ✅ | §6: **12/12** |
| 3.13 Types, hooks, Jest, screens | ✅ | See §4 |
| 3.14 Concurrency probes + hosted Slice 2 + full regression + this report | ✅ | §6–8 |
| Reviewer gate rework (F-S3-03, F-S3-04) | ✅ | `20260927103524_workout_payload_limits_and_compound_block_cardinality`; see §2 and §9 |

## 2. Findings

- **[F-S3-03](findings/F-S3-03-payload-limits-drifted-from-frozen-values.md)** (Bug, High — Reviewer implementation-
  acceptance gate) — `app_private.build_workout_version` enforced 30 items/block, 50 sets/item and 500 total sets
  instead of the frozen 15/30/150. Fixed with `CREATE OR REPLACE FUNCTION` in a forward migration (the original
  migration files are not edited — they are already applied to `bacalsys-dev`). Client validation
  (`workout-builder.ts`) and both pgTAP and Jest regressions updated to match exactly.
- **[F-S3-04](findings/F-S3-04-compound-block-minimum-cardinality-missing.md)** (Bug, Medium — same gate) — `superset`
  and `circuit` blocks accepted a single item; the frozen spec requires at least 2 (a "compound" block of one
  exercise is not a superset or circuit). Fixed in the same migration and function.

- **[F-S3-01](findings/F-S3-01-immutability-triggers-security-invoker-risk.md)** (Bug, High) — the Section 10 listing's
  immutability trigger functions needed `SECURITY DEFINER` to see `workout_versions.is_sealed` regardless of the
  caller's own RLS grant; written as `SECURITY INVOKER` they would silently disable immutability for a DML-privileged,
  non-RLS-exempt role. Fixed before any hosted apply; regression coverage in `009` §6–8 (run under the pgTAP test
  role, which holds table DML like a privileged tester would).
- **[F-S3-02](findings/F-S3-02-set-load-consistency-null-load-type-loophole.md)** (Bug, Medium) — the Section 10
  `set_load_consistency` CHECK let a positive load through with `load_type IS NULL` (three-valued-logic gap: `IN`
  against NULL is `NULL`, and `CHECK` passes on `NULL`). Fixed with an explicit `IS NOT NULL`; regression coverage in
  `009` §5. `app_private.validate_workout_set` already caught this correctly for every RPC-driven write, so no runtime
  data was ever at risk — this closes a table-level backstop gap only.

All four findings are implementation corrections to how the frozen Section 10 requirements are realized, not
behavior or scope changes; no ADR was needed for any of them.

## 3. Offline verification

`npm run verify` (typecheck + lint + Jest + `test:scripts` + `db:verify`), after the F-S3-03/F-S3-04 fix:

```
Typecheck:  0 errors
Lint:       0 errors, 0 warnings
Jest:       6 suites, 70 tests passed (workout-builder.test.ts: 31, incl. 10 for F-S3-03/F-S3-04)
db:verify:  10 files, 443 assertions, 0 failed
```

`db:verify` file breakdown: `001`–`008` (Sprints 1–2, unchanged, 304 total) + `009_workout_builder_schema` (62) +
`010_workout_cloning_and_versioning` (77, incl. 2 new F-S3-03/F-S3-04 assertion groups) = 443.

A mutation check (temporarily reverting the corrected limits in the new migration) confirmed the new pgTAP
assertion (`010` #10) fails without the fix and passes with it — the regression is real, not a tautology.

`npm run build:web` succeeds (930 modules, 1.6MB bundle) against the hosted backend
(`https://sfptojkkmjggssqzyseo.supabase.co`); the deployed build was smoke-checked locally (`serve:web`) and lands on
the login screen as expected. No signed-in click-through was performed — that step goes to the product owner per the
Executor's standing rule against entering credentials into pages that talk to hosted Supabase.

## 4. TypeScript, hooks & UI (Task 3.13)

- `src/types/database.ts` regenerated from hosted (all 5 hierarchy tables, 6 new/changed RPC signatures).
- `src/features/workouts/workout-builder.ts` — pure logic: draft types for blocks/items/sets, `validateSet` (mirrors
  `app_private.validate_workout_set` mode-by-mode), `validateDraft`, `buildBlocksPayload` (array order → derived
  `order_in_workout`/`order_in_block`/`set_number`), `addPyramidSets`/`addBackOffSet` helpers, `summarizeSet` for
  display, and (post reviewer-rework) the frozen `MAX_BLOCKS`/`MAX_ITEMS_PER_BLOCK`/`MAX_SETS_PER_ITEM`/
  `MAX_TOTAL_SETS` constants plus compound-block (superset/circuit) minimum-cardinality validation. **31 Jest
  tests** in `__tests__/workout-builder.test.ts`.
- `src/components/WorkoutBlocksEditor.tsx` — the interactive hierarchical builder (block → item → set repeaters,
  pyramid/back-off helper buttons, an exercise picker modal that offers only approved exercises for an
  organization-visible routine).
- Screens under `src/app/(athlete)/workouts/`:
  - `index.tsx` — routine catalog, "My routines" / "Club templates" tabs.
  - `builder.tsx` — create a routine (`create_workout_template`).
  - `[id].tsx` — routine detail: full prescribed hierarchy of the latest version, version history, and (when the
    caller can mutate) edit metadata, publish a new version, toggle visibility, archive/unarchive; clone is offered
    to everyone who can view the routine.
  - `version.tsx` — publish a new version (`publish_new_workout_version`), the Rule C changelog-note modal.
  - `(athlete)/_layout.tsx` and the home screen updated with the new routes.
- Typed routes regenerated (`npx expo customize tsconfig.json`, the documented workaround since routes only
  regenerate via `expo start` otherwise).

## 5. Hosted Acceptance Slice 1 — Hierarchical Creation & Measurement Modes

Re-run against fresh fixtures after the F-S3-03/F-S3-04 fix:
`node --env-file=.env.hosted.local scripts/e2e/sprint3-slices.mjs slice1` — **12/12**:

1. Coach creates the canonical routine (superset of Pull-up/Parallel Bar Dip pyramid + back-off sets, AMRAP Hanging
   Leg Raise finisher — 2 items in its superset block, well within the corrected 15-item limit) through
   `create_workout_template`.
2–6. `workout_templates` (1, organization), `workout_versions` (1, sealed, v1), `workout_blocks` (2),
   `workout_items` (3), `workout_item_sets` (7) — exact Slice 1 shape.
7–11. Direct authenticated `INSERT`/`UPDATE`/`DELETE` against every one of the 5 hierarchy tables: **42501**.
12. An unsupported measurement mode for the exercise (`push-up` + `holds`) is rejected with **22023**.

## 5a. Hosted F-S3-03 / F-S3-04 Live Limit Probes

`node --env-file=.env.hosted.local scripts/e2e/sprint3-slices.mjs limits` — **6/6** (real RPC calls against
`bacalsys-dev`, not pgTAP):

1. 16 items in a block → **22023**.
2. Exactly 15 items in a block → accepted.
3. 31 sets on one item → **22023**.
4. A 1-item `superset` → **22023**.
5. A 1-item `circuit` → **22023**.
6. A 2-item `superset` → accepted.

## 6. Hosted Acceptance Slice 2 — Version Immutability, Historical Safety & Deep Cloning

Re-run against fresh fixtures after the F-S3-03/F-S3-04 fix:
`node --env-file=.env.hosted.local scripts/e2e/sprint3-slices.mjs slice2` — **14/14**, all 9 scenario steps from the
spec:

1. Athlete creates a private routine with an athlete-private exercise (V1, unsafe).
2. Assigned Coach: **0 rows**.
3. Athlete publishes V2 with approved exercises.
4. Coach: sees the template; only **V2** is visible (V1 stays hidden).
5. Coach clones while V2 is latest → the clone's version notes confirm it copied **version 2**.
6. Athlete publishes V3, unsafe again.
7. Coach: **0 rows** (V3 unsafe hides the whole template, even the safe V2); clone attempt → **42501**.
8. Creator: sees all **3** versions (creator shortcut).
9. A Coach in Organization B: **0 rows**; clone attempt → **42501**.

## 7. Concurrency Verification Probes

Re-run after the F-S3-03/F-S3-04 fix:
`node --env-file=.env.hosted.local scripts/e2e/sprint3-slices.mjs concurrency` — **6/6**:

1. **Concurrent publishes** — two `publish_new_workout_version` calls fired with `Promise.all` on the same template:
   both succeed, produce sequential versions (`2`, `3`), no unique-constraint conflict (parent row `FOR UPDATE` lock
   serializes them).
2. **Publish racing clone** — a publish and a `clone_workout_template` fired concurrently: both complete without
   error; the clone recorded a complete, sealed source-version reference and a full hierarchy (never a partial or
   zero-row copy), regardless of which side's row lock (`FOR UPDATE` / `FOR SHARE`) was granted first.

## 8. Hosted advisors

`get_advisors` (security, performance), re-run after the F-S3-03/F-S3-04 migration: no new findings from Sprint 3 or
from the rework. The four pre-existing `authenticated_security_definer_function_executable` warnings are Sprint 1/2
RPCs (intentional, by design — every one is an authenticated public wrapper); the `unused_index` INFO items are
expected pre-traffic noise on newly created indexes and are not acted on (the count dropped from 19 to 15 as the
hosted probe traffic exercised some of them).

## 9. Deployment & signed-in click-through

- Commit [`da8927f`](https://github.com/carvele/bacalsys/commit/da8927f) pushed to `main` (first submission).
- CI [run 36311916865](https://github.com/carvele/bacalsys/actions/runs/36311916865): **green** — typecheck, lint,
  Jest, `test:scripts`, `db:verify`, then build & deploy to GitHub Pages.
- Signed-in UI click-through performed by the product owner against the deployed build. Reported result: **all
  steps passed** —
  1. Coach creates a routine (block/exercise/set builder), saves it private or club-visible.
  2. Coach publishes a new version of that routine with a changelog note.
  3. A member with access clones a routine into their own private library.
  4. Creator/VP/President toggles a private routine to club-visible and back, edits its name/description,
     archives/unarchives it.
  5. Athlete browses "My routines" vs "Club templates" and opens a routine's detail to see the full prescribed
     block/exercise/set breakdown.

## 10. What was not verified

- **`supabase test db` / local Docker stack**: unavailable in this environment (same waiver as Sprints 1–2).
- **Signed-in UI click-through**: not performed by the Executor (credential-entry rule); pending the product owner.
- **Android dev-client boot**: not performed this sprint; no native module was added.
- **Row-lock concurrency under true simultaneous transactions** (two separate Postgres sessions blocking on the same
  lock): the hosted probes fire two RPC calls concurrently over separate PostgREST connections and assert the
  *outcome* (sequential versions, no partial copies), which is what the spec requires proven; they do not instrument
  the lock wait itself. This is the same evidentiary standard Sprint 2's `assign_primary_coach` concurrency guarantee
  was accepted under.
