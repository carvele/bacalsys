# F-S3-04 — Compound blocks (superset, circuit) had no minimum item count

- **Class:** Bug (implementation did not satisfy the frozen requirement).
- **Severity:** Medium.
- **Found during:** Reviewer implementation-acceptance gate, first submission (commit `da8927f`), alongside F-S3-03.

## Symptom

`app_private.build_workout_version` accepted a `superset` or `circuit` block
with a single item. A "superset" or "circuit" of one exercise is not a
compound structure; the frozen spec requires at least 2 items for both block
types. `standard_set` and `amrap` correctly kept their existing 1-item
minimum (unchanged).

## Root cause

The block-type-specific validation (Task 3.6) checked `circuit_rounds` and
`amrap_duration_seconds` consistency but never checked item-count cardinality
against block type.

## Fix

Same migration as F-S3-03
(`20260927103524_workout_payload_limits_and_compound_block_cardinality.sql`):
`app_private.build_workout_version` now rejects `block_type IN ('superset',
'circuit')` with fewer than 2 items, with SQLSTATE `22023`. The existing
`circuit_rounds` (≥1, circuit-only) and AMRAP duration (≥30s, AMRAP-only)
validation is untouched.

`src/features/workouts/workout-builder.ts` mirrors the same rule client-side;
the block-level error message takes priority over the (now redundant) generic
item-count message so a circuit block missing both its round count and a
second item still reports the round-count problem first (existing behavior
preserved).

## Regression coverage

- `supabase/tests/010_workout_cloning_and_versioning.test.sql`: assertions
  proving a 1-item superset and a 1-item circuit are rejected with `22023`,
  and that a 2-item superset/circuit remain accepted.
- `src/features/workouts/__tests__/workout-builder.test.ts`: 4 new tests
  (1-item superset rejected, 1-item circuit rejected, 2-item versions of both
  accepted, and confirming `standard_set`/`amrap` keep no minimum-2 rule).
- Hosted: `scripts/e2e/sprint3-slices.mjs limits` — live RPC calls proving a
  1-item superset is rejected with `22023` and a 2-item superset is accepted.

## Classification note

No ADR was needed: this restores the frozen Section 10 requirement, it does
not change the requirement itself.
