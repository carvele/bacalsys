# F-S2-01: RESTRICT violations report different SQLSTATEs on PostgreSQL 17 and 18

- **Class:** Bug (test assumption only, no product change)
- **Found by:** running `007_coach_assignments.test.sql` on hosted Supabase

**Symptom.** Two assertions ("deleting the athlete's account / a former coach's profile is blocked") expected SQLSTATE
23001 and passed offline, but failed on hosted with 23503.

**Root cause.** The offline harness is PGlite, which is PostgreSQL **18.3**. `bacalsys-dev` runs PostgreSQL **17.6**.
PostgreSQL 18 reports an `ON DELETE RESTRICT` violation as `23001 restrict_violation`. PostgreSQL 17 and earlier report
`23503 foreign_key_violation`. In both versions the delete is blocked and coaching history is preserved.

**Fix.** The assertions now check that the delete is rejected with either code, using a `pg_temp.sqlstate_of()` helper.
The schema is unchanged.

**Regression test.** Assertions 56–57 in `007_coach_assignments.test.sql` pass on both engines: offline 76/76, hosted
76/76.

**Lesson.** The offline and hosted engines differ by a major version. Treat engine-specific SQLSTATEs as a parity risk,
and keep running the hosted pgTAP pass.
