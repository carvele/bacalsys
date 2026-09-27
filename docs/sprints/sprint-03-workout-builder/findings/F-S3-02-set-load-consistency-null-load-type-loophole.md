# F-S3-02 — `set_load_consistency` CHECK let a load through with no `load_type`

- **Class:** Bug (implementation would not satisfy the frozen requirement as literally transcribed).
- **Severity:** Medium (a malformed row could pass the table-level CHECK; the
  RPC-level `validate_workout_set` would still catch it on every write made
  through the mutation API, but a future direct-DML path — e.g. a privileged
  migration or an `app_private` internal that forgets the RPC-level check —
  would not).
- **Found during:** Task 3.2 (workout hierarchy DDL), before any hosted apply.

## Symptom

The Section 10 listing writes:

```sql
CONSTRAINT set_load_consistency CHECK (
  (target_load_kg IS NOT NULL AND target_load_kg > 0 AND load_type IN ('added', 'assisted')) OR
  (target_load_kg IS NULL AND (load_type IS NULL OR load_type = 'bodyweight'))
)
```

In PostgreSQL, `load_type IN ('added', 'assisted')` evaluates to `NULL`
(neither `TRUE` nor `FALSE`) when `load_type IS NULL`, and a `CHECK` passes
whenever its expression is `TRUE` **or `NULL`**. So a row with
`target_load_kg = 10, load_type = NULL` makes the first branch `NULL AND ...`
→ `NULL`, the whole `OR` evaluates to `NULL`, and the constraint is satisfied
— a positive load with no load type slips through the table constraint
undetected.

## Root cause

Classic three-valued-logic gap: an `IN` (or `=`) comparison against a nullable
column inside a `CHECK` needs an explicit `IS NOT NULL` to turn the "unknown"
case into a hard failure.

## Fix

[20260926120426_workout_hierarchy_schema.sql](../../../../supabase/migrations/20260926120426_workout_hierarchy_schema.sql)
adds the explicit null check:

```sql
CONSTRAINT set_load_consistency CHECK (
  (target_load_kg IS NOT NULL AND target_load_kg > 0 AND load_type IS NOT NULL AND load_type IN ('added', 'assisted')) OR
  (target_load_kg IS NULL AND (load_type IS NULL OR load_type = 'bodyweight'))
)
```

## Regression coverage

`supabase/tests/009_workout_builder_schema.test.sql` §5 ("items/sets: … load
needs a positive value and a type …") asserts
`INSERT INTO workout_item_sets (..., target_load_kg) VALUES (..., 10)` (load
present, `load_type` omitted/NULL) fails with `23514`. A mutation-testing pass
over this migration (toggling the fix back off) confirmed the assertion fails
without the `IS NOT NULL` guard and passes with it.

## Classification note

No ADR was needed: this is a correction to how the frozen Task 3.2 requirement
is implemented, not a change to its behavior or the load-modeling rules
themselves (`app_private.validate_workout_set`, which every mutation RPC calls
before any row is written, already enforced the equivalent rule correctly).
