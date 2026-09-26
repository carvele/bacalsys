# F-S2-03: Sprint 1 permission surfaces do not fail closed for suspended members

- **Class:** ADR, because the fix changes a verbatim baseline function or accepted Sprint 1 surfaces.
  Raised as [ADR-003](../../../adr/ADR-003-fail-closed-permissions-for-inactive-members.md), now **Accepted and
  Implemented** (Option A-revised, Task 2.14).
- **Status:** **Resolved** 2026-09-26 by migration `20260926072909_fail_closed_has_permission.sql`
- **Severity:** High (authorization)
- **Found by:** code review while adding `is_active_member()`, then confirmed by a hosted probe (rolled-back transaction)

**Symptom.** On hosted, a suspended Vice President could still:

- read the approval queue;
- approve a member;
- create an invitation;
- read 167 audit rows.

A suspended Coach could still read 23 member profiles.

**Root cause.** The verbatim `app_private.has_permission()` evaluates active positions only and ignores
`profiles.status`. Every Sprint 1 RPC and policy relies on it.

**What Sprint 2 did.** Every Sprint 2 wrapper, internal function, helper and policy adds `app_private.is_active_member()`.
The same probe shows `assign_primary_coach` rejected (42501) and exercises hidden (0 rows). The pgTAP suites pin this
with a suspended VP, a suspended President, a suspended Coach and a suspended creator (007 #13–15 and #61–63; 008
#39–42 and #62–65).

**What Sprint 2 did not do.** It did not change `has_permission()` or the Sprint 1 surfaces: Sprint 1 is not to be
reopened, and the baseline function is verbatim. Mitigation until ADR-003 is decided: when suspending a member, also
end their positions (`member_positions.ended_at`). The client already holds non-active users at the PendingApproval
screen, but that is UX only.

**Fix (Task 2.14, ADR-003 Option A-revised).** A forward migration replaces two functions:

- `has_permission()`: the position branch now joins `profiles` and requires `status = 'active'`. The system-role
  branch is unchanged, and there is no top-level short-circuit.
- `get_my_access_context()`: returns no positions and no position-derived permissions for non-active callers.
  System-role permissions and `is_system_admin` are still reported.

The mitigation above (ending positions when suspending a member) is no longer needed.

**Regression tests.** These failed first when run without the migration:

- `002_rbac_access_context` #15–26:
  - a suspended VP loses `members:approve` and `audit:view`, and gets an empty context;
  - a suspended or pending System Administrator keeps its system-role permissions and `is_system_admin`;
  - a rejected Coach has no position permissions;
  - a reinstated VP regains authority.
- `005_walking_skeleton_rls` #31–46:
  - a suspended VP gets 42501 on list, approve and invite, sees 0 audit rows, and sees only their own profile and
    positions;
  - a suspended Coach sees only their own profile;
  - a suspended VP who holds an active System Administrator role reads the audit log but still gets 42501 on
    governance;
  - an active President is unchanged.
- `007_coach_assignments` #76–81:
  - a suspended Coach gets an empty context, no `exercises:approve`, and only their own profile;
  - a suspended VP has no `coaches:assign`;
  - an active Coach is unchanged.

**Hosted probe, re-run.** The same rolled-back probe was run before and after the migration.

| Probe | Before | After |
|---|---|---|
| Suspended VP `list_pending_members` | succeeded | 42501 |
| Suspended VP `approve_member` | succeeded (applicant became active) | 42501 (applicant still pending) |
| Suspended VP `create_invitation` | succeeded | 42501 |
| Suspended VP `audit_logs` rows | 171 | 0 |
| Suspended VP profiles visible | 25 | 1 |
| Suspended VP access context | VP + 11 permissions | `[]` / `[]` / false |
| Suspended Coach profiles visible | 25 | 1 |
| Suspended Coach access context | Coach + 4 permissions | `[]` / `[]` / false |
| Suspended Coach + System Administrator: `system_roles:view` / `audit:view` | true / true | true / true |
| Suspended Coach + System Administrator: `skills:verify` (position) | true | false |
| Suspended Coach + System Administrator: context | Coach + 8 permissions, admin | `[]` + 4 system permissions, admin |
