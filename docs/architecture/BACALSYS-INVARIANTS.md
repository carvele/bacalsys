# BaCalSys Frozen Architecture Invariants

Use this as a compact execution reference. The full frozen roadmap remains the product baseline.

## Identity and authorization

- Club positions: Athlete, Leader, Coach, Vice President, President.
- System roles are separate from club positions.
- Member positions and system roles are temporal; active rows have `ended_at IS NULL`.
- Permission helpers consider only active positions/roles.
- Client-safe RPCs live in exposed `public`; internal implementations live in unexposed `app_private`.
- RLS combines permission checks with row-scope predicates.
- One active primary coach per athlete.
- Former coach access uses half-open intervals: `started_at >= start_date AND started_at < end_date`.
- Current primary coach sees full athlete training history.

## Training model

- `workout_templates -> workout_versions -> workout_blocks -> workout_items -> workout_item_sets`.
- Actual execution is stored separately in sessions/session exercises/session sets.
- `prescribed_item_set_id` may be null for added actual sets.
- Template/version updates never mutate completed or started session history.
- Substitutions retain exact original workout-item lineage.
- Explicit session states: completed, partially_completed, abandoned. Missed belongs to assignment occurrence status.

## Assignments and recurrence

- Programming event: `workout_assignments`.
- Targets: `assignment_targets`.
- Per-athlete scheduled units: `assignment_occurrences`.
- Recurrence attaches to assignment.
- Scheduled functions are timezone-aware and use organization timezone.
- Past occurrences are immutable historical facts.

## Privacy

Ordinary feedback:
- difficulty
- energy

Sensitive private feedback:
- discomfort flag
- general discomfort area
- note to coach

Private feedback visibility:
- athlete
- current primary coach
- VP
- President

Not visible merely because of organization-wide training access:
- Leader
- Former coach

Push notifications never expose discomfort details.

## Audit

- Application/runtime roles cannot directly mutate audit rows.
- Trusted internal triggers/functions append audit records.
- Update/delete attempts hard-fail.
- Actor may be user, system, cron, or migration.

## Offline

- SQLite outbox is the durable source for unsynchronized workout mutations.
- Mutations carry stable UUID idempotency keys.
- Remove an outbox mutation only after server acknowledgement.
- Replays must be safe against duplicate delivery.
