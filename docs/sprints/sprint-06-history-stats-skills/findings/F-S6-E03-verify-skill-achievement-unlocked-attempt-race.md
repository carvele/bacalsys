# F-S6-E03 — `verify_skill_achievement` read the linked attempt without a row lock

- **Class:** Bug (race condition in the frozen predicate text, closed before any hosted apply).
- **Found by:** the Executor, comparing Section 13's `verify_skill_achievement_internal` listing against
  `review_skill_attempt_internal` in the same section, which does lock the attempt it mutates.

## Symptom (as specified)

The frozen listing reads the linked `skill_attempts` row with a plain `SELECT * INTO v_attempt ... WHERE id =
p_skill_attempt_id` (no `FOR UPDATE`) before deciding whether to flip it from `pending_review` to `approved`. Two
concurrent calls — an officer's `verify_skill_achievement(..., p_skill_attempt_id => X)` racing a coach's
`review_skill_attempt(X, false, ...)` — could interleave: the reject transaction commits `status = 'rejected'`
between the verify transaction's unlocked read and its `UPDATE ... WHERE id = p_skill_attempt_id`, silently
overwriting the rejection back to `approved` with no error and no audit trail of the conflict.

## Fix

`app_private.verify_skill_achievement_internal`
([20260929000007_skills_workflow_rpcs.sql](../../../../supabase/migrations/20260929000007_skills_workflow_rpcs.sql))
selects the linked attempt `FOR UPDATE`, matching `review_skill_attempt_internal`'s own lock. The two mutations
now serialize like any other pair of writers on the same `skill_attempts` row.

## Verification

`supabase/tests/017_skills_and_progressions.test.sql` §10 (assertion #67) asserts, structurally, that the lock is
present (`position('FOR UPDATE' ...)`) — the same convention Sprints 3–5 use for serialization statements a single
pgTAP transaction cannot exercise as genuine concurrency. Mutation-tested: reverting the `FOR UPDATE` clause makes
that assertion fail (verified locally before committing the fix). Real concurrent behavior for the sibling
`review_skill_attempt` race is proven on `bacalsys-dev` by `scripts/e2e/sprint6-slices.mjs concurrency` (Probe 2).
