---
name: adr
description: Draft a BaCalSys Architecture Decision Record when implementation requires a justified deviation or new cross-cutting architectural decision.
---

# BaCalSys ADR

Use when the Architecture Guard classifies a change as ADR-required.

Do not silently change the frozen baseline.

## Process

1. Identify the implementation pressure or conflict.
2. Quote/identify the affected frozen baseline rule.
3. Research current repository behavior.
4. Present realistic alternatives, including "keep baseline."
5. Evaluate:
   - correctness
   - complexity
   - migration
   - security/privacy
   - offline behavior
   - operational burden
   - reversibility
6. Recommend the smallest decision necessary.

## File

Create a new file under `docs/adr/` using `docs/adr/ADR-000-template.md`.

Name it `ADR-NNN-short-slug.md` (three-digit, next sequential number after inspecting the folder; e.g. `ADR-001-expo-router-version-and-route-root.md` exists).

Initial status should be `Proposed` unless the user explicitly accepts the decision.

## Important

Do not implement a proposed baseline-changing decision merely because the ADR has been drafted.

Implementation begins after the ADR is accepted or the user explicitly instructs implementation.
