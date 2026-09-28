# F-S5-03 — An offline workout can fail to sync if Rule C moves its occurrence to a new version while the athlete is offline

- **Class:** Backlog Refinement (open decision for the Planner; **not** implemented, no baseline change).
- **Severity:** Medium (athlete data is not lost — it stays in the on-device outbox — but it cannot sync until reconciled).
- **Found during:** Task 5.6 (writing the bundle's occurrence checks).

## Scenario

1. An athlete opens an `upcoming` occurrence pinned to **V1**, goes offline and trains.
2. While they are offline, the coach applies Rule C `selected_upcoming_assignments`, moving that still-`upcoming` occurrence to **V2** (Rule C forbids moving only `in_progress`/terminal occurrences, and the server cannot know a session is running offline).
3. The athlete reconnects: the bundle carries `workout_version_id = V1`, the occurrence now pins V2.

## What the frozen text says, and what was built

Section 12: for a brand-new offline session, "verifies `occurrence.workout_version_id = bundle.workout_version_id`". Implemented literally: a mismatch raises **`22000`** and the bundle does not sync (the ordinary outbox retry/dead-letter policy then applies; the pinned-history invariant — "a session never silently migrates to a newer version" — is preserved).

Contrast the cases the Reviewer explicitly required to preserve the workout (occurrence deleted, assignment cancelled, missed-and-started-after-deadline): those fall back to a direct session. A version mismatch does **not** fall back, because the frozen text asks for verification, not preservation.

## Options for the Planner (none taken)

- **A.** Fall back to a *direct* session pinned to V1 (data preserved; the occurrence is left as-is for the athlete to redo on V2). Smallest change; one extra branch in `sync_offline_session_bundle_internal`.
- **B.** Reject Rule C migration of an occurrence that started a session offline — impossible server-side without client telemetry.
- **C.** Client-side: re-key the bundle to the occurrence's new version — invalid, the sets were performed against V1's prescription.

Recommendation: **A**, as a follow-up sprint item (an ADR is only needed if the Planner wants B/C). Until then the behaviour is the literal frozen contract.

## Evidence

pgTAP 015 #16 asserts the literal behaviour (`22000` on a version mismatch, occurrence untouched).
