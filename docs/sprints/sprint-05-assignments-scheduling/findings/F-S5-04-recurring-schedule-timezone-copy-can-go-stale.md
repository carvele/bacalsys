# F-S5-04 — `recurring_schedules.timezone` is a write-time copy that can go stale if the organization's timezone changes

- **Class:** Backlog Refinement (no runtime defect).
- **Severity:** Low.
- **Found during:** Task 5.3 (deciding which timezone the generator reads); exercised by pgTAP 014 #18–#21.

## Observation

Section 12 stores the organization's timezone on each `recurring_schedules` row and enforces `recurring_schedules.timezone = organizations.timezone` with a `BEFORE INSERT OR UPDATE OF timezone` trigger on the *schedule*. Nothing re-checks it when `organizations.timezone` itself later changes, so an existing schedule's copy can drift from the organization's.

## What was built (and why runtime behaviour stays correct)

The Reviewer baseline says "**organization timezone is authoritative**". The generator, the cancellation cut-off and the lifecycle trigger therefore read `organizations.timezone` directly (the frozen text's `COALESCE(s.timezone, o.timezone, …)` would have let the stale copy win). With the invariant intact the two are identical; if an organization's timezone is ever changed the *next* generator run simply schedules in the new zone. pgTAP 014 proves the horizon and the local-midnight `scheduled_at`/`due_datetime` pair follow the organization-local date for UTC+14 and UTC−11 organizations, and that a 23h / 25h DST day gets a `due_datetime` at the next local midnight.

## Follow-up (not done)

A tiny `AFTER UPDATE OF timezone ON organizations` trigger that re-syncs the schedule copy would remove the cosmetic divergence. Changing an organization's timezone is a rare administrative act with no UI today, so this is recorded rather than built.
