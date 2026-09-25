---
name: verification-gate
description: Prove a BaCalSys change satisfies acceptance criteria with tests, builds, migration replay, RLS checks, and explicit evidence before completion.
---

# BaCalSys Verification Gate

Use before declaring any implementation ticket complete.

Verification is mandatory. Never infer success from code appearance.

## 1. Map acceptance criteria to evidence

For every acceptance criterion, identify one or more:
- automated test
- database/RLS test
- build/typecheck
- deterministic manual reproduction

No criterion should remain "probably works."

## 2. Determine affected checks

Inspect repository scripts first. Use the project's actual commands.

Potential checks:
- formatting
- lint
- TypeScript
- unit tests
- component/integration tests
- migration replay / local DB reset
- generated DB types
- pgTAP/RLS
- web build
- native development runtime
- offline/restart behavior
- security negative tests

## 3. Security negative testing

For permission-sensitive changes, test both success and denial.

Examples:
- athlete own row succeeds
- athlete cross-user row denied
- former coach outside window denied
- current coach allowed
- Leader blocked from private feedback
- anonymous blocked
- public RPC blocks invalid caller

## 4. Inspect diff

Check:
- no secrets
- no service-role client usage
- no disabled RLS
- no debug bypasses
- no accidental generated files
- no hidden scope expansion
- no TODO replacing an acceptance criterion

## 5. Report

Return a verification table:

- check
- command/test performed
- result
- failure details if any

Then state:
- acceptance criteria proven
- unverified criteria
- blockers

Never say complete if a required verification failed or was not performed.
