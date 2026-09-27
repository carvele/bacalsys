-- =============================================================================
-- workout_visibility_metadata_rpcs
-- Roadmap v1.2 · Sprint 3 · Task 3.9 (Section 10, Decision D5)
--
--   public.set_template_visibility(template, visibility)
--   public.update_workout_template_metadata(template, name, description)
--   public.set_workout_template_archived(template, is_archived)
--
-- each a SECURITY INVOKER wrapper over an app_private.*_internal SECURITY DEFINER
-- function that locks the template row FOR UPDATE.
--
-- Visibility transition matrix (D5):
--   private → organization  ONLY the creator (workouts:manage_org never authorizes
--                           touching someone else's private routine), AND the
--                           template is homed in the caller's CURRENT organization
--                           (an existing template is never silently re-homed: clone
--                           first), AND workouts:publish_org, AND every exercise in
--                           every version is approved/official.
--   organization → private  same current organization AND
--                           ((creator AND workouts:publish_org) OR workouts:manage_org).
-- Metadata/archive follow can_mutate_workout_template (private: creator, even after
-- moving organizations; organization: same current organization + publish/manage).
-- Every path fails closed when the caller has no organization context (org paths).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- set_template_visibility
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.set_template_visibility_internal(p_template_id uuid, p_visibility text)
RETURNS public.workout_templates
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
  v_template public.workout_templates%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_template FROM public.workout_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout template not found' USING ERRCODE = 'P0002';
  END IF;

  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NULL THEN
    RAISE EXCEPTION 'Active organization context required' USING ERRCODE = '42501';
  END IF;

  IF p_visibility IS NULL OR p_visibility NOT IN ('private', 'organization') THEN
    RAISE EXCEPTION 'visibility must be private or organization' USING ERRCODE = '22023';
  END IF;

  IF v_template.visibility = 'private' THEN
    IF v_template.created_by <> v_uid THEN
      RAISE EXCEPTION 'Only the creator can change the visibility of a private routine' USING ERRCODE = '42501';
    END IF;
    IF p_visibility = 'private' THEN
      RAISE EXCEPTION 'The routine is already private (nothing to change)' USING ERRCODE = '55000';
    END IF;

    -- Promotion private → organization
    IF v_template.organization_id IS DISTINCT FROM v_current_org THEN
      RAISE EXCEPTION 'This routine belongs to a previous organization: clone it first, then publish the clone'
        USING ERRCODE = '42501';
    END IF;
    IF NOT app_private.has_permission('workouts:publish_org') THEN
      RAISE EXCEPTION 'You do not have permission to publish routines to the organization' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.workout_versions v
      JOIN public.workout_blocks b ON b.workout_version_id = v.id
      JOIN public.workout_items i ON i.block_id = b.id
      JOIN public.exercises e ON e.id = i.exercise_id
      WHERE v.template_id = p_template_id
        AND NOT (e.status = 'approved' AND e.is_official)
    ) THEN
      RAISE EXCEPTION 'Every exercise in every version must be an approved library exercise before publishing to the organization'
        USING ERRCODE = '22023';
    END IF;
  ELSE
    -- Current visibility = organization: same current organization plus publish/manage authority.
    IF NOT app_private.can_mutate_workout_template(v_template) THEN
      RAISE EXCEPTION 'You do not have permission to change the visibility of this routine' USING ERRCODE = '42501';
    END IF;
    IF p_visibility = 'organization' THEN
      RAISE EXCEPTION 'The routine is already visible to the organization (nothing to change)' USING ERRCODE = '55000';
    END IF;
  END IF;

  UPDATE public.workout_templates
  SET visibility = p_visibility, updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_template;

  PERFORM app_private.write_audit_event(
    'visibility_changed', 'workout_template', p_template_id::text,
    jsonb_build_object('visibility', CASE p_visibility WHEN 'organization' THEN 'private' ELSE 'organization' END),
    jsonb_build_object('visibility', p_visibility)
  );

  RETURN v_template;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.set_template_visibility_internal(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.set_template_visibility_internal(uuid, text) TO authenticated;

CREATE FUNCTION public.set_template_visibility(p_template_id uuid, p_visibility text)
RETURNS public.workout_templates
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.set_template_visibility_internal(p_template_id, p_visibility);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_template_visibility(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_template_visibility(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- update_workout_template_metadata
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.update_workout_template_metadata_internal(
  p_template_id uuid, p_name text, p_description text
)
RETURNS public.workout_templates
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_template public.workout_templates%ROWTYPE;
  v_old public.workout_templates%ROWTYPE;
  v_name text := btrim(COALESCE(p_name, ''));
  v_description text := nullif(btrim(COALESCE(p_description, '')), '');
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_template FROM public.workout_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout template not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT app_private.can_mutate_workout_template(v_template) THEN
    RAISE EXCEPTION 'You do not have permission to edit this routine' USING ERRCODE = '42501';
  END IF;

  IF v_name = '' OR length(v_name) > 100 THEN
    RAISE EXCEPTION 'A routine name of 1 to 100 characters is required' USING ERRCODE = '22023';
  END IF;
  IF v_description IS NOT NULL AND length(v_description) > 1000 THEN
    RAISE EXCEPTION 'The description can be at most 1000 characters' USING ERRCODE = '22023';
  END IF;

  v_old := v_template;
  UPDATE public.workout_templates
  SET name = v_name, description = v_description
  WHERE id = p_template_id
  RETURNING * INTO v_template;

  PERFORM app_private.write_audit_event(
    'metadata_updated', 'workout_template', p_template_id::text,
    jsonb_build_object('name', v_old.name, 'description', v_old.description),
    jsonb_build_object('name', v_template.name, 'description', v_template.description)
  );

  RETURN v_template;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.update_workout_template_metadata_internal(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.update_workout_template_metadata_internal(uuid, text, text) TO authenticated;

CREATE FUNCTION public.update_workout_template_metadata(p_template_id uuid, p_name text, p_description text)
RETURNS public.workout_templates
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.update_workout_template_metadata_internal(p_template_id, p_name, p_description);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.update_workout_template_metadata(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_workout_template_metadata(uuid, text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- set_workout_template_archived
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.set_workout_template_archived_internal(p_template_id uuid, p_is_archived boolean)
RETURNS public.workout_templates
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_template public.workout_templates%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  IF p_is_archived IS NULL THEN
    RAISE EXCEPTION 'is_archived must be true or false' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_template FROM public.workout_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout template not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT app_private.can_mutate_workout_template(v_template) THEN
    RAISE EXCEPTION 'You do not have permission to archive this routine' USING ERRCODE = '42501';
  END IF;

  -- Idempotent: repeating the current state writes nothing.
  IF v_template.is_archived = p_is_archived THEN
    RETURN v_template;
  END IF;

  UPDATE public.workout_templates
  SET is_archived = p_is_archived
  WHERE id = p_template_id
  RETURNING * INTO v_template;

  PERFORM app_private.write_audit_event(
    CASE WHEN p_is_archived THEN 'archived' ELSE 'unarchived' END,
    'workout_template', p_template_id::text,
    jsonb_build_object('is_archived', NOT p_is_archived),
    jsonb_build_object('is_archived', p_is_archived)
  );

  RETURN v_template;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.set_workout_template_archived_internal(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.set_workout_template_archived_internal(uuid, boolean) TO authenticated;

CREATE FUNCTION public.set_workout_template_archived(p_template_id uuid, p_is_archived boolean)
RETURNS public.workout_templates
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.set_workout_template_archived_internal(p_template_id, p_is_archived);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_workout_template_archived(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_workout_template_archived(uuid, boolean) TO authenticated;
