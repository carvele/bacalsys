# Sprint 5: Acceptance Checklist

> **Status: IMPLEMENTATION COMPLETE — PENDING THE REVIEWER'S INDEPENDENT ACCEPTANCE GATE.** Nothing here is
> self-approved and Sprint 5 is **not tagged**. See [STATUS.md](STATUS.md) for the engineering record, and
> [findings/](findings/) for the four classified discoveries (1 Bug, 3 Backlog Refinements, 0 ADRs).

An item is checked only with the evidence beside it. Detail is in [STATUS.md](STATUS.md).

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Tasks 5.0–5.15 implemented in order; Section 12 realized as frozen, no ADR needed | ✅ | STATUS §1, §2 |
| 2 | Assignment model: `workout_assignments`, `assignment_targets`, `recurring_schedules`, `assignment_occurrences`; `workout_sessions.assignment_occurrence_id` FK **ON DELETE RESTRICT**; at most one session per non-null occurrence | ✅ | pgTAP 013 #10–#12 (FK `confdeltype = 'r'`, partial unique index, real-FK requirement) |
| 3 | Occurrence lifecycle: legal transitions only; terminal history (completed / partially_completed / abandoned / missed) immutable; lineage & temporal anchors immutable; version change only while `upcoming`; deletion only of future/today `upcoming` rows of a cancelled assignment | ✅ | pgTAP 013 #13–#19, #24–#26; hosted privileged-path proof (STATUS §7) |
| 4 | Late offline reconciliation is **structural, no GUC**: linked in-progress session inserted first, then `missed → in_progress`; direct `missed → terminal` fails `22000` — even with a valid linked session present; `reconciled_from_missed` audited | ✅ | pgTAP 013 #20–#23 (#23: the trigger has no `current_setting`/`set_config`), 015 #5–#9, #22–#23; mutation-tested |
| 5 | Offline resilience: an occurrence deleted (or its assignment cancelled) before sync ⇒ the workout is preserved as a direct session, the occurrence is not recreated or altered, and every ordinary direct-session rule still applies | ✅ | pgTAP 015 #11–#14 (version availability `P0002`, lineage `22000`, mode `22023`, one-active-session `23505`) |
| 6 | Assignment RLS: athlete = own; current coach = only their athlete (target-safe); former coach = occurrences inside the half-open window, **0** assignment/target/schedule rows; leadership = `current org = workout_assignments.organization_id` + `training:view_org`; cross-org and NULL-org fail closed; **no creator shortcut**; `profiles.organization_id` is never referenced (it does not exist) | ✅ | pgTAP 013 #27–#40 (12 identities), hosted Slice 1 #11–#20 |
| 7 | Idempotency catalog: the 5 Sprint 4 types preserved; **exactly** `CREATE_ASSIGNMENT`, `CANCEL_ASSIGNMENT`, `MIGRATE_ASSIGNMENT_VERSION` added; same-key concurrent requests return the cached logical success | ✅ | pgTAP 013 #4; hosted probes 1, 2, 5a, 5b (STATUS §8) |
| 8 | Racing starts of one occurrence with different keys: first succeeds, second fails **`22000`** (unique index is defense in depth) | ✅ | pgTAP 014 #28; hosted probe 3 (4/4 rounds); finding F-S5-01 |
| 9 | Rule C: `template_only` mutates nothing; `future_assignments_only` moves only the assignment default; `selected_upcoming_assignments` moves only the selected `upcoming` occurrences and leaves the default alone; never in-progress/terminal; `version_migrated` audited | ✅ | pgTAP 014 #45–#59; hosted Slice 3 (13/13) |
| 10 | Scheduling: organization timezone authoritative; weekdays normalized sorted/distinct; horizon exactly `[org_today, org_today+13]`; due = next local midnight (DST 23h/25h days); generator idempotent; overdue job touches only `upcoming`; cron actor independent of auth (`actor_type='cron'`) | ✅ | pgTAP 014 #6–#7, #14–#25; hosted Slice 1 #8–#10, Slice 2 |
| 11 | Concurrency proven on hosted `bacalsys-dev`: duplicate CREATE (same key); duplicate assigned START (same key); different-key START race; START vs overdue job (**both orders, real overlap**); START vs cancellation (both serializations observed); generator vs cancellation (**both orders, real overlap**) | ✅ | STATUS §8 — 9/9 client probes + R3a, R3b, R5a, R5b via `pg_cron` background sessions; method in `scripts/e2e/sprint5-cron-races.sql` |
| 12 | Required pgTAP coverage: schema/constraints, RLS matrix, organization boundary, terminal immutability, direct `missed→terminal` rejection, Rule C, timezone generation, cron actor/audit, late-sync structural reconciliation, cancelled-occurrence offline fallback, RPC signature inventory, exact scoped idempotency types | ✅ | `013` (53) + `014` (61) + `015` (24); seven invariants mutation-tested, all caught (STATUS §3) |
| 13 | RPC signature inventory: 2 public `start_workout_session`, exactly 1 private `start_workout_session_internal(uuid,uuid,uuid)` | ✅ | pgTAP 013 #45–#48; hosted verification (STATUS §5) |
| 14 | Public wrappers `SECURITY INVOKER`; every `SECURITY DEFINER` pins `search_path=''`; cron/helper/trigger functions not executable by `authenticated`/`anon`; direct DML revoked | ✅ | pgTAP 013 #2–#3, #49–#52; hosted: 0 definer functions without pinned search_path, no client DML grant |
| 15 | Forward migrations only (6 new, no applied migration edited); hosted migration status recorded; TypeScript types regenerated from hosted | ✅ | STATUS §5; `src/types/database.ts` |
| 16 | Full regression `npm run verify` | ✅ | Typecheck 0 errors; lint 0; Jest **14 suites / 145 tests**; Node **2 suites / 9 tests**; pgTAP **15 files / 646 assertions, 0 failed** (baseline 10/106, 2/9, 12/508) |
| 17 | Hosted Acceptance Slice 1 — creation, multi-targeting, recurrence, RLS reach | ✅ | **23/23** (STATUS §6) |
| 18 | Hosted Acceptance Slice 2 — occurrence execution, overdue cron, cancellation immutability | ✅ | **11/11 + 12/12** and the privileged `22000` proofs (STATUS §7) |
| 19 | Hosted Acceptance Slice 3 — Rule C | ✅ | **13/13** (STATUS §7) |
| 20 | Client: date/timezone utilities, `AssignWorkoutModal`, Rule C `VersionAdoptionPanel`, athlete "Today's training", coach roster, occurrence-linked player / outbox / bundle | ✅ | STATUS §1, §4; 39 new Jest tests; typecheck, lint, `npm run build:web` |
| 21 | Hosted advisors | ✅ | No new security findings; no missing-FK-index warnings (STATUS §10) |
| 22 | CI green for every pushed commit | ✅ | Run [36408260792](https://github.com/carvele/bacalsys/actions/runs/36408260792) on the code commit `761af0b`; the evidence commit's run is recorded in STATUS §12 |
| 23 | Android dev-client boot | ⚠️ Build / install / launch / no-crash only | Gradle BUILD SUCCESSFUL, `MainActivity` resumed, **0** crash entries for our package. **No visual render confirmation**: the emulator's own `system` process hit an ANR under load and, on the product owner's instruction, the check moved to the web app (STATUS §11) |
| 24 | Web check of the deployed build | ✅ read-only | Home renders the live "Today's training" card (empty state), 0 console errors, under the product owner's own session; no mutating action |
| 25 | Signed-in UI click-through of the new screens | ⏳ Pending product owner | Executor may not enter credentials or act on a live personal account |
| 26 | Local-stack runs (`supabase test db`) | ⚠️ Waived | Docker unavailable; offline PGlite + hosted probes cover the same ground |
| 27 | Hosted fixture cleanup | ⚠️ Not executed | The product owner's call, same as Sprints 2–4 |
| 28 | F-S5-03 — offline workout vs Rule C version drift | ⚠️ Open decision (Planner) | Literal frozen contract implemented (`22000`); fallback options written up, none built |
| 29 | Tag Sprint 5 as accepted | ⏳ **Not done** | Awaiting the Reviewer gate; the Executor does not self-approve or tag |

## Notes

- **Findings:** [F-S5-01](findings/F-S5-01-racing-start-must-fail-22000-not-23505.md) (Bug),
  [F-S5-02](findings/F-S5-02-pg-cron-not-installed-on-hosted.md), [F-S5-03](findings/F-S5-03-offline-bundle-vs-rule-c-version-drift.md),
  [F-S5-04](findings/F-S5-04-recurring-schedule-timezone-copy-can-go-stale.md) (Backlog Refinements). No ADR and no
  deviation from Section 12's architecture.
- **Operational change to flag:** applying the scheduling migration installed `pg_cron` 1.6.4 on `bacalsys-dev`
  (F-S5-02). The two frozen jobs now run on the dev database; one-off probe jobs were removed.
- **Next workflow step:** the product owner relays this package (STATUS.md + ACCEPTANCE.md + findings + the commit list)
  to the ChatGPT Reviewer for the independent acceptance gate. Sprint 5 stays untagged until a Reviewer verdict is relayed.
