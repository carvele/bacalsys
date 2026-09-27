-- =============================================================================
-- workout_clone_rpc
-- Roadmap v1.2 · Sprint 3 · Task 3.8 (Feature 4.2, Section 10)
--
--   public.clone_workout_template(p_template_id, p_new_name)   SECURITY INVOKER wrapper
--     → app_private.clone_workout_template_internal(source, name, target_user)
--
-- Deep-copies the LATEST SEALED version of a routine the caller can read into a
-- new PRIVATE template owned by the caller, homed in the caller's CURRENT
-- organization (this is how a member who moved organizations re-homes an old
-- routine: an existing template is never silently re-homed). The clone is
-- version 1 of a new template.
--
-- Serialization: the source template row is locked FOR SHARE, which conflicts
-- with publish_new_workout_version's FOR UPDATE, so a clone always copies a
-- complete latest version — either the one before or the one after a racing
-- publish — never a partial one.
--
-- Safety: every exercise in the copied version must be usable by the new owner
-- (approved/official, or created by them). A routine that references another
-- member's private exercise is rejected atomically with 42501.
-- =============================================================================

CREATE FUNCTION app_private.clone_workout_template_internal(
  p_source_template_id uuid, p_new_name text, p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
  v_src public.workout_templates%ROWTYPE;
  v_src_version public.workout_versions%ROWTYPE;
  v_name text;
  v_template_id uuid;
  v_version_id uuid;
  v_block public.workout_blocks%ROWTYPE;
  v_item public.workout_items%ROWTYPE;
  v_block_id uuid;
  v_item_id uuid;
  v_n_blocks integer := 0;
  v_n_items integer := 0;
  v_n_sets integer := 0;
  v_added integer;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  IF p_target_user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'A routine can only be cloned into your own library' USING ERRCODE = '42501';
  END IF;

  -- Serialization point against concurrent publishes.
  SELECT * INTO v_src FROM public.workout_templates WHERE id = p_source_template_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout template not found' USING ERRCODE = 'P0002';
  END IF;

  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NULL THEN
    RAISE EXCEPTION 'Active organization context required' USING ERRCODE = '42501';
  END IF;

  IF NOT app_private.can_view_workout_template(p_source_template_id) THEN
    RAISE EXCEPTION 'You do not have permission to clone this routine' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_src_version
  FROM public.workout_versions
  WHERE template_id = p_source_template_id AND is_sealed = true
  ORDER BY version_number DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This routine has no published version to clone' USING ERRCODE = '55000';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.workout_blocks b
    JOIN public.workout_items i ON i.block_id = b.id
    JOIN public.exercises e ON e.id = i.exercise_id
    WHERE b.workout_version_id = v_src_version.id
      AND NOT ((e.status = 'approved' AND e.is_official) OR e.created_by = p_target_user_id)
  ) THEN
    RAISE EXCEPTION 'This routine uses a private exercise you cannot use, so it cannot be cloned'
      USING ERRCODE = '42501';
  END IF;

  v_name := nullif(btrim(COALESCE(p_new_name, '')), '');
  IF v_name IS NULL THEN
    v_name := left(v_src.name, 93) || ' (copy)';
  ELSIF length(v_name) > 100 THEN
    RAISE EXCEPTION 'A routine name of 1 to 100 characters is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.workout_templates (organization_id, name, description, visibility, created_by)
  VALUES (v_current_org, v_name, v_src.description, 'private', p_target_user_id)
  RETURNING id INTO v_template_id;

  INSERT INTO public.workout_versions (template_id, version_number, notes, created_by, is_sealed)
  VALUES (
    v_template_id, 1,
    left(format('Cloned from "%s" version %s', v_src.name, v_src_version.version_number), 1000),
    p_target_user_id, false
  )
  RETURNING id INTO v_version_id;

  FOR v_block IN
    SELECT * FROM public.workout_blocks WHERE workout_version_id = v_src_version.id ORDER BY order_in_workout
  LOOP
    INSERT INTO public.workout_blocks
      (workout_version_id, order_in_workout, title, block_type, circuit_rounds, amrap_duration_seconds, notes)
    VALUES
      (v_version_id, v_block.order_in_workout, v_block.title, v_block.block_type,
       v_block.circuit_rounds, v_block.amrap_duration_seconds, v_block.notes)
    RETURNING id INTO v_block_id;
    v_n_blocks := v_n_blocks + 1;

    FOR v_item IN
      SELECT * FROM public.workout_items WHERE block_id = v_block.id ORDER BY order_in_block
    LOOP
      INSERT INTO public.workout_items (block_id, exercise_id, order_in_block, measurement_mode, notes)
      VALUES (v_block_id, v_item.exercise_id, v_item.order_in_block, v_item.measurement_mode, v_item.notes)
      RETURNING id INTO v_item_id;
      v_n_items := v_n_items + 1;

      INSERT INTO public.workout_item_sets
        (workout_item_id, set_number, target_reps, target_duration_seconds, target_distance_meters,
         target_load_kg, load_type, target_rest_seconds, target_rpe, notes)
      SELECT v_item_id, s.set_number, s.target_reps, s.target_duration_seconds, s.target_distance_meters,
             s.target_load_kg, s.load_type, s.target_rest_seconds, s.target_rpe, s.notes
      FROM public.workout_item_sets s
      WHERE s.workout_item_id = v_item.id
      ORDER BY s.set_number;
      GET DIAGNOSTICS v_added = ROW_COUNT;
      v_n_sets := v_n_sets + v_added;
    END LOOP;
  END LOOP;

  PERFORM app_private.seal_workout_version(v_version_id);

  PERFORM app_private.write_audit_event(
    'cloned', 'workout_template', v_template_id::text, NULL,
    jsonb_build_object(
      'source_template_id', p_source_template_id,
      'source_version_id', v_src_version.id,
      'source_version_number', v_src_version.version_number,
      'version_id', v_version_id, 'organization_id', v_current_org,
      'blocks', v_n_blocks, 'items', v_n_items, 'sets', v_n_sets
    )
  );

  RETURN jsonb_build_object(
    'template_id', v_template_id, 'version_id', v_version_id, 'version_number', 1,
    'source_version_number', v_src_version.version_number
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.clone_workout_template_internal(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.clone_workout_template_internal(uuid, text, uuid) TO authenticated;

CREATE FUNCTION public.clone_workout_template(p_template_id uuid, p_new_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.clone_workout_template_internal(p_template_id, p_new_name, auth.uid());
END;
$$;
REVOKE EXECUTE ON FUNCTION public.clone_workout_template(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clone_workout_template(uuid, text) TO authenticated;
