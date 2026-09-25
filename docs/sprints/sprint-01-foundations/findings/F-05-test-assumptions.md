# F-05: Two over-specified tests (collation order, empty table)

- **Class:** Test bugs (no product change)
- **Found by:** real pgTAP on hosted Supabase

1. `002_rbac_access_context.test.sql` compared the permissions array *in order*. `jsonb_agg(DISTINCT …)` inside the
   verbatim `get_my_access_context()` orders by database collation (locale on Supabase, C on PGlite).
   Order carries no meaning, and the client uses `includes()`. Fixed by comparing as a set. The RPC is untouched.
2. `003_registration_invitations.test.sql` counted *all* visible invitations, assuming an empty table. Fixed by scoping
   the count to the test's own fixture.

**Lesson:** suites must be environment-independent, i.e. not depend on collation or pre-existing data.
