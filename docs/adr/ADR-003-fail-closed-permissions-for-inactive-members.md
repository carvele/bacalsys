# ADR-003: Permissions fail closed for inactive members

- **Status:** Accepted — Implemented (Sprint 2, Task 2.14)
- **Accepted:** 2026-09-26. Option A-revised, reviewer-approved, relayed by the product owner.
- **Implemented:** 2026-09-26 in migration `20260926072909_fail_closed_has_permission.sql` (hosted version
  `20260926073438`)
- **Date:** 2026-09-26
- **Owners:** Executor (Claude) proposes. Planner (Antigravity) decides. Reviewer (ChatGPT) gates.
- **Related ticket:** Sprint 2 finding [F-S2-03](../sprints/sprint-02-membership-exercise/findings/F-S2-03-sprint1-surfaces-not-fail-closed.md)

## Context

Section 9 of the roadmap requires that all organizational operations fail closed for inactive and suspended members.
Every Sprint 2 surface does this through `app_private.is_active_member()`.

A hosted probe on 2026-09-26 found that the Sprint 1 surfaces do **not** fail closed. The probe used a suspended Vice
President, a suspended Coach and one rolled-back transaction:

| Surface (Sprint 1) | Suspended caller | Result |
|---|---|---|
| `public.list_pending_members()` | VP | **succeeded** |
| `public.approve_member()` | VP | **succeeded** |
| `public.create_invitation()` | VP | **succeeded** |
| `audit_logs` SELECT policy | VP | **167 rows visible** |
| `get_my_access_context()` permissions | VP | 11 permissions reported |
| `profiles` SELECT policy (`members:view_all`) | Coach | **23 other profiles visible** |
| `public.assign_primary_coach()` (Sprint 2) | VP | rejected, 42501 |
| `exercises` policies (Sprint 2) | Coach | 0 rows |

Root cause: the verbatim baseline `app_private.has_permission()` (Feature 2.1) checks only active *positions*
(`member_positions.ended_at IS NULL`). It never checks `profiles.status`. Suspending a member without also ending their
positions leaves their permissions live at the API.

The client route guard holds non-active members at the PendingApproval screen, but that is UX only. A suspended user
with a valid JWT can still call PostgREST directly.

## Baseline affected

- Feature 2.1: `app_private.has_permission` and `public.get_my_access_context` are specified verbatim.
- Section 9: "All organizational operations must fail closed for inactive/suspended members."
- Baseline Architecture: "System Administrator is a separate technical/break-glass role independent of club hierarchy/membership."
- Sprint 1 is accepted and tagged, and the instruction for this sprint is not to reopen it.

## Decision

**Option A-revised** is decided. 

The original Option A proposed adding `IF NOT app_private.is_active_member() THEN RETURN false;` at the top of `app_private.has_permission()`. That proposal introduced an architectural conflict: in BaCalSys, the System Administrator is a technical and break-glass role independent of club hierarchy. A blanket top-level check would strip a System Administrator of system authority if their club profile was suspended, pending, or inactive.

Under **Option A-revised**, `app_private.has_permission()` and `public.get_my_access_context()` are updated in a forward migration so that:
1. **Organizational-position permissions require active profile status (`profiles.status = 'active'`).**
2. **System-role permissions evaluate independently of club membership status (`user_system_roles.ended_at IS NULL`).**
3. **No top-level short-circuit** (`IF NOT is_active_member() THEN RETURN false;`) is permitted at the function level.
4. **`public.get_my_access_context()` aligns with this separation**: for an inactive or suspended user holding active system roles, organizational positions report `[]` and position permissions are omitted, but system role permissions and `is_system_admin` remain accurately populated.

### Function implementations

```sql
-- -----------------------------------------------------------------------------
-- app_private.has_permission (Option A-revised)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_private.has_permission(p_permission text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    -- Organizational position permissions: require active membership status
    SELECT 1
    FROM public.member_positions mp
    JOIN public.profiles pr ON pr.id = mp.profile_id
    JOIN public.position_permissions pp ON pp.position_id = mp.position_id
    JOIN public.permissions p ON p.id = pp.permission_id
    WHERE mp.profile_id = v_uid
      AND mp.ended_at IS NULL
      AND pr.status = 'active'
      AND p.name = p_permission
    UNION ALL
    -- System role permissions: technical/break-glass roles independent of club membership status
    SELECT 1
    FROM public.user_system_roles usr
    JOIN public.system_role_permissions srp ON srp.role_id = usr.role_id
    JOIN public.permissions p ON p.id = srp.permission_id
    WHERE usr.user_id = v_uid
      AND usr.ended_at IS NULL
      AND p.name = p_permission
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.has_permission(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.has_permission(text) TO authenticated;

-- -----------------------------------------------------------------------------
-- public.get_my_access_context (Option A-revised)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_access_context()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_active boolean := false;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'Unauthenticated');
  END IF;

  SELECT (status = 'active') INTO v_is_active
  FROM public.profiles
  WHERE id = v_uid;

  v_is_active := COALESCE(v_is_active, false);

  SELECT jsonb_build_object(
    'positions', CASE
      WHEN v_is_active THEN COALESCE((
        SELECT jsonb_agg(pos.name)
        FROM public.member_positions mp
        JOIN public.positions pos ON pos.id = mp.position_id
        WHERE mp.profile_id = v_uid AND mp.ended_at IS NULL
      ), '[]'::jsonb)
      ELSE '[]'::jsonb
    END,
    'permissions', COALESCE((
      SELECT jsonb_agg(DISTINCT perm.name)
      FROM (
        -- Position permissions: active members only
        SELECT p.name
        FROM public.member_positions mp
        JOIN public.position_permissions pp ON pp.position_id = mp.position_id
        JOIN public.permissions p ON p.id = pp.permission_id
        WHERE mp.profile_id = v_uid
          AND mp.ended_at IS NULL
          AND v_is_active
        UNION
        -- System role permissions: independent of membership status
        SELECT p.name
        FROM public.user_system_roles usr
        JOIN public.system_role_permissions srp ON srp.role_id = usr.role_id
        JOIN public.permissions p ON p.id = srp.permission_id
        WHERE usr.user_id = v_uid
          AND usr.ended_at IS NULL
      ) perm
    ), '[]'::jsonb),
    'is_system_admin', EXISTS (
      SELECT 1
      FROM public.user_system_roles usr
      JOIN public.system_roles sr ON sr.id = usr.role_id
      WHERE usr.user_id = v_uid
        AND usr.ended_at IS NULL
        AND sr.name = 'System Administrator'
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_my_access_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_access_context() TO authenticated;
```

## Alternatives considered

### Option A-revised: status-aware organizational permissions, independent system roles (decided)
Pros:
- Enforces fail-closed organizational security across all current and future permission-gated surfaces (Sprint 1 RPCs, RLS policies, Sprint 2 and beyond).
- Preserves technical break-glass authority: System Administrators are not locked out of system-role operations if their club membership profile is suspended or pending.
- Structural enforcement: individual RPCs and policies do not need to repeat defensive status guards to prevent unauthorized organizational governance.
- Cleanly updates `get_my_access_context()` so client UX and server authorization tell the same truth.

Cons:
- Modifies verbatim baseline functions, requiring this ADR and a forward migration.
- Adds an indexed join on `public.profiles` PK in the organizational branch of `has_permission()`.

### Option A (original proposal): top-level `is_active_member()` short-circuit
Pros:
- Very simple check at the start of `has_permission()`.

Cons:
- **Rejected:** Conflicts with the core architectural principle that System Administrator is an independent technical role. If a System Administrator's club profile is suspended or pending, top-level short-circuiting revokes break-glass access (`system_roles:view`, `system_roles:assign`, `audit:view`), breaking recovery capabilities.

### Option B: add `is_active_member()` to each Sprint 1 RPC and policy
Pros:
- Leaves baseline `has_permission()` verbatim.

Cons:
- Highly invasive: touches accepted Sprint 1 surfaces (`approve_member`, `create_invitation`, `list_pending_members`, and RLS policies on `profiles`, `member_positions`, `invitations`, `audit_logs`).
- Fragile: every future permission check must remember to include explicit active status guards.

### Option C: operational rule, where suspension also ends all positions
Pros:
- No schema or function changes.

Cons:
- Fragile and prone to human error; no suspension RPC exists yet to automate it.
- Destroys historical position records unless complex re-grant logic is built for reinstated members.
- Does not address pending members who might be pre-assigned positions prior to approval.

## Consequences

### Positive
- A suspended officer (President, Vice President, Coach) immediately loses all organizational authority (cannot approve members, create invitations, assign coaches, approve exercises, or inspect audit logs and member directories).
- System Administrators retain technical break-glass access even if their club member profile is inactive or pending.
- Consistent fail-closed behavior across all application tiers.

### Negative / tradeoffs
- Existing pgTAP test suites gain assertions covering suspended organizational roles and inactive system administrators.
- Forward migration required.

## Security and privacy impact

- **RLS:** All permission-gated policies (`audit_logs`, `profiles`, `invitations`, `exercises`, `coach_assignments`) fail closed for non-active members regarding organizational club data.
- **Break-glass access:** System Administrator permissions remain functional regardless of club membership profile status.
- **Sensitive data:** Closes audit log and member directory exposure to suspended or pending accounts.
- **Grants:** `REVOKE EXECUTE ... FROM PUBLIC, anon;` and `GRANT EXECUTE ... TO authenticated;` preserved per ADR-002.

## Data / migration impact

- **Schema:** Function replacements only (`app_private.has_permission` and `public.get_my_access_context`), delivered in a forward migration using the repo's Supabase CLI migration pattern.
- **Backfill:** None.
- **Rollback:** Forward migration restoring the previous function definitions.
- **Client compatibility:** None required; the client already treats non-active users as pending.

## Verification plan

### pgTAP Test Matrix (to be added to `supabase/tests/`):
1. **Suspended Vice President:**
   - Calling `public.list_pending_members()` raises SQLSTATE 42501 (insufficient privilege).
   - Calling `public.approve_member(...)` raises SQLSTATE 42501.
   - Calling `public.create_invitation(...)` raises SQLSTATE 42501.
   - `SELECT COUNT(*)` on `public.audit_logs` returns 0.
   - `SELECT COUNT(*)` on `public.profiles` returns 1 (caller's own row only; cannot view directory).
   - `public.get_my_access_context()` returns `positions: []`, `permissions: []`, `is_system_admin: false`.
2. **Suspended Coach:**
   - Calling `public.assign_primary_coach(...)` raises SQLSTATE 42501.
   - `SELECT COUNT(*)` on `public.profiles` returns 1 (caller's own row only).
   - `public.get_my_access_context()` returns `positions: []`, `permissions: []`.
3. **Inactive / Suspended System Administrator (holds active System Administrator role, profile status `suspended` or `pending_approval`):**
   - `app_private.has_permission('system_roles:view')` returns `true`.
   - `app_private.has_permission('members:approve')` returns `false` (cannot perform club governance).
   - `public.get_my_access_context()` returns `positions: []`, `permissions` includes `system_roles:view` (and other system-role permissions), and `is_system_admin: true`.
4. **Active Officer / Active Coach:**
   - All existing tests in `002_rbac_access_context.test.sql`, `005_rls_policies.test.sql`, `006_permission_matrix.test.sql`, `007_coach_assignments.test.sql`, and `008_exercise_library.test.sql` continue to pass without regression.

### Hosted Environment Verification:
- Re-run the hosted test probe against `bacalsys-dev` in a rolled-back transaction verifying:
  - Suspended VP: `list_pending_members()`, `approve_member()`, `create_invitation()` rejected; `audit_logs` returns 0 rows.
  - Suspended Coach: `profiles` returns 1 row (self only).
  - Suspended System Admin: system-role permissions functional; club position permissions rejected.

## Rollback / reversal plan

Forward migration restoring previous function bodies.

## Status note

**Accepted and implemented.** Implementation evidence (2026-09-26):

- Forward migration `supabase/migrations/20260926072909_fail_closed_has_permission.sql` replaces both functions with
  the bodies above. Migration 003 is untouched. Both functions remain `SECURITY DEFINER SET search_path = ''`. Hosted
  ACLs: `has_permission` = postgres and authenticated; `get_my_access_context` = postgres, service_role and
  authenticated. PUBLIC and anon have no EXECUTE on either.
- There is no top-level `is_active_member()` short-circuit. A suspended or pending System Administrator keeps
  `system_roles:view`, `audit:view` and `system:configure`, and `is_system_admin` stays true.
- Regression tests: 002 #15–26, 005 #31–46 and 007 #76–81. The tests failed first without the migration: 002 had
  6 failures; 007 had 4; 005 aborted because the suspended VP's `approve_member` succeeded.
- Offline pgTAP passed 304/304, and hosted pgTAP passed 304/304.
- The hosted F-S2-03 probe was run before and after the migration, rolled back. See Sprint 2 `STATUS.md` §9.

Evidence: [Sprint 2 STATUS.md](../sprints/sprint-02-membership-exercise/STATUS.md) §2.14 and §9.
