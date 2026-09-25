# Permission-to-position matrix review

- **Status:** reviewed; the current matrix is pinned by `supabase/tests/006_permission_matrix.test.sql` (19 assertions,
  passing offline and on hosted Supabase). Three decisions are open for the product owner (below).
- **Principle:** seed permissions are part of the authorization model. Any change must edit the golden matrix in test 006.

## Current matrix vs. expected boundaries

| Position / role | Seeded permissions | Expected (product owner) | Verdict |
|---|---|---|---|
| **Athlete** | *(none)* | own profile/training only | ✅ Own-record access comes from ownership predicates (`id = auth.uid()`), not permissions. Test 006 #1; cross-user denial in 005 #15–26. |
| **Leader** | `members:view_all`, `training:view_org` | org training visibility; workout assignment where intended; **no** private feedback | ✅ visibility. ⏳ assignment permission doesn't exist yet (Sprint 5), see D1. ✅ Forward guard: no non-VP/President position may hold a `*private_feedback*` permission (006 #14). Governance denied (006 #15–17). |
| **Coach** | `members:view_all`, `skills:verify` | assigned-athlete permissions; workout assignment; skill verification | ✅ skill verification. By design, "assigned athlete" is **row scope** via `coach_assignments` (Sprint 2, Rule D), not a permission. ⏳ assignment permission is Sprint 5. ⚠️ `members:view_all` gives coaches the whole-org member directory, see D2. |
| **Vice President** | executive set (9) | org-wide training; private feedback; membership approval / role ops | ✅ training + governance. ⏳ Private feedback is Sprint 4 (Rule E): table-level RLS for VP/President, or a VP/President-only permission. Guarded by 006 #14. ⚠️ identical to President, see D3. |
| **President** | executive set (9) | org-wide visibility; governance | ✅ |
| **System Administrator** (system role) | `system:configure`, `system_roles:assign`, `system_roles:view`, `audit:view` | separate technical permissions; not dependent on org position | ✅ Holds no club/training permissions (006 #10), and no club position holds system permissions (006 #9). The access context reports `is_system_admin` from the system role alone (002 #9–10). |

## Decisions for the product owner

- **D1: Workout-assignment permission (Sprint 5).** Which positions get it? Suggested: Coach, VP, President. Leader only
  if Leaders are meant to program workouts. Add it with the Sprint 5 migration and extend test 006.
- **D2: Coach member-directory scope (Sprint 2).** Today `members:view_all` lets a Coach read every member profile and
  position in the organization. That is needed if coaches pick athletes to coach, but broader than "assigned athletes".
  Suggested: keep it for Sprint 2's assignment flow, and scope *training* data strictly through `coach_assignments`.
  If coaches should only see their own athletes' profiles, remove `members:view_all` from Coach and add a
  coach-scope predicate to the profiles policy.
- **D3: VP vs President.** They are currently identical. Is there any President-only governance, such as assigning or ending the
  President/VP positions themselves? If so, add a narrower permission (for example `positions:assign_executive`) so a VP can't
  appoint or remove a President.

## Tests covering the matrix

- `006_permission_matrix.test.sql`: golden matrix (#1–8), Rule A separation (#9–10), executive-only governance and
  audit (#11–12), Rule D org visibility (#13), Rule E forward guard (#14), Leader behavioural denials (#15–17), and a drift
  guard that every permission named in functions and RLS policies exists (#18–19). The drift guard was confirmed to
  fail on a planted typo (`members:aprove`).
- `002_rbac_access_context.test.sql`: exact access contexts, and temporal expiry (an ended position loses its permissions).
