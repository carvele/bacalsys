# Sprint 4: Acceptance Checklist

> **Status: F-S4-02 NARROW RE-REVIEW FIX COMPLETE — READY FOR RE-REVIEW.** The Reviewer's first implementation/evidence
> gate returned **FAIL** for one defect (F-S4-02); it was fixed within the Reviewer's stated scope, then the
> Reviewer's narrow re-review caught one remaining race purely in `workout/active.tsx`'s call ordering, which has now
> also been fixed (Section 11 architecture, F-S4-01, F-S4-P13, F-S4-P14, permissions, RLS, server mutation semantics,
> and the `OutboxStorage`/SQLite/IndexedDB design were not touched by either fix). No Reviewer verdict on this second
> fix has been relayed yet. The Executor never self-approves or tags a sprint without that relay — see
> [STATUS.md](STATUS.md) header for the full gate history.

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
| 8 | Full regression `npm run verify` | ✅ | Typecheck, lint, Jest **98/98**, script tests, offline pgTAP **508/508** (post F-S4-02 narrow re-review fix) |
| 9 | Hosted pgTAP-equivalent state | ✅ | 7 migrations applied and re-verified on `bacalsys-dev` (STATUS §5, §10) |
| 10 | Hosted Execution Acceptance Slice 1 | ✅ | **18/18** (STATUS §6) |
| 11 | Hosted Acceptance Slice 2 (offline bundle + replay idempotency) | ✅ | **6/6** (STATUS §7) |
| 12 | Concurrency verification probes | ✅ | **6/6** (STATUS §8) |
| 13 | Supabase advisors | ✅ | No new security findings; 1 genuine performance gap (4 uncovered FKs) found and fixed (STATUS §10) |
| 14 | F-S4-01 (`session_set_load_consistency` NULL-vs-CHECK gap) resolved | ✅ | Fixed pre-hosted-apply, in the initial schema migration; pgTAP 011 §2 |
| 15 | F-S4-02 (offline outbox server handshake not durable across restart) resolved, incl. narrow re-review follow-up | ✅ | `session_handshakes` durable store (SQLite table / IndexedDB store), 2 Jest restart-recovery tests; plus the narrow re-review's `active.tsx` ordering/fail-closed fix via `beginOnlineSession()` (new `session-start.ts`), 3 more Jest tests; both rounds mutation-tested (STATUS §2–3) |
| 16 | CI green for every pushed commit | ✅ (narrow-re-review-fix commit pending push) | Runs 36324519669, 36327084129, 36327659766, 36329178710, 36330960227, 36331210108 all green; the narrow-re-review-fix commit's run is not yet available — CI must be confirmed green for it too before the gate closes (STATUS §12) |
| 17 | Client: offline outbox, sync engine, rest timer, substitution modal, player + summary screens (Tasks 4.9–4.14) | ✅ | STATUS §4; 28 new Jest tests incl. the full online→offline→reconnect→offline→bundle acceptance scenario, the F-S4-02 restart-recovery scenario, and the narrow re-review's online-start ordering/fail-closed scenario |
| 18 | Android dev-client boot (mandatory: 4 native modules added) | ✅ | Build/install/launch succeeded, all 4 modules autolinked, no crash in logcat — STATUS §11 |
| 19 | Signed-in UI click-through | ⏳ Pending product owner | Read-only web smoke check only (STATUS §12); interactive click-through of the new screens not performed by the Executor (credential/live-account rule) |
| 20 | Local-stack runs (`supabase test db`) | ⚠️ Waived | Docker is unavailable (no WSL); offline PGlite + hosted probes cover the same ground |
| 21 | Hosted fixture cleanup | ⚠️ Not executed | The product owner's call, same as Sprints 2–3 |
| 22 | Row-lock concurrency under true simultaneous transactions | ⚠️ Waived | Hosted probes assert outcome over concurrent RPC calls, not the lock wait itself — same standard as Sprints 2–3 |
| 23 | Mixed online/offline-in-one-session completion | ⚠️ Documented gap, not silently assumed correct | STATUS §9 — not exercised by either hosted Acceptance Slice; summary.tsx's routing rule avoids it in practice but the bundle-replay collision case itself is untested |
| 24 | App-process-kill mid-session recovery | ⚠️ Partially out of scope, documented | STATUS §9/§13 — the durable outbox rows (incl. the handshake, per F-S4-02) reliably survive and resume syncing; only the athlete's in-memory UI draft (`session-store.ts`) does not |
| 25 | Circuit-block round repetition / AMRAP countdown UI | ⚠️ Out of scope, documented | STATUS §9/§13 — athlete can freely log additional sets instead |
| 26 | F-S4-02 hosted recovery probe | ⚠️ Not applicable, documented | STATUS §13 — a client-local-storage-restart defect has no hosted-RPC surface to probe; covered instead by the Jest restart-recovery tests against the real `OutboxStorage` contract |
| 27 | Tag Sprint 4 as accepted | ⏳ **Not done** | Awaiting the Reviewer gate relay; the Executor does not self-approve or tag |

## Notes

- Findings: [F-S4-01](findings/F-S4-01-session-set-load-consistency-null-load-type-loophole.md) (Bug, Medium, found
  pre-hosted-apply) and [F-S4-02](findings/F-S4-02-outbox-handshake-not-durable-across-restart.md) (Bug, High, found
  by the Reviewer's gate, with a narrow re-review follow-up documented in the same finding file) — both classified
  as Bugs (implementation corrections to how the frozen Section 11 requirement, or the client's own stated
  durability guarantee, is realized); no ADR needed for either.
- Next workflow step: this delta evidence (STATUS.md + ACCEPTANCE.md + the F-S4-02 finding's narrow-re-review section
  + CI link, once available) goes to the product owner to relay back to the ChatGPT Reviewer, who stated this gate
  should close without another architectural pass once the ordering/fail-closed fix lands. No further Sprint 4
  implementation changes are planned unless the Reviewer finds another defect. Sprint 4 is not tagged until that
  gate closes.
