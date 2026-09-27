# Sprint 3: Final Acceptance

> **Status: ACCEPTED on 2026-09-27.** Reviewer approval was relayed by the product owner. The Reviewer independently
> verified the remediation in the repository, CI, and the live hosted database and returned "ACCEPTED — READY TO
> CLOSE." Items marked ⚠️ are explicit waivers, listed below.

An item is checked only with the evidence beside it. Detail is in [STATUS.md](STATUS.md).

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Tasks 3.0–3.14 implemented in dependency order; D1–D5 unmodified | ✅ | STATUS §1 |
| 2 | Hierarchical schema (templates → versions → blocks → items → sets); no session/feedback/assignment tables | ✅ | STATUS §1; migration `…120426_workout_hierarchy_schema` |
| 3 | Public wrapper → `app_private` internals; Supabase-generated migration names; forward-only | ✅ | STATUS §1; 9 migrations total (8 initial + 1 forward remediation) |
| 4 | Sealed-version structural immutability (dual-ancestry triggers); RLS/grants not weakened | ✅ | pgTAP 009 §6–8; F-S3-01 |
| 5 | Two-tier fail-closed RLS (`can_view_workout_template` / `can_view_workout_version`); null-safe org scope | ✅ | pgTAP 009/010; hosted Slice 1/2 |
| 6 | D5 authority matrix (`workouts:publish_org`, `workouts:manage_org`); private-creator retention across orgs | ✅ | pgTAP 010 §5–7 |
| 7 | pgTAP negative and structural tests | ✅ | 009 (62) and 010 (77, incl. F-S3-03/F-S3-04 regressions) |
| 8 | Full regression `npm run verify` | ✅ | Typecheck, lint, Jest **70/70**, script tests, offline pgTAP **443/443** |
| 9 | Hosted pgTAP-equivalent state | ✅ | Migrations applied and re-verified on `bacalsys-dev` (STATUS §5, §5a, §9) |
| 10 | Hosted Acceptance Slice 1 | ✅ | **12/12** (STATUS §5), re-run post-remediation |
| 11 | Hosted Acceptance Slice 2 | ✅ | **14/14**, all 9 spec steps (STATUS §6), re-run post-remediation |
| 12 | Concurrency verification probes | ✅ | **6/6** (STATUS §7), re-run post-remediation |
| 13 | Supabase advisors | ✅ | No new findings from Sprint 3 or the rework (STATUS §8) |
| 14 | F-S3-01 (immutability triggers needed `SECURITY DEFINER`) resolved | ✅ | Fixed pre-hosted-apply; pgTAP 009 §6–8 |
| 15 | F-S3-02 (`set_load_consistency` NULL-vs-CHECK gap) resolved | ✅ | Fixed pre-hosted-apply; pgTAP 009 §5 |
| 16 | F-S3-03 (payload limits drifted: 15 items/block, 30 sets/item, 150 total sets) resolved | ✅ | Forward migration `20260927103524`; pgTAP 010, Jest, hosted `limits` probe **6/6** |
| 17 | F-S3-04 (superset/circuit needed ≥2 items) resolved | ✅ | Same migration; pgTAP 010, Jest, hosted `limits` probe |
| 18 | CI and deploy for the delivered commit | ✅ | [Run 36311916865](https://github.com/carvele/bacalsys/actions/runs/36311916865) (initial, `da8927f`) and [run 36314719808](https://github.com/carvele/bacalsys/actions/runs/36314719808) (remediation, `c5a4eb8`) both green |
| 19 | Signed-in UI click-through | ✅ | Performed by the product owner on the initial deployed build (`da8927f`). **All 5 steps passed**: create a routine, publish a new version, clone, visibility/metadata/archive, catalog browsing |
| 20 | Android dev-client boot | ⚠️ Waived | No native dependency was added in Sprint 3 |
| 21 | Local-stack runs (`supabase test db`) | ⚠️ Waived | Docker is unavailable (no WSL); the offline PGlite harness and hosted probes cover the same ground |
| 22 | Second signed-in click-through for the F-S3-03/F-S3-04 remediation | ⚠️ Waived, by Reviewer agreement | Server-side/validation-only correction on the same screens; not a Sprint 3 acceptance blocker per the Reviewer's explicit retained waiver |
| 23 | Row-lock concurrency under true simultaneous transactions | ⚠️ Waived | Hosted probes assert outcome (sequential versions, no partial copies) over concurrent RPC calls, not the lock wait itself — same evidentiary standard as Sprint 2 |
| 24 | Tag Sprint 3 as ACCEPTED | ✅ | Git tag `sprint-03-accepted` |

## Notes

- Reviewer gate history (planning → implementation → rework → close) is recorded in [STATUS.md](STATUS.md) header.
- Findings [F-S3-01](findings/F-S3-01-immutability-triggers-security-invoker-risk.md),
  [F-S3-02](findings/F-S3-02-set-load-consistency-null-load-type-loophole.md),
  [F-S3-03](findings/F-S3-03-payload-limits-drifted-from-frozen-values.md), and
  [F-S3-04](findings/F-S3-04-compound-block-minimum-cardinality-missing.md) were all classified as Bugs (implementation
  corrections to how the frozen Section 10 requirements are realized); none required an ADR.
- Next workflow step, per the Reviewer: Sprint 3 accepted → Antigravity plans Sprint 4 → Reviewer reviews the Sprint 4
  plan → Claude executes only after planning approval. No Sprint 4 implementation begins until that plan clears the
  architecture/reviewer gate.
