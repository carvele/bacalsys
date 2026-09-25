---
name: sprint-executor
description: Execute a BaCalSys sprint ticket from acceptance criteria through implementation and verification without drifting from the frozen roadmap.
---

# BaCalSys Sprint Executor

Use this for implementing a concrete issue, story, feature slice, or Sprint task.

## Before editing

1. Read root `CLAUDE.md`.
2. Read `docs/architecture/BACALSYS-INVARIANTS.md`.
3. Read the user-provided ticket and acceptance criteria.
4. Inspect relevant code, tests, migrations, and recent patterns.
5. Run `git status` and inspect existing uncommitted changes. Do not overwrite unrelated work.
6. Identify:
   - exact acceptance criteria
   - touched layers
   - dependencies
   - security/privacy impact
   - required verification

If the requested work conflicts with the frozen baseline, do not improvise. Use the ADR workflow.

## Implementation discipline

- Work in the smallest coherent vertical slice.
- Prefer existing repository abstractions.
- Do not add dependencies unless necessary.
- Do not rename/restructure unrelated modules.
- Database changes must be migrations.
- Add/update tests alongside behavior, not after the entire feature.
- Preserve backwards/historical semantics required by the roadmap.
- Never weaken RLS to make development easier.
- Never bypass a public-wrapper/private-helper boundary for convenience.

## Completion loop

For each meaningful slice:

1. implement
2. typecheck/lint relevant code
3. run focused tests
4. inspect errors
5. correct the cause, not merely the symptom

Before declaring done, invoke the verification workflow or perform its equivalent.

## Final report

Return:
- acceptance criteria satisfied
- files/migrations changed
- tests/checks actually run and results
- security/privacy implications
- anything intentionally deferred
- any discovered follow-up issue

Never say "done" if acceptance criteria or verification are still failing.
