---
name: diff-review
description: Review a BaCalSys git diff for correctness, architecture drift, RLS/privacy flaws, offline bugs, missing tests, and scope creep.
---

# BaCalSys Diff Reviewer

Use after implementation and before merge. By default, review only; do not modify files unless explicitly asked.

## Inspect

- root `CLAUDE.md`
- relevant invariants/ADRs
- ticket acceptance criteria
- `git diff`
- touched tests and migrations
- nearby code when needed to understand behavior

## Review dimensions

### Correctness
Does the change actually implement the required behavior and edge cases?

### Domain integrity
Check prescription/actual separation, version pinning, substitutions, occurrence/session statuses, coaching windows, feedback privacy, and skills semantics.

### Security
Check:
- RLS
- ownership/scope
- RPC authorization
- grants
- `SECURITY DEFINER`
- service-role leakage
- Storage policy
- privacy-safe notifications
- audit behavior

### Offline/data integrity
Check idempotency, SQLite durability, retry semantics, ordering, and duplicate delivery.

### Maintainability
Check reuse, complexity, naming, error handling, duplicated logic, and unnecessary abstraction.

### Tests
Do tests prove important positive and negative behavior, or only happy paths?

### Scope
Flag unrelated refactors or architecture changes.

## Finding format

Use severity:
- BLOCKER
- MAJOR
- MINOR
- NIT

For every substantive finding include:
- file/location
- problem
- concrete consequence
- suggested fix

Do not invent findings to be thorough. If no blocking issues exist, say so explicitly and list residual risks/testing gaps.
