# F-S5-02 — `pg_cron` was available but not installed on the hosted project

- **Class:** Backlog Refinement (operational precondition; no change to the frozen design).
- **Severity:** Medium (the frozen migration would have failed loudly, by design, on the first hosted apply).
- **Found during:** Task 5.3, checking hosted extensions before applying.

## Symptom

Section 12 specifies that the scheduling migration "fails loudly if `pg_cron` / `cron.schedule` is unavailable (SQLSTATE `0A000`)". `list_extensions` on `bacalsys-dev` showed `pg_cron` **available (1.6.4) but not installed**, so the migration as literally written would have aborted with `0A000` on a project that can, in fact, run the jobs.

## Decision

The migration keeps the fail-loud guard **unchanged** and, ahead of it, enables the extension *only when the platform offers it but the project hasn't installed it*:

```sql
IF NOT EXISTS (… cron.schedule …) AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
  CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
END IF;
-- (the frozen loud-failure check follows)
```

- Offline (PGlite) the harness supplies a `cron.schedule()` shim, so the branch is skipped and the guard passes.
- On a platform where `pg_cron` is genuinely absent, nothing is created and the frozen `0A000` failure still fires.
- The change is version-controlled in the migration itself (no out-of-band dashboard toggle).

## Consequence for the product owner

Applying the migration installed `pg_cron` 1.6.4 on `bacalsys-dev` and registered the two frozen jobs (`generate-recurring-occurrences` `0 1 * * *`, `mark-missed-workouts` `0 * * * *`). Both run against the dev database from now on; the overdue job will transition any expired fixture occurrences to `missed` hourly (harmless, audited as `cron`). Hosted probe jobs used to prove the service-side races were unscheduled afterwards — `cron.job` holds exactly those two rows.

## Classification note

No ADR: the scheduling architecture (Section 12 "Timezone-Aware Scheduling Engine & pg_cron") is unchanged; this only supplies the extension the frozen design assumes.
