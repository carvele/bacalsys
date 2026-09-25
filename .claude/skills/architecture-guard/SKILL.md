---
name: architecture-guard
description: Check proposed or implemented BaCalSys changes for drift from the frozen roadmap and decide whether an ADR is required.
---

# BaCalSys Architecture Guard

Use before cross-cutting changes, dependency additions, schema redesigns, authorization changes, or whenever implementation pressure suggests changing the frozen baseline.

## Inputs to inspect

- `CLAUDE.md`
- `docs/architecture/BACALSYS-INVARIANTS.md`
- accepted ADRs
- relevant frozen roadmap section
- proposed change or current diff

## Classify the change

### Conforming
Implementation choice fits the frozen baseline.

Proceed normally.

### Backlog refinement
Adds implementation detail without changing product behavior, data ownership, security boundary, architecture, or externally visible semantics.

Proceed and document in the ticket/tests.

### ADR required
Any of the following:
- changes architecture or selected framework
- changes privacy/access semantics
- changes role or coaching visibility
- changes workout historical semantics
- changes prescription-vs-actual separation
- changes offline durability/idempotency model
- introduces a new persistence strategy
- weakens or bypasses RLS
- changes public/private database API boundaries
- creates incompatible schema/history behavior

Do not silently implement an ADR-required change.

## Output

State:
1. classification
2. baseline rule(s) involved
3. exact conflict or compatibility
4. lowest-risk path
5. whether an ADR is required

If ADR is required, use the ADR skill to draft it before implementation.
