---
name: sprint-handoff
description: Produce a precise BaCalSys end-of-ticket or end-of-sprint handoff covering shipped behavior, migrations, tests, risks, ADRs, and next work.
---

# BaCalSys Sprint Handoff

Use when closing a ticket, milestone, or sprint.

## Gather evidence

Inspect:
- ticket acceptance criteria
- git diff / changed files
- migrations
- test output
- ADRs created/accepted
- known failures or deferred work

## Handoff format

### Delivered
Map completed behavior to acceptance criteria.

### Technical changes
Summarize:
- frontend
- database
- RPC/RLS
- offline
- tests
- deployment/config

### Migrations
List new migration files and important schema/data effects.

### Verification
List commands/tests actually run and results.

### Security/privacy review
Mention relevant role boundaries, RLS, secrets, sensitive data, audit, and negative tests.

### Known limitations
Only real limitations; do not hide unfinished work.

### Deferred follow-ups
Separate required follow-ups from optional improvements.

### ADRs
List proposed/accepted ADRs and their status.

### Next recommended ticket
Name the next dependency-correct piece of work.

Do not claim sprint completion if its Definition of Done is not met.
