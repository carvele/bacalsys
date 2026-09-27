# Sprint 4: Acceptance Checklist

> **Status: PENDING REVIEWER GATE.** Implementation and evidence are complete; no Reviewer verdict has been relayed
> yet. The Executor never self-approves or tags a sprint without that relay — see [STATUS.md](STATUS.md) header.

An item is checked only with the evidence beside it. Detail is in [STATUS.md](STATUS.md).

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Tasks 4.0–4.15 implemented in dependency order | ✅ | STATUS §1 |
| 2 | Execution schema (workout_sessions → session_exercises → session_sets, session_modifications, session_feedback/session_private_feedback split); no assignment/recurrence tables (Sprint 5 boundary) | ✅ | STATUS §1; migration `…130335_workout_execution_schema` |
| 3 | Public wrapper → `app_private` internals; Supabase-generated migration names; forward-only | ✅ | STATUS §1; 7 migrations total, all new (no Sprint 1–3 migration edited) |
| 4 | Race-safe idempotency (composite reservation, SHA-256 payload-hash validation, caller-scoped) | ✅ | pgTAP 011 §3, 012 §2; hosted concurrency probes 1–3 |
| 5 | Two-tier RLS (`can_view_workout_session` / `can_view_session_private_feedback`); F-S4-P13 uniform audit redaction | ✅ | pgTAP 011 §5–7; hosted Slice 1 |
| 6 | F-S4-P14 substitution lineage invariant (before any set, single substitution per item) | ✅ | pgTAP 012 §3; hosted Slice 1 |
| 7 | pgTAP negative and structural tests | ✅ | 011 (35) and 012 (30) |
| 8 | Full regression `npm run verify` | ✅ | Typecheck, lint, Jest **93/93**, script tests, offline pgTAP **508/508** |
| 9 | Hosted pgTAP-equivalent state | ✅ | 7 migrations applied and re-verified on `bacalsys-dev` (STATUS §5, §10) |
| 10 | Hosted Execution Acceptance Slice 1 | ✅ | **18/18** (STATUS §6) |
| 11 | Hosted Acceptance Slice 2 (offline bundle + replay idempotency) | ✅ | **6/6** (STATUS §7) |
| 12 | Concurrency verification probes | ✅ | **6/6** (STATUS §8) |
| 13 | Supabase advisors | ✅ | No new security findings; 1 genuine performance gap (4 uncovered FKs) found and fixed (STATUS §10) |
| 14 | F-S4-01 (`session_set_load_consistency` NULL-vs-CHECK gap) resolved | ✅ | Fixed pre-hosted-apply, in the initial schema migration; pgTAP 011 §2 |
| 15 | CI green for every pushed commit | ✅ | Runs 36324519669, 36327084129 (STATUS §12); ⏳ pending for the fk-index commit |
| 16 | Client: offline outbox, sync engine, rest timer, substitution modal, player + summary screens (Tasks 4.9–4.14) | ✅ | STATUS §4; 23 new Jest tests incl. the full online→offline→reconnect→offline→bundle acceptance scenario |
| 17 | Android dev-client boot (mandatory: 4 native modules added) | ⏳ | Build in progress at report time — STATUS §11 |
| 18 | Signed-in UI click-through | ⏳ Pending product owner | Not performed by the Executor (credential-entry rule) |
| 19 | Local-stack runs (`supabase test db`) | ⚠️ Waived | Docker is unavailable (no WSL); offline PGlite + hosted probes cover the same ground |
| 20 | Hosted fixture cleanup | ⚠️ Not executed | The product owner's call, same as Sprints 2–3 |
| 21 | Row-lock concurrency under true simultaneous transactions | ⚠️ Waived | Hosted probes assert outcome over concurrent RPC calls, not the lock wait itself — same standard as Sprints 2–3 |
| 22 | Mixed online/offline-in-one-session completion | ⚠️ Documented gap, not silently assumed correct | STATUS §9 — not exercised by either hosted Acceptance Slice; summary.tsx's routing rule avoids it in practice but the bundle-replay collision case itself is untested |
| 23 | App-process-kill mid-session recovery | ⚠️ Out of scope, documented | STATUS §9/§13 — durable outbox rows survive; the in-memory session draft does not |
| 24 | Circuit-block round repetition / AMRAP countdown UI | ⚠️ Out of scope, documented | STATUS §9/§13 — athlete can freely log additional sets instead |
| 25 | Tag Sprint 4 as accepted | ⏳ **Not done** | Awaiting the Reviewer gate relay; the Executor does not self-approve or tag |

## Notes

- Findings: [F-S4-01](findings/F-S4-01-session-set-load-consistency-null-load-type-loophole.md) — classified as a Bug
  (implementation correction to how the frozen Section 11 requirement is realized); no ADR needed.
- Next workflow step: this evidence package (STATUS.md + ACCEPTANCE.md + findings + CI links) goes to the product
  owner to relay to the ChatGPT Reviewer for the implementation/evidence acceptance gate. No further Sprint 4
  implementation changes are planned unless the Reviewer finds a defect. Sprint 4 is not tagged until that gate
  closes.
