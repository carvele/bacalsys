# F-S3-03 — Workout payload limits drifted from the frozen values

- **Class:** Bug (implementation did not satisfy the frozen requirement).
- **Severity:** High.
- **Found during:** Reviewer implementation-acceptance gate, first submission (commit `da8927f`).

## Symptom

`app_private.build_workout_version` (the function every mutation RPC —
`create_workout_template` and `publish_new_workout_version` — calls to
validate and insert a routine's blocks/items/sets) enforced:

| Limit | Implemented | Frozen |
|---|---|---|
| Blocks per workout | 1–20 | 1–20 (correct) |
| Items per block | 1–30 | 1–15 |
| Sets per item | 1–50 | 1–30 |
| Sets per workout (total) | ≤500 | ≤150 |

The blocks-per-workout limit was correct; the other three had drifted upward
from the frozen values.

## Root cause

The limits were written from the Executor's own reading of the plan document
during Task 3.6, without an explicit numeric table to check against in the
visible spec text. The Reviewer holds the authoritative frozen numbers.

## Fix

`supabase/migrations/20260927103524_workout_payload_limits_and_compound_block_cardinality.sql`
— a forward migration (the already-applied Sprint 3 migrations are untouched)
that `CREATE OR REPLACE`s `app_private.build_workout_version` with:

- items per block: 1–15
- sets per item: 1–30
- total sets per workout: ≤150

No other function, grant, RLS policy, or trigger changed.

`src/features/workouts/workout-builder.ts` client-side validation
(`validateDraft`) updated to the same numbers via shared constants
(`MAX_BLOCKS`, `MAX_ITEMS_PER_BLOCK`, `MAX_SETS_PER_ITEM`, `MAX_TOTAL_SETS`),
plus a new `totalSets` error surfaced by the builder and publish-version
screens. The server remains authoritative; this is UX only.

## Regression coverage

- `supabase/tests/010_workout_cloning_and_versioning.test.sql`: a new
  `pg_temp.block_with_items` fixture helper and two assertions proving 16
  items/block, 31 sets/item and 151 total sets are rejected with `22023`,
  and that exactly 15/30/150 remain accepted.
- `src/features/workouts/__tests__/workout-builder.test.ts`: 6 new tests for
  the same boundaries against the client mirror.
- Hosted: `scripts/e2e/sprint3-slices.mjs limits` — live RPC calls against
  `bacalsys-dev` proving 16 items/block and 31 sets/item are rejected with
  `22023` and 15 items/block is accepted.
- A mutation check (reverting the fix locally) confirmed the new pgTAP
  assertion fails without the corrected limits and passes with them.

## Classification note

No ADR was needed: this restores the frozen Section 10 requirement, it does
not change the requirement itself.
