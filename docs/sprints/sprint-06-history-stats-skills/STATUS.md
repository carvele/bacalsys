# Sprint 6: Training History, Statistics & Calisthenics Skills — engineering status

> **Status: implementation complete, verification-in-progress. Not yet submitted to the Reviewer.** The Executor
> never self-approves; [ACCEPTANCE.md](ACCEPTANCE.md) carries the gate rows and stays unchecked until a Reviewer
> verdict is relayed by the product owner. One required gate item — the interactive Android dev-client smoke test
> (F-S6-P10) — was **not executed**; see [F-S6-E06](findings/F-S6-E06-android-device-smoke-not-executed.md) for why
> and what closing it needs.
>
> **Baseline:** `sprint-05-accepted` (commit `f87d807`). Roadmap v1.2 Section 13, Tasks 6.0–6.16, implemented from
> the Planner's dispatch as frozen, with five Executor-classified discoveries (§5): four Bugs found by reading the
> frozen predicate/navigation text against the rest of the accepted codebase (fixed before any hosted apply), and
> the Android-evidence gap above.

- **Environment:**
  - Hosted dev project `bacalsys-dev` (`sfptojkkmjggssqzyseo`), PostgreSQL **17.6**.
  - Offline harness: PGlite, PostgreSQL **18.3**.
  - Docker is unavailable, so `supabase test db` and the local stack were **not run** (same waiver as Sprints 1–5).
  - Android emulator (AVD `Pixel_4`) was not booted for this sprint — see F-S6-E06.

## 1. Task 6.0 — baseline re-verification

Before any Sprint 6 file was touched: `npm run verify` on `4afa42d` (2 documentation commits ahead of the accepted
tag `f87d807`, no code change between them) — typecheck 0 errors, lint 0, Jest **15 suites / 150 tests**, Node
**2 suites / 9 tests**, pgTAP **15 files / 646 assertions**, all green. Matches the dispatch's stated baseline
exactly.

## 2. Tasks 6.1–6.9 — database

| Task | Status | Deliverable / evidence |
|---|---|---|
| 6.1 Permission & idempotency migration | ✅ | `20260929000001_skills_permissions.sql`: `skills:manage` inserted (`skills:verify` already existed since the Sprint 1 seed catalog — repeated idempotently); both mapped to Coach/VP/President; idempotency ledger gains the 6 skill mutation types, preserving the 8 accepted Sprint 4/5 types |
| 6.2 Skills & progressions schema | ✅ | `20260929000002_...schema.sql`: `skills`, `skill_progressions` (composite FK target for F-S6-P06), `athlete_skill_status`, `skill_attempts`, `skill_achievements`; no free-text notes column anywhere (F-S6-P09); RLS enabled, SELECT-only grants (ADR-002) |
| 6.3 Default ladder seed | ✅ | `20260929000003_seed_default_skill_progressions.sql`: `app_private.seed_default_skill_ladders(org)` — 6 ladders / 28 rungs, `ON CONFLICT DO NOTHING` at both levels (idempotent, never overwrites a coach's later edit — proven in pgTAP 017 §9); called directly for hosted (org already exists) and from `seed.sql` for a fresh reset (org does not exist until seed runs) |
| 6.4 Scope/authorization helpers | ✅ | `20260929000004_...helpers.sql`: `holds_active_position` (F-S6-P14 guard), `can_view_athlete_training`, `can_verify_skill` (**hardened**, F-S6-E02), `can_set_athlete_skill_status`, `can_view_athlete_skill_status/_attempts/_achievements` — all `SECURITY DEFINER`, `search_path=''`, revoked from `PUBLIC`/`anon` |
| 6.5 Skills RLS | ✅ | `20260929000005_skills_rls.sql`: 5 SELECT policies, every one gated by `holds_active_position()` (F-S6-P14) |
| 6.6 History/replay/statistics RPCs | ✅ | `20260929000006_...rpcs.sql`: `get_session_replay` (F-S6-P02/P11/P12), `get_my_athlete_summary`/`get_athlete_summary` (F-S6-P08, dynamic org timezone, zero-division-safe adherence); **hardened** `get_athlete_summary_metrics` self-check (F-S6-E04) |
| 6.7 Skills workflow RPCs | ✅ | `20260929000007_skills_workflow_rpcs.sql`: 6 mutating RPCs, mandatory idempotency key with no default (F-S6-P13), reservation before every row lock (F-S6-P05), lineage validation (F-S6-P06), **hardened** `verify_skill_achievement` row lock (F-S6-E03) |
| 6.8 pgTAP history/statistics suite | ✅ | `016_training_history_and_statistics.test.sql`, **49** assertions |
| 6.9 pgTAP skills suite | ✅ | `017_skills_and_progressions.test.sql`, **75** assertions |

Existing tests updated for the new `skills:manage` mapping: `002_rbac_access_context.test.sql`,
`006_permission_matrix.test.sql` (golden matrix rows).

## 3. Tasks 6.10–6.15 — client

| Task | Status | Deliverable |
|---|---|---|
| 6.10 Types, stats, skills libraries | ✅ | `src/types/skills.ts` (hand-written `jsonb` parsers, no schema library — no new dependency without an ADR), `src/lib/training-stats.ts` (calendar precedence, month grid, adherence/volume formatting), `src/lib/skills.ts` (TanStack Query hooks + RPC wrappers) |
| 6.11 Training Calendar | ✅ | `src/components/TrainingCalendar.tsx`, `src/app/(athlete)/history/index.tsx`; `?athleteId=UUID` drill-down; 30-day adherence card with progress bar |
| 6.12 Session Replay | ✅ | `src/components/SessionReplayTable.tsx`, `src/app/(athlete)/history/[id].tsx`; prescribed-vs-actual per set, extra/skipped badges, substitution lineage, Rule-E-redacted private feedback rendered only when the RPC returns it |
| 6.13 Skill Tree screens | ✅ | `src/components/SkillLadderRung.tsx`, `LogSkillAttemptModal.tsx`, `EditSkillProgressionModal.tsx`, `src/app/(athlete)/skills/index.tsx` + `[id].tsx`; `?athleteId=UUID` drill-down; objective-only attempt logging (F-S6-P09) |
| 6.14 Coach Verification Queue | ✅ | `src/app/(coach)/skills/verify.tsx`: pending-attempt triage (approve/reject with feedback) plus a "recently verified by you" list with mandatory-reason revocation |
| 6.15 Home/roster integration | ✅ | Athlete Home: History/Skills cards, officer-tools verification-queue link with a pending-count badge. Coach roster: History/Skills buttons per athlete, `?athleteId=...`. **F-S6-E05**: root navigator widened so `skills:verify` (not just Coach) reaches the `(coach)` route group |

Client-side pure logic and its Jest coverage: `src/lib/training-stats.ts` (17 tests), `src/features/history/replay.ts`
(15), `src/features/skills/ladder.ts` (9), `src/features/skills/attempt-form.ts` (5),
`src/features/skills/progression-form.ts` (6) — **52 new tests**, written alongside their implementation.

## 4. Task 6.16 — verification

- **Full regression** (`npm run verify`, run once as a single combined pass after the pieces above were each
  green): typecheck **0 errors**; lint **0 errors, 0 warnings**; Jest **20 suites / 202 tests** (was 15/150); Node
  scripts **2 suites / 9 tests** (unchanged); offline pgTAP **17 files / 770 assertions, 0 failed** (was 15/646);
  `npm run build:web` passes (web bundle check green, backend `https://sfptojkkmjggssqzyseo.supabase.co`).
- **Hosted migrations:** all 7 applied to `bacalsys-dev` via the Supabase MCP, in order, each confirmed
  individually (`success: true`); post-apply spot checks: 6 skills / 28 rungs seeded, `skills:manage` on
  Coach/VP/President, 9 `SECURITY INVOKER` public wrappers, `anon` denied `get_session_replay`.
- **Hosted advisors:** `get_advisors(security)` after all 7 migrations shows the **same 4 pre-existing** warnings
  from Sprints 1–2 (`approve_member`, `create_invitation`, `get_my_access_context`, `list_pending_members` callable
  by `authenticated` — accepted, unrelated to Sprint 6) plus the standing "leaked password protection disabled"
  notice. **No new finding from this sprint's migrations.**
- **TypeScript types:** regenerated from the hosted project (`generate_typescript_types`) and installed at
  `src/types/database.ts` — a purely additive diff (361 added lines, 0 removed) confirmed before replacing the file.

### Hosted acceptance slices — `scripts/e2e/sprint6-slices.mjs`

Four disposable `*.e2e.bacalsys.local` fixtures (Coach, Athlete, Leader, Vice President), registered via
`auth.signUp` (no privileged credentials used), activated by a short SQL step run by the Executor through the
Supabase MCP impersonating the hosted project's own disposable **"Seed President"** fixture via
`set_config('request.jwt.claims', ...)` — never the product owner's personal President account, which was read
only to distinguish it from the seed fixture and never mutated or signed into.

```bash
node --env-file=.env.hosted.local scripts/e2e/sprint6-slices.mjs setup
node --env-file=.env.hosted.local scripts/e2e/sprint6-slices.mjs slices
node --env-file=.env.hosted.local scripts/e2e/sprint6-slices.mjs concurrency
```

**Slice 1 — session replay & Rule E (9/9):** athlete completes a real session (`start_workout_session` →
`record_session_set` → `complete_workout_session` with private feedback); athlete and current coach both see the
paired sets and the private feedback via `get_session_replay`; a Leader (organization-wide `training:view_org`,
no `training:view_private_feedback`) sees the same workout sets but `private_feedback: null`; `get_my_athlete_summary`
is reachable; `anon` is refused `get_session_replay` (`42501`).

**Slice 2 — skill progression, review, criteria edit, revocation (9/9):** athlete sets a trained rung and logs an
attempt (18s hold + video link) → `pending_review`; coach approves with feedback → attempt `approved`, achievement
`active` (Tier 3 badge); coach edits the next rung's criteria (12s → 15s) → the edit is audited
(`old_values`/`new_values`, read back as the Vice President, since `audit:view` is executive-only — Coach does not
hold it, matching the accepted permission matrix); revoking without a reason fails closed; revoking with one
succeeds.

**Concurrency probes (9/9), Section 13's five, run as real overlapping `Promise.all` HTTP calls:**

| # | Probe | Result |
|---|---|---|
| 1 | Same attempt, **same** idempotency key, two concurrent reviewers | Both calls succeed, both return the **identical** `achievement_id` — one reservation, one approval |
| 2 | Different attempt, **different** keys, two concurrent reviewers | Exactly one winner; the other fails closed `22000` ("already been reviewed") |
| 3 | Same key, **different** payload (12s → 99s) | First call succeeds; the replay with a different payload fails closed `42501` |
| 4 | Same `(athlete, skill)`, two concurrent `set_athlete_skill_status` calls (different rungs) | Both succeed; exactly one row survives, on one of the two rungs (`ON CONFLICT DO UPDATE`, no constraint violation) |
| 5 | Same achievement, concurrent `verify` (VP) + `revoke` (Coach) | Both complete without deadlock; the achievement lands in one deterministic final state (`active` or `revoked`) |

### Android dev-client smoke test — **not executed**

See [F-S6-E06](findings/F-S6-E06-android-device-smoke-not-executed.md). The dev client targets the hosted
`bacalsys-dev` project, not a local development host, so reaching any signed-in screen requires typing test
credentials into a field the Executor's standing instructions do not permit outside a strictly local host —
regardless of the credentials being disposable. No screenshots or logcat were produced. This is stated here
plainly, not silently skipped; see the finding for what would close it.

## 5. Findings

- [F-S6-E02](findings/F-S6-E02-can-verify-skill-permitted-self-verification.md) (Bug) — `can_verify_skill` as
  specified would let a training officer verify their own skill; fixed with an explicit `auth.uid()` exclusion.
- [F-S6-E03](findings/F-S6-E03-verify-skill-achievement-unlocked-attempt-race.md) (Bug) — `verify_skill_achievement`
  read its linked attempt without `FOR UPDATE`, unlike its sibling `review_skill_attempt`; fixed to match.
- [F-S6-E04](findings/F-S6-E04-athlete-summary-metrics-defense-in-depth.md) (Bug) — `get_athlete_summary_metrics`,
  necessarily granted to `authenticated` for its `SECURITY INVOKER` wrappers to work, had no authorization check of
  its own and so was directly callable via PostgREST for any athlete's aggregates; fixed with a self-check matching
  `get_session_replay_internal`'s existing pattern.
- [F-S6-E05](findings/F-S6-E05-coach-route-group-unreachable-for-non-coach-verifiers.md) (Bug, client-only) — the
  `(coach)` route group was gated on the Coach position alone, so a Vice President/President holding
  `skills:verify` could never reach `/skills/verify`; the root navigator guard now also admits `skills:verify`.
- [F-S6-E06](findings/F-S6-E06-android-device-smoke-not-executed.md) (Backlog Refinement) — the required interactive
  Android smoke test was not run; the credential-entry boundary and what would close it are recorded there.

No ADR was needed: nothing here conflicts with the frozen architecture or roadmap; all five are either predicate/
navigation corrections against the frozen text itself, or an explicitly stated verification gap.

## 6. Not verified (stated plainly)

- Interactive Android dev-client feature smoke (F-S6-E06): no screenshots, no logcat.
- iOS: never targeted in any sprint so far (same waiver as Sprints 1–5).
- Local Docker stack (`supabase test db`, `npm run db:test`, `npm run e2e:skeleton`): Docker unavailable, same
  waiver as Sprints 1–5; the offline PGlite harness (770 assertions) and the hosted e2e scripts above cover the
  same ground.
- Hosted fixture cleanup: the four Sprint 6 fixtures remain on `bacalsys-dev`
  (`scripts/test/cleanup-fixtures.mjs` removes them); left for the product owner's call, same convention as
  Sprints 2–5.
- CI status for the commits in this sprint: not yet checked at the time of writing (pending push).
