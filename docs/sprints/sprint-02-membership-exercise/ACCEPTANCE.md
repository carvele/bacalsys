# Sprint 2: Final Acceptance

> **Status: ACCEPTED on 2026-09-26.** Reviewer approval was relayed by the product owner. The product owner performed
> the signed-in UI click-through on the deployed build (commit `63d1aee`); all steps passed. Items marked ⚠️ are
> explicit waivers, listed below.

An item is checked only with the evidence beside it. Detail is in [STATUS.md](STATUS.md).

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Tasks 2.0–2.13 implemented in dependency order; D1–D4 unmodified | ✅ | STATUS §1, §4 |
| 2 | No `workout_sessions`, `session_feedback`, `session_private_feedback` or workout-assignment tables | ✅ | STATUS §2; only `workout:assign` and `can_assign_training_to()` exist |
| 3 | Public wrapper → `app_private` internals; Supabase-generated migration names | ✅ | STATUS §2–3; seven migrations, forward-only |
| 4 | Fail closed for inactive and suspended members; no cascade delete of coaching history; RLS and privileges not weakened | ✅ | pgTAP 007 and 008; hosted probe (STATUS §9) |
| 5 | pgTAP negative tests | ✅ | 007 (82) and 008 (67) |
| 6 | Full regression `npm run verify` | ✅ | Typecheck, lint, Jest 39/39, script tests 9/9, offline pgTAP **304/304** |
| 7 | Hosted pgTAP | ✅ | **304/304** on `bacalsys-dev` (STATUS §5) |
| 8 | Hosted Acceptance Slice 1 | ✅ | **31/31**, plus helper boundary checks on real rows (STATUS §6) |
| 9 | Hosted Acceptance Slice 2 | ✅ | **33/33** (STATUS §7) |
| 10 | Sprint 1 regression `e2e:skeleton:hosted` | ✅ | **24/24**, re-run after Task 2.14 |
| 11 | Supabase advisors | ✅ | No new findings (STATUS §8) |
| 12 | ADR-003 (F-S2-03, High) resolved | ✅ | ADR-003 **Accepted — Implemented**; Task 2.14 migration `20260926072909`; before/after hosted probe (STATUS §9) |
| 13 | CI and deploy for the delivered commit | ✅ | [Run 36228148451](https://github.com/carvele/bacalsys/actions/runs/36228148451): verify and deploy both succeeded on commit `63d1aee`; live site returns 200 |
| 14 | Signed-in UI click-through (Tasks 2.6, 2.9, 2.10) | ✅ | Performed by the product owner on the live build. **All passed:** assign and change coach, Coach "My athletes", exercise create and submit, reviewer approve, approved-visible-to-all, and the rejection path. Per-step notes were not recorded. |
| 15 | Android dev-client boot | ⚠️ Waived | No native dependency was added in Sprint 2; last verified at the Sprint 1 gate (W-01 still covers iOS) |
| 16 | Local-stack runs (`supabase test db`, `npm run e2e:skeleton`) | ⚠️ Waived | Docker is unavailable (no WSL). The offline PGlite harness and hosted pgTAP cover the same suites. |
| 17 | Concurrent test of the `assign_primary_coach` row lock | ⚠️ Waived | Not exercised. The unique index enforces the single-active invariant (007 #58). |
| 18 | Hosted fixture cleanup executed | ⚠️ Not run, by choice | Guarded script verified by a rolled-back dry run. 24 tagged accounts remain on hosted. Execute at the product owner's discretion. |
| 19 | Tag Sprint 2 as ACCEPTED | ✅ | Git tag `sprint-02-accepted` |

## Notes

- The click-through steps were the five in STATUS §12, plus the rejection path.
- The Planner's open questions in [findings/refinements.md](findings/refinements.md) (former-coach visibility after the
  Coach position ends, exercise self-approval, the member directory for Coaches, target eligibility) are backlog items,
  not gate blockers.
