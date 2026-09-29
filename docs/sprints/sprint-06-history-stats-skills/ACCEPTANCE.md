# Sprint 6: Acceptance Checklist

> **Status: NOT submitted for review yet.** The Executor never self-approves and never tags a sprint without a
> relayed Reviewer verdict. This checklist is prepared for the Reviewer; item 22 is intentionally unchecked pending
> the interactive Android smoke test (F-S6-E06) — the Reviewer decides, as they did for several Sprint 5 items,
> whether that gap blocks the gate.

An item is checked only with the evidence beside it. Detail is in [STATUS.md](STATUS.md). pgTAP assertion numbers
refer to `016_training_history_and_statistics.test.sql` (49 total) and `017_skills_and_progressions.test.sql`
(75 total).

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Tasks 6.0–6.16 implemented in order; Section 13 realized as frozen | ✅ | STATUS §1–§4 |
| 2 | Skills schema: `skills`, `skill_progressions`, `athlete_skill_status`, `skill_attempts`, `skill_achievements`; composite FK `(skill_id, current_progression_id)` structurally forbids a rung/skill mismatch (F-S6-P06); no free-text notes column anywhere (F-S6-P09) | ✅ | pgTAP 017 #11 (`23503` on mismatch), #7 (column scan) |
| 3 | 6 default ladders / 28 rungs seeded with frozen criteria (F-S6-P07); idempotent — a re-seed never overwrites a coach's edit | ✅ | pgTAP 017 #8–#10, #65 (edit survives re-seed); hosted: 6/28 confirmed post-migration |
| 4 | Permissions: `skills:manage` added, mapped to Coach/VP/President only; `skills:verify` confirmed on the same three; neither on Athlete, Leader or any system role | ✅ | pgTAP 017 #1–#3; golden matrix rows in `006_permission_matrix.test.sql` updated |
| 5 | 11-identity RLS matrix across all 5 skill tables (athlete self, peer, cross-org athlete, current coach, former coach, unassigned coach, leader, VP, President, inactive member, SysAdmin-only) | ✅ | pgTAP 017 #14–#19 |
| 6 | **F-S6-P14**: a System Administrator holding no club position reads **0** rows across all 5 skill tables | ✅ | pgTAP 017 #20–#21 |
| 7 | Tier-2 split: Leaders see **0** rows of `skill_attempts` (review feedback is not a leak channel); athlete, current coach, VP/President do | ✅ | pgTAP 017 #15 |
| 8 | Tier-3 split: verified milestones are club-visible to every same-organization active position holder, including peers and former coaches; cross-org and SysAdmin-only see 0 | ✅ | pgTAP 017 #16 |
| 9 | Tier-1 status mutation authority (F-S6-P04): athlete self, current coach, VP/President succeed; peer, other org, former/unassigned coach, Leader, inactive, SysAdmin-only get `42501` | ✅ | pgTAP 017 #22 |
| 10 | `log_skill_attempt`: objective metrics only, no notes field; validation (no metric, zero, non-http video, future date → `22023`); position-less caller refused | ✅ | pgTAP 017 #26 |
| 11 | Idempotency (F-S6-P05): reservation acquired **before** every domain row lock; same-key replay returns the cached result with no duplicate write or audit row; same-key + different payload fails closed `42501` | ✅ | pgTAP 017 #13, #27–#28, #36–#37, #47, #54, #61, #66 |
| 12 | **F-S6-E02** (self-review guard) and **F-S6-E03** (verify's row lock) — both hardened beyond the literal frozen text, before any hosted apply | ✅ | pgTAP 017 §6 (#41–#43), §10 (#67); findings [F-S6-E02](findings/F-S6-E02-can-verify-skill-permitted-self-verification.md), [F-S6-E03](findings/F-S6-E03-verify-skill-achievement-unlocked-attempt-race.md) |
| 13 | `verify_skill_achievement` lineage (F-S6-P06): an attempt of another athlete/rung → `22000`; a rejected attempt → `22000`; unknown attempt → `P0002`; a supplied pending attempt is closed out (approved + attributed), never left dangling; authorization mirrors `can_verify_skill` (athlete, peer, other org, former/unassigned coach, Leader, inactive, SysAdmin-only all refused) | ✅ | pgTAP 017 #44–#45, #48 |
| 14 | `revoke_skill_achievement`: reason is mandatory, non-blank, ≤1000 chars, checked by both the RPC and the table `CHECK`; every revoke/re-verify emits one immutable audit event, never duplicated on replay | ✅ | pgTAP 017 #49–#57 |
| 15 | `update_skill_progression` (F-S6-P07): `skills:manage` required; cross-organization write refused `42501`; edit is audited with old **and** new values | ✅ | pgTAP 017 §9 (#58–#64) |
| 16 | **F-S6-P13**: `p_idempotency_key` is required with **no default** on all 6 mutating RPCs, including `verify_skill_achievement`; calling it without a key is not even a valid call (`42883`) | ✅ | pgTAP 017 #73–#74 |
| 17 | **F-S6-P15**: 6 skill RPCs + 3 history RPCs are `SECURITY INVOKER`; their 9 delegates + 7 helpers are `SECURITY DEFINER` with `search_path=''`; `anon` denied on every public RPC and every delegate; `authenticated` denied direct DML on all 5 tables even for a Coach/VP/President | ✅ | pgTAP 016 #43–#48; pgTAP 017 #68, #70–#72, #75; hosted spot check (STATUS §4) |
| 18 | Session replay (F-S6-P02): a coach/Leader with **no** table-level access to an athlete's private template still gets the full prescribed-vs-actual comparison through `get_session_replay`; `workout_items.block_id = wb.id` used throughout (F-S6-P11); paired sets flag `is_skipped` (unlogged or not-completed) and `is_extra` (athlete-added, `prescribed_item_set_id IS NULL`) (F-S6-P12) | ✅ | pgTAP 016 #1–#8, #12–#15, #49 |
| 19 | Rule E on replay: private feedback and medical (`pain_discomfort`/`injury_limitation`) substitutions are `null`/omitted for a Leader; present for athlete, current coach, VP/President; a **former** coach inside their tenure gets the sets but not the private feedback | ✅ | pgTAP 016 #16–#22 |
| 20 | Replay authorization: a former coach outside tenure, a peer, an unassigned coach, another organization, `NULL`, and an unknown session id are all refused `42501` | ✅ | pgTAP 016 #23 |
| 21 | Calendar read model & summary statistics (F-S6-P08): occurrence/session visibility under RLS (incl. the D2 former-coach half-open window); adherence math with zero-division protection (`NULL`, never `0.0`); window validation (end<start, >366 days → `22023`); dynamic organization timezone (a non-Manila organization's session dates correctly, proven against a same-instant Manila comparison) | ✅ | pgTAP 016 #24–#41 |
| 22 | **F-S6-P10** — interactive Android dev-client feature smoke: signed-in `/history` + `/skills` render, `/history/[id]` replay, an attempt logged and reviewed, `/skills/verify` approval, screenshots + logcat | ⚠️ **Not executed** | [F-S6-E06](findings/F-S6-E06-android-device-smoke-not-executed.md) — credential-entry boundary against the hosted (non-localhost) dev client; no screenshots or logcat produced |
| 23 | Client: `TrainingCalendar`, `SessionReplayTable`, `SkillLadderRung`, `LogSkillAttemptModal`, `EditSkillProgressionModal`, the 5 new screens, `?athleteId=UUID` drill-down on History and Skills, verification-queue pending-count badge | ✅ | STATUS §3; typecheck 0, lint 0 |
| 24 | **F-S6-E05** — the `(coach)` route group is reachable by `skills:verify` holders who are not Coaches | ✅ | [finding](findings/F-S6-E05-coach-route-group-unreachable-for-non-coach-verifiers.md); `src/app/_layout.tsx` |
| 25 | **F-S6-E04** — `get_athlete_summary_metrics` refuses a direct call for another athlete's aggregates even though it must be granted to `authenticated` | ✅ | pgTAP 016 #42; [finding](findings/F-S6-E04-athlete-summary-metrics-defense-in-depth.md) |
| 26 | Full regression `npm run verify` | ✅ | Typecheck 0 errors; lint 0 errors/0 warnings; Jest **20 suites / 202 tests** (baseline 15/150); Node **2 suites / 9 tests** (unchanged); offline pgTAP **17 files / 770 assertions, 0 failed** (baseline 15/646) |
| 27 | `npm run build:web` | ✅ | Web bundle check passed (4 files), backend `https://sfptojkkmjggssqzyseo.supabase.co` |
| 28 | Hosted migrations applied to `bacalsys-dev`, in order, individually confirmed | ✅ | STATUS §4; 7/7 `success: true` |
| 29 | TypeScript types regenerated from the hosted project | ✅ | `src/types/database.ts`, purely additive diff confirmed before replacing |
| 30 | Hosted advisors: no new finding from this sprint's migrations | ✅ | STATUS §4 — same 4 pre-existing Sprint 1/2 warnings, unrelated |
| 31 | Hosted Acceptance Slice 1 — session replay + Rule E redaction | ✅ | **9/9** (STATUS §4) |
| 32 | Hosted Acceptance Slice 2 — skill progression, attempt review, criteria edit, mandatory-reason revocation | ✅ | **9/9** (STATUS §4) |
| 33 | Hosted concurrency probes — all 5 from Section 13, run as real overlapping HTTP calls | ✅ | **9/9** (STATUS §4 table) |
| 34 | CI green for the commits in this sprint | ⏳ Not yet checked | Pending push |
| 35 | Hosted fixture cleanup | ⚠️ Not executed | Four Sprint 6 fixtures remain on `bacalsys-dev`; the product owner's call, same convention as Sprints 2–5 |
| 36 | Tag Sprint 6 as accepted | ⏳ Not done | Requires a relayed Reviewer verdict first (workflow rule) |

## Notes

- **Findings:** [F-S6-E02](findings/F-S6-E02-can-verify-skill-permitted-self-verification.md) (Bug),
  [F-S6-E03](findings/F-S6-E03-verify-skill-achievement-unlocked-attempt-race.md) (Bug),
  [F-S6-E04](findings/F-S6-E04-athlete-summary-metrics-defense-in-depth.md) (Bug),
  [F-S6-E05](findings/F-S6-E05-coach-route-group-unreachable-for-non-coach-verifiers.md) (Bug, client-only),
  [F-S6-E06](findings/F-S6-E06-android-device-smoke-not-executed.md) (Backlog Refinement — stated verification gap).
  No ADR: nothing here conflicts with the frozen architecture; F-S6-E02/E03/E04/E05 are corrections found by
  reading the frozen text against the rest of the accepted codebase, fixed before any hosted apply.
- **Open items for the Reviewer:** whether F-S6-E06 (no on-device evidence) blocks this gate, and whether the
  product owner wants to complete the Android pass themselves (per the finding's "what is needed to close this").
- **Waived / unverified, same convention as prior sprints:** iOS, local Docker stack (`supabase test db`), hosted
  fixture cleanup.
- **Not yet done:** push to `origin/main` and check CI (item 34); this checklist itself is not yet sent anywhere —
  the Executor is holding it for the product owner to relay to the Reviewer.
