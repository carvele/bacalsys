# F-S4-01 — `session_set_load_consistency` repeated the F-S3-02 NULL-vs-CHECK loophole

- **Class:** Bug (implementation would not satisfy the frozen requirement as literally transcribed).
- **Severity:** Medium (a malformed row could pass the table-level CHECK; the
  RPC-level `validate_session_set` — which every mutation RPC calls before any
  row is written — already enforced the equivalent rule correctly, so no
  hosted row was ever actually affected).
- **Found during:** Task 4.2 (workout execution DDL), before any hosted apply.

## Symptom

The Section 11 listing writes:

```sql
CONSTRAINT session_set_load_consistency CHECK (
  (actual_load_kg IS NOT NULL AND actual_load_kg > 0 AND load_type IN ('added', 'assisted')) OR
  (actual_load_kg IS NULL AND (load_type IS NULL OR load_type = 'bodyweight'))
)
```

This is the exact same three-valued-logic gap Sprint 3's F-S3-02 closed on
`workout_item_sets.set_load_consistency`: `load_type IN ('added', 'assisted')`
evaluates to `NULL` (neither `TRUE` nor `FALSE`) when `load_type IS NULL`, and
a `CHECK` passes whenever its expression is `TRUE` **or `NULL`**. A row with
`actual_load_kg = 10, load_type = NULL` makes the first branch's `AND` chain
evaluate to `NULL`, the whole `OR` evaluates to `NULL`, and the constraint is
satisfied — a positive load with no load type slips through the table
constraint undetected.

## Root cause

The frozen Section 11 text carried the same unguarded `IN` comparison against
a nullable column that F-S3-02 already identified and fixed on the sibling
prescription table; it was not re-derived from the corrected version when
Section 11 was drafted.

## Fix

[20260927130335_workout_execution_schema.sql](../../../../supabase/migrations/20260927130335_workout_execution_schema.sql)
adds the explicit null check, applied identically to F-S3-02's fix, from the
very first hosted apply (never a separate remediation migration):

```sql
CONSTRAINT session_set_load_consistency CHECK (
  (actual_load_kg IS NOT NULL AND actual_load_kg > 0 AND load_type IS NOT NULL AND load_type IN ('added', 'assisted')) OR
  (actual_load_kg IS NULL AND (load_type IS NULL OR load_type = 'bodyweight'))
)
```

The client mirror (`app_private.validate_session_set`, and its TypeScript
counterpart `validateActualSet` in `src/features/workouts/session-player.ts`)
carries the same guard.

## Regression coverage

- `supabase/tests/011_workout_sessions_schema.test.sql` §2: a direct, privileged
  `INSERT INTO session_sets (..., actual_load_kg) VALUES (..., 10.00)` with
  `load_type` omitted (`NULL`) fails with `23514`; a well-typed load only trips
  the (unrelated, expected) `23503` foreign-key check against a real
  `session_exercise_id`, proving the load-consistency branch itself passed.
- `src/features/workouts/__tests__/session-player.test.ts`: "F-S4-01: a nonzero
  load with no load type is rejected client-side too".

## Classification note

No ADR was needed: this is a correction to how the frozen Task 4.2 requirement
is implemented, not a change to its behavior or the load-modeling rules
themselves. It mirrors F-S3-02's classification exactly.
