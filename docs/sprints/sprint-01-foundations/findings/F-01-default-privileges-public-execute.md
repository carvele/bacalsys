# F-01: Schema-scoped default-privilege revoke leaves functions executable by anon

- **Class:** ADR ([ADR-002](../../../adr/ADR-002-global-function-execute-revocation.md), accepted 2026-09-25)
- **Found by:** offline pgTAP, `001_security_baseline.test.sql` #6–7
- **Environment:** reproduced on PGlite (PG 18.3); confirmed fixed on Supabase Postgres 17

**Symptom:** the baseline's `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated`
still left new functions callable by `anon`.

**Root cause:** EXECUTE-for-PUBLIC is a *global* built-in default. Per-schema defaults add to it and cannot remove it.

**Fix:** `001` additionally runs a global `ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`.
Regression: tests 001 #6–7.
