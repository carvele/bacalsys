# ADR-002: Global default revocation of function EXECUTE from PUBLIC

- **Status**: Accepted
- **Accepted**: 2026-09-25 by the product owner (Sprint 1 final acceptance review)
- **Date**: 2026-09-25
- **Sprint**: 1 (Task 1.4, DoD #4)
- **Classification**: ADR. The baseline's own SQL does not meet the baseline's stated
  requirement, and the fix widens the scope of a statement the baseline gives verbatim.

## Context

Roadmap v1.2 §1 and Feature 1.2 require that new public functions are **not** executable
by default, and specify this statement:

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
```

The Sprint 1 pgTAP suite (`supabase/tests/001_security_baseline.test.sql`, tests 6–7)
showed that with only this statement, a newly created `public` function **is still
executable by `anon` and `authenticated`**.

The cause is PostgreSQL's documented semantics. EXECUTE-for-PUBLIC on functions is a
*global* built-in default. Per-schema default privileges are *added to* the global
defaults and cannot remove them. The schema-scoped `REVOKE … FROM PUBLIC` therefore
does nothing, and every role keeps EXECUTE through `PUBLIC`.

Reproduced on PostgreSQL 18.3 (PGlite):

| Statements applied | `has_function_privilege('anon', f, 'EXECUTE')` |
|---|---|
| schema-scoped revoke only (baseline) | **true** |
| + `ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` | false |

## Decision

`001_security_baseline.sql` keeps the baseline statement verbatim and adds one global
statement for the migration-owning role:

```sql
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
```

Every intended RPC continues to be granted explicitly, as the baseline already requires.

## Consequences

- DoD #4 is actually enforced. Regression tests 6–7 in `001_security_baseline.test.sql` guard it.
- The revocation applies to functions the migration role creates in **any** schema,
  not just `public`. This is intended for `app_private`. It is safe in general
  because PostgreSQL checks trigger-function EXECUTE only at `CREATE TRIGGER`
  time, and SECURITY DEFINER bodies run as their owner.
- Helpers that RLS policies call (`app_private.has_permission`, `same_organization`,
  `current_organization_id`) must be, and are, granted to `authenticated` explicitly.
- Extension objects created later by the same role (for example pgTAP in the test
  runner) may also lose PUBLIC EXECUTE. Test files therefore grant EXECUTE on the
  `extensions` schema to the roles they impersonate. That grant sits inside the test
  transaction and is rolled back.
- No change to product behavior, the data model, or the RPC surface.

## Rollback / reversal

A new forward migration running `ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;` restores
PostgreSQL's default for functions created afterwards. Existing functions keep their explicit grants.
Rolling back re-opens the gap that `001_security_baseline.test.sql` tests 6–7 detect, so those tests fail by design.
