# F-S3-01 — Sealed-version immutability triggers must be SECURITY DEFINER

- **Class:** Bug (implementation would not satisfy the frozen requirement as literally transcribed).
- **Severity:** High (would silently defeat the structural immutability guarantee for any DML-privileged, non-RLS-exempt role).
- **Found during:** Task 3.3 (dual-ancestry immutability triggers), before any hosted apply.

## Symptom

The Section 10 listing (Roadmap v1.2 implementation plan) writes the descendant
immutability trigger functions (`check_version_unsealed_for_block/_item/_set`)
as plain `SECURITY DEFINER SET search_path = ''` functions, but does not call
out that they read `public.workout_versions` (and, for items/sets, join back
through `workout_blocks`/`workout_items`) to resolve `is_sealed`. If any of
these functions ran as `SECURITY INVOKER` instead — an easy typo, since most
helper functions elsewhere in the codebase mix both styles — the read would be
subject to the *calling role's* RLS policies on `workout_versions`. A
privileged test/service role that holds table DML but is not exempted from RLS
(e.g. it is not `BYPASSRLS` and not the table owner) would then see zero rows
for that lookup, `v_old_sealed`/`v_new_sealed` would stay `NULL`, every `IF
... = true` guard would evaluate to `NULL` (never `TRUE`), and the trigger
would silently allow the mutation it exists to block.

## Root cause

Immutability triggers that must reason about a *different* table's protected
state need `SECURITY DEFINER` to guarantee they see that state regardless of
the caller's row-level visibility. Writing them without it is a class of bug
that only surfaces under an unusual role (a privileged tester, a future
service role), so it would not be caught by normal `authenticated`-role
testing.

## Fix

All four trigger functions in
[20260926120431_workout_version_immutability.sql](../../../../supabase/migrations/20260926120431_workout_version_immutability.sql)
are declared `SECURITY DEFINER SET search_path = ''` with `EXECUTE` revoked
from `PUBLIC, anon, authenticated` (they are never called directly — only by
the trigger mechanism). This matches the pattern already used by every other
cross-table check in the codebase (`app_private.current_coach_can_view`,
`app_private.has_permission`, etc.).

## Regression coverage

`supabase/tests/009_workout_builder_schema.test.sql` §6–8 run every mutation
attempt against a sealed version — and the sealing-transition loophole probes
— under **`postgres`**, the pgTAP test role, which holds table DML directly
(no RLS bypass is granted to it beyond ordinary superuser status locally, so
the assertion exercises the same code path a hosted service-role probe would).
Every attempt hard-fails with `22000`, proving the trigger's visibility into
`workout_versions.is_sealed` does not depend on the caller's own RLS grant.

## Classification note

No ADR was needed: this is a correction to how the frozen Task 3.3
requirement is implemented, not a change to its behavior, scope, or the
sealed-version security model.
