-- =============================================================================
-- fail_closed_has_permission
-- Roadmap v1.2 · Sprint 2 · Task 2.14 — ADR-003 Option A-revised (F-S2-03)
--
-- Forward replacement of the two Feature 2.1 functions from
-- 003_auth_functions.sql (that migration is not edited):
--
--   app_private.has_permission(text)
--     · organizational-position branch requires profiles.status = 'active';
--     · system-role branch stays independent of club membership status
--       (System Administrator is a technical / break-glass role).
--     · deliberately NO top-level is_active_member() short-circuit.
--
--   public.get_my_access_context()
--     · non-active callers report positions = [] and no position-derived
--       permissions; active system roles still report their permissions and
--       is_system_admin.
--
-- CREATE OR REPLACE keeps owner, SECURITY DEFINER and existing grants; the
-- REVOKE / GRANT statements below restate them explicitly (ADR-002).
-- Rollback: a forward migration restoring the 003 bodies.
-- =============================================================================

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

  SELECT (pr.status = 'active') INTO v_is_active
  FROM public.profiles pr
  WHERE pr.id = v_uid;

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
