# F-S5-01 — A racing second START of one occurrence would fail 23505, not the mandated 22000

- **Class:** Bug (implementation detail: the frozen acceptance text and the inherited Sprint 4 function body could not both hold as literally combined).
- **Severity:** Medium (no data risk — the unique session/occurrence index and the one-active-session index both hold — but the *observable outcome* would contradict the frozen contract and the Reviewer's execution baseline).
- **Found during:** Task 5.6 design, before any code ran; pinned by test before it could regress.

## Symptom

Section 12 (and the Reviewer's baseline, invariant 5) require that when two requests start the **same assignment occurrence with different idempotency keys**, "the first succeeds, the second wakes after locking and sees the occurrence no longer `upcoming`; the expected failure is `22000`".

Sprint 4's `start_workout_session_internal` takes the athlete's `profiles` row `FOR UPDATE` **first**, then checks "you already have an active session" (`23505`). Both racing requests come from the *same athlete*, so they serialize on that profile lock — and the second, once awake, would find the first's `in_progress` session and raise **`23505`** before it ever looked at the occurrence. Bolting the occurrence checks on *after* the existing profile lock would therefore never produce `22000`.

## Root cause

The frozen text specifies the assignment → occurrence lock order and the occurrence-state check, but is silent on where they sit relative to the pre-existing profile lock / active-session check that Sprint 4 shipped. A literal append puts them behind it.

## Fix

`start_workout_session_internal` (migration `workout_session_occurrence_handshake`) now resolves the occurrence **before** the profile lock:

1. pre-read ownership with no lock (a non-owner can never queue on somebody else's occurrence, 42501);
2. `workout_assignments … FOR SHARE` (cancelled ⇒ 22000);
3. `assignment_occurrences … FOR UPDATE`, then owner / `status = 'upcoming'` (22000) / version match (22000);
4. **only then** the profile lock and the active-session rule (23505).

The same order is used by the offline bundle path (assignment share → occurrence update → profile lock) so a start and a bundle sync racing on one athlete can never deadlock (a profile-first bundle against an occurrence-first start would have been a lock inversion). Cancellation (assignment `FOR UPDATE`), Rule C migration (assignment `FOR UPDATE`, occurrences `FOR UPDATE`), the generator (assignment `FOR SHARE`) and the overdue job (occurrence `FOR UPDATE SKIP LOCKED`) all agree with it.

## Regression coverage

- pgTAP 014 #28: a second start of the same occurrence with a different key fails `22000` even though the athlete already has an active session (the active-session `23505` still fires for every *other* start); mutation-tested (disabling the `upcoming` check turns the assertion red).
- pgTAP 014 #60 and 015 #22: the source-order of the three locks is asserted structurally for both the start and the bundle path.
- Hosted probe 3 (4/4 rounds): two real concurrent starts with different keys ⇒ exactly one success, the other `22000`.
- Hosted probe R3a: a start that waits behind the overdue job's row lock wakes up to `missed` and fails `22000`.

## Classification note

No ADR: the frozen contract (assignment `FOR SHARE` → occurrence `FOR UPDATE`, `22000` for a non-upcoming occurrence) is realized exactly; only the position of the *pre-existing* profile lock relative to it was decided here.
