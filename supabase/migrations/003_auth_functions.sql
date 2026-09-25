-- =============================================================================
-- 003_auth_functions.sql
-- Roadmap v1.2 · Sprint 1 · Task 1.6
--
-- Pattern (Roadmap §1 "Public RPC Pattern"):
--   public.<rpc>()              SECURITY DEFINER wrapper. Authenticates and
--                               authorizes the caller, then delegates.
--   app_private.<rpc>_internal  Implementation. Never granted to API roles.
--
-- Every SECURITY DEFINER function pins `search_path = ''` and schema-qualifies
-- all references.
-- Errors use SQLSTATE 42501 (insufficient_privilege) for authorization failures
-- so clients can distinguish them from validation errors.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app_private.has_permission (verbatim from Roadmap v1.2 Feature 2.1)
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.has_permission(p_permission text)
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
    -- Position permissions
    SELECT 1
    FROM public.member_positions mp
    JOIN public.position_permissions pp ON pp.position_id = mp.position_id
    JOIN public.permissions p ON p.id = pp.permission_id
    WHERE mp.profile_id = v_uid AND mp.ended_at IS NULL AND p.name = p_permission
    UNION ALL
    -- System role permissions
    SELECT 1
    FROM public.user_system_roles usr
    JOIN public.system_role_permissions srp ON srp.role_id = usr.role_id
    JOIN public.permissions p ON p.id = srp.permission_id
    WHERE usr.user_id = v_uid AND usr.ended_at IS NULL AND p.name = p_permission
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.has_permission(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.has_permission(text) TO authenticated;

-- -----------------------------------------------------------------------------
-- public.get_my_access_context (verbatim from Roadmap v1.2 Feature 2.1)
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.get_my_access_context()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'Unauthenticated');
  END IF;

  SELECT jsonb_build_object(
    'positions', COALESCE((
      SELECT jsonb_agg(pos.name)
      FROM public.member_positions mp
      JOIN public.positions pos ON pos.id = mp.position_id
      WHERE mp.profile_id = v_uid AND mp.ended_at IS NULL
    ), '[]'::jsonb),
    'permissions', COALESCE((
      SELECT jsonb_agg(DISTINCT perm.name)
      FROM (
        SELECT p.name
        FROM public.member_positions mp
        JOIN public.position_permissions pp ON pp.position_id = mp.position_id
        JOIN public.permissions p ON p.id = pp.permission_id
        WHERE mp.profile_id = v_uid AND mp.ended_at IS NULL
        UNION
        SELECT p.name
        FROM public.user_system_roles usr
        JOIN public.system_role_permissions srp ON srp.role_id = usr.role_id
        JOIN public.permissions p ON p.id = srp.permission_id
        WHERE usr.user_id = v_uid AND usr.ended_at IS NULL
      ) perm
    ), '[]'::jsonb),
    'is_system_admin', EXISTS (
      SELECT 1
      FROM public.user_system_roles usr
      JOIN public.system_roles sr ON sr.id = usr.role_id
      WHERE usr.user_id = v_uid AND usr.ended_at IS NULL AND sr.name = 'System Administrator'
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_my_access_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_access_context() TO authenticated;

-- -----------------------------------------------------------------------------
-- Organization scope helpers (Rule F: scope derives from profiles.home_branch_id)
-- SECURITY DEFINER so RLS policies on profiles can call them without recursing
-- into the profiles policy itself.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.organization_of(p_profile_id uuid)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT b.organization_id
  FROM public.profiles p
  JOIN public.branches b ON b.id = p.home_branch_id
  WHERE p.id = p_profile_id;
$$;
REVOKE EXECUTE ON FUNCTION app_private.organization_of(uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app_private.current_organization_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.organization_of(auth.uid());
$$;
REVOKE EXECUTE ON FUNCTION app_private.current_organization_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.current_organization_id() TO authenticated;

-- True only when both the caller and the target belong to the same, known organization.
CREATE FUNCTION app_private.same_organization(p_profile_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT COALESCE(
    app_private.organization_of(auth.uid()) = app_private.organization_of(p_profile_id),
    false
  );
$$;
REVOKE EXECUTE ON FUNCTION app_private.same_organization(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.same_organization(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- Invitation token hashing
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.hash_invitation_token(p_token text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path = ''
AS $$
  SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
$$;
REVOKE EXECUTE ON FUNCTION app_private.hash_invitation_token(text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Registration: auth.users → public.profiles (status = pending_approval)
--
-- If the signup metadata carries `invite_token`, the matching invitation is
-- claimed atomically (single use, unexpired, e-mail must match). A claimed
-- invitation counts as officer pre-approval: the profile becomes active and
-- receives the invitation's pre-assigned position, defaulting to Athlete.
-- An invalid token never blocks signup; the user simply lands in the normal
-- pending-approval queue.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_full_name  text := left(btrim(COALESCE(NEW.raw_user_meta_data ->> 'full_name', '')), 120);
  v_branch_id  uuid;
  v_token      text := NULLIF(btrim(COALESCE(NEW.raw_user_meta_data ->> 'invite_token', '')), '');
  v_invitation public.invitations%ROWTYPE;
BEGIN
  -- Single-organization deployment: new members join the default branch.
  SELECT b.id INTO v_branch_id
  FROM public.branches b
  WHERE b.is_default
  ORDER BY b.created_at
  LIMIT 1;

  INSERT INTO public.profiles (id, full_name, status, home_branch_id)
  VALUES (NEW.id, v_full_name, 'pending_approval', v_branch_id);

  IF v_token IS NOT NULL THEN
    UPDATE public.invitations i
       SET claimed_at = now(),
           claimed_by = NEW.id
     WHERE i.token_hash = app_private.hash_invitation_token(v_token)
       AND i.claimed_at IS NULL
       AND i.expires_at > now()
       AND i.email = lower(btrim(NEW.email))
    RETURNING i.* INTO v_invitation;

    IF FOUND THEN
      UPDATE public.profiles SET status = 'active' WHERE id = NEW.id;

      INSERT INTO public.member_positions (profile_id, position_id, assigned_by)
      VALUES (
        NEW.id,
        COALESCE(
          v_invitation.preassigned_position_id,
          (SELECT pos.id FROM public.positions pos WHERE pos.name = 'Athlete')
        ),
        v_invitation.created_by
      );
    END IF;

    -- Hygiene: drop the raw token from user metadata. It is already single-use,
    -- so if the platform ever denies this UPDATE, warn instead of failing signup.
    BEGIN
      UPDATE auth.users
         SET raw_user_meta_data = raw_user_meta_data - 'invite_token'
       WHERE id = NEW.id;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE WARNING 'handle_new_user: could not strip invite_token from auth.users metadata';
    END;
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.handle_new_user() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION app_private.handle_new_user();

-- -----------------------------------------------------------------------------
-- Invitations: create (returns the raw token exactly once)
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.create_invitation_internal(
  p_actor_id uuid,
  p_email text,
  p_preassigned_position_id uuid,
  p_expires_in_hours integer
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_email  text := lower(btrim(COALESCE(p_email, '')));
  v_token  text;
  v_row    public.invitations%ROWTYPE;
BEGIN
  IF v_email NOT LIKE '%_@_%' THEN
    RAISE EXCEPTION 'A valid e-mail address is required' USING ERRCODE = '22023';
  END IF;
  IF p_expires_in_hours IS NULL OR p_expires_in_hours NOT BETWEEN 1 AND 720 THEN
    RAISE EXCEPTION 'Invitation lifetime must be between 1 and 720 hours' USING ERRCODE = '22023';
  END IF;

  -- 256 bits of CSPRNG entropy; only the digest is stored.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO public.invitations (token_hash, email, preassigned_position_id, created_by, expires_at)
  VALUES (
    app_private.hash_invitation_token(v_token),
    v_email,
    p_preassigned_position_id,
    p_actor_id,
    now() + make_interval(hours => p_expires_in_hours)
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'invitation_id', v_row.id,
    'email', v_row.email,
    'token', v_token,
    'expires_at', v_row.expires_at
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.create_invitation_internal(uuid, text, uuid, integer)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.create_invitation(
  p_email text,
  p_preassigned_position_id uuid DEFAULT NULL,
  p_expires_in_hours integer DEFAULT 168
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT app_private.has_permission('members:invite') THEN
    RAISE EXCEPTION 'Not authorized to invite members' USING ERRCODE = '42501';
  END IF;

  -- Feature 1.3: invitees default to Athlete unless the inviter may pre-assign.
  IF p_preassigned_position_id IS NOT NULL
     AND p_preassigned_position_id IS DISTINCT FROM (SELECT id FROM public.positions WHERE name = 'Athlete')
     AND NOT app_private.has_permission('members:preassign_position') THEN
    RAISE EXCEPTION 'Not authorized to pre-assign positions' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.create_invitation_internal(v_uid, p_email, p_preassigned_position_id, p_expires_in_hours);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.create_invitation(text, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_invitation(text, uuid, integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- Member approval queue
-- E-mail lives in auth.users (not duplicated onto profiles), so the queue is
-- served by a wrapper that joins it for authorized officers only.
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.list_pending_members()
RETURNS TABLE (
  id              uuid,
  full_name       text,
  email           text,
  home_branch_id  uuid,
  branch_name     text,
  created_at      timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.has_permission('members:approve') THEN
    RAISE EXCEPTION 'Not authorized to review member applications' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT p.id, p.full_name, u.email::text, p.home_branch_id, b.name, p.created_at
  FROM public.profiles p
  JOIN auth.users u ON u.id = p.id
  LEFT JOIN public.branches b ON b.id = p.home_branch_id
  WHERE p.status = 'pending_approval'
    AND app_private.same_organization(p.id)
  ORDER BY p.created_at;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.list_pending_members() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_pending_members() TO authenticated;

-- -----------------------------------------------------------------------------
-- Member approval: pending → active + Athlete position, in one transaction
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.approve_member_internal(p_actor_id uuid, p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_status       public.member_status;
  v_position_id  uuid;
  v_assignment   public.member_positions%ROWTYPE;
BEGIN
  -- Row lock serializes concurrent approvals of the same applicant.
  SELECT p.status INTO v_status
  FROM public.profiles p
  WHERE p.id = p_profile_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Member not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_status <> 'pending_approval' THEN
    RAISE EXCEPTION 'Member is not pending approval (current status: %)', v_status
      USING ERRCODE = '55000';
  END IF;
  IF app_private.organization_of(p_actor_id) IS DISTINCT FROM app_private.organization_of(p_profile_id)
     OR app_private.organization_of(p_actor_id) IS NULL THEN
    RAISE EXCEPTION 'Member belongs to a different organization' USING ERRCODE = '42501';
  END IF;

  SELECT pos.id INTO STRICT v_position_id FROM public.positions pos WHERE pos.name = 'Athlete';

  UPDATE public.profiles SET status = 'active' WHERE id = p_profile_id;

  INSERT INTO public.member_positions (profile_id, position_id, assigned_by)
  VALUES (p_profile_id, v_position_id, p_actor_id)
  RETURNING * INTO v_assignment;

  RETURN jsonb_build_object(
    'profile_id', p_profile_id,
    'status', 'active',
    'position', 'Athlete',
    'member_position_id', v_assignment.id,
    'assigned_at', v_assignment.assigned_at,
    'assigned_by', v_assignment.assigned_by
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.approve_member_internal(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.approve_member(p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT app_private.has_permission('members:approve') THEN
    RAISE EXCEPTION 'Not authorized to approve members' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.approve_member_internal(v_uid, p_profile_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.approve_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_member(uuid) TO authenticated;
