-- =============================================================================
-- 005_rls_policies.sql
-- Roadmap v1.2 · Sprint 1 · Task 1.8 (Feature 11.2)
--
-- Every table has RLS enabled. Grants are explicit and minimal:
--   * anon receives nothing on any BaCalSys table.
--   * authenticated receives SELECT (filtered by policy) and, where a user may
--     edit their own data, column-scoped UPDATE.
--   * Privileged writes (approval, invitations, position/role assignment) are
--     not granted at all; they happen only through public RPC wrappers.
--
-- Policy composition (Feature 11.2): role/permission checks use
-- app_private.has_permission(); row scope uses explicit ownership and
-- organization predicates. auth.uid() is wrapped in (SELECT …) so Postgres
-- evaluates it once per statement instead of once per row.
-- =============================================================================

ALTER TABLE public.organizations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.positions               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.position_permissions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_positions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_roles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_system_roles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invitations             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs              ENABLE ROW LEVEL SECURITY;

-- Belt and braces: whatever default privileges the platform applied, start
-- from zero for the client roles on every Sprint 1 table.
REVOKE ALL ON TABLE
  public.organizations, public.branches, public.profiles, public.permissions,
  public.positions, public.position_permissions, public.member_positions,
  public.system_roles, public.system_role_permissions, public.user_system_roles,
  public.invitations
FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- organizations / branches — visible to members of that organization
-- -----------------------------------------------------------------------------
GRANT SELECT ON TABLE public.organizations, public.branches TO authenticated;

CREATE POLICY organizations_select_own ON public.organizations
FOR SELECT TO authenticated
USING (id = (SELECT app_private.current_organization_id()));

CREATE POLICY branches_select_own_org ON public.branches
FOR SELECT TO authenticated
USING (organization_id = (SELECT app_private.current_organization_id()));

-- -----------------------------------------------------------------------------
-- RBAC catalogs — non-sensitive reference data, readable when signed in
-- -----------------------------------------------------------------------------
GRANT SELECT ON TABLE
  public.permissions, public.positions, public.position_permissions,
  public.system_roles, public.system_role_permissions
TO authenticated;

CREATE POLICY permissions_select ON public.permissions
FOR SELECT TO authenticated USING (true);

CREATE POLICY positions_select ON public.positions
FOR SELECT TO authenticated USING (true);

CREATE POLICY position_permissions_select ON public.position_permissions
FOR SELECT TO authenticated USING (true);

CREATE POLICY system_roles_select ON public.system_roles
FOR SELECT TO authenticated USING (true);

CREATE POLICY system_role_permissions_select ON public.system_role_permissions
FOR SELECT TO authenticated USING (true);

-- -----------------------------------------------------------------------------
-- profiles — protected member record
--   read:   self, or members:view_all within the same organization
--   update: self only, and only full_name / avatar_url (column grant).
--           status and home_branch_id change only through officer RPCs.
-- -----------------------------------------------------------------------------
GRANT SELECT ON TABLE public.profiles TO authenticated;
GRANT UPDATE (full_name, avatar_url) ON TABLE public.profiles TO authenticated;

CREATE POLICY profiles_select ON public.profiles
FOR SELECT TO authenticated
USING (
  id = (SELECT auth.uid())
  OR (
    (SELECT app_private.has_permission('members:view_all'))
    AND app_private.same_organization(id)
  )
);

CREATE POLICY profiles_update_self ON public.profiles
FOR UPDATE TO authenticated
USING (id = (SELECT auth.uid()))
WITH CHECK (id = (SELECT auth.uid()));

-- -----------------------------------------------------------------------------
-- member_positions — read-only to clients; written by approval / assignment RPCs
-- -----------------------------------------------------------------------------
GRANT SELECT ON TABLE public.member_positions TO authenticated;

CREATE POLICY member_positions_select ON public.member_positions
FOR SELECT TO authenticated
USING (
  profile_id = (SELECT auth.uid())
  OR (
    (SELECT app_private.has_permission('members:view_all'))
    AND app_private.same_organization(profile_id)
  )
);

-- -----------------------------------------------------------------------------
-- user_system_roles — read-only; self or holders of system_roles:view
-- -----------------------------------------------------------------------------
GRANT SELECT ON TABLE public.user_system_roles TO authenticated;

CREATE POLICY user_system_roles_select ON public.user_system_roles
FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR (SELECT app_private.has_permission('system_roles:view'))
);

-- -----------------------------------------------------------------------------
-- invitations — inviters in the same organization; token_hash never readable
-- -----------------------------------------------------------------------------
GRANT SELECT (
  id, email, preassigned_position_id, created_by, created_at, expires_at, claimed_at, claimed_by
) ON TABLE public.invitations TO authenticated;

CREATE POLICY invitations_select ON public.invitations
FOR SELECT TO authenticated
USING (
  created_by = (SELECT auth.uid())
  OR (
    (SELECT app_private.has_permission('members:invite'))
    AND app_private.same_organization(created_by)
  )
);

-- -----------------------------------------------------------------------------
-- audit_logs — readable only with audit:view (mutation grants revoked in 004)
-- -----------------------------------------------------------------------------
CREATE POLICY audit_logs_select ON public.audit_logs
FOR SELECT TO authenticated
USING ((SELECT app_private.has_permission('audit:view')));
