-- =============================================================================
-- workout_publish_version_rpc
-- Roadmap v1.2 · Sprint 3 · Task 3.7 (Section 10, Rule C)
--
--   public.publish_new_workout_version(...)            SECURITY INVOKER wrapper
--     → app_private.publish_new_workout_version_internal   SECURITY DEFINER
--
-- Publishing never edits an existing version: it appends version N+1, sealed.
-- The parent template row is locked FOR UPDATE first, so concurrent publishes
-- (and publish-vs-clone, which takes FOR SHARE) are serialized and version
-- numbers are sequential without ever tripping uq_workout_version.
--
-- Rule C UI timing: the changelog is p_version_notes. Which assignments adopt
-- the new version is a Sprint 5 concern (no assignments exist yet); nothing here
-- can migrate an existing session or assignment.
-- =============================================================================

CREATE FUNCTION app_private.publish_new_workout_version_internal(
  p_template_id uuid, p_version_notes text, p_blocks jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_template public.workout_templates%ROWTYPE;
  v_notes text := nullif(btrim(COALESCE(p_version_notes, '')), '');
  v_next integer;
  v_version_id uuid;
  v_counts jsonb;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  -- Serialization point.
  SELECT * INTO v_template FROM public.workout_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout template not found' USING ERRCODE = 'P0002';
  END IF;

  -- Current temporal authority: private → creator (even across organizations);
  -- organization → same current organization AND publish_org (creator) or manage_org.
  IF NOT app_private.can_mutate_workout_template(v_template) THEN
    RAISE EXCEPTION 'You do not have permission to publish a new version of this routine' USING ERRCODE = '42501';
  END IF;

  IF v_notes IS NOT NULL AND length(v_notes) > 1000 THEN
    RAISE EXCEPTION 'Version notes can be at most 1000 characters' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(max(version_number), 0) + 1 INTO v_next
  FROM public.workout_versions WHERE template_id = p_template_id;

  INSERT INTO public.workout_versions (template_id, version_number, notes, created_by, is_sealed)
  VALUES (p_template_id, v_next, v_notes, v_uid, false)
  RETURNING id INTO v_version_id;

  v_counts := app_private.build_workout_version(
    v_version_id, p_blocks, v_uid, v_template.visibility = 'organization'
  );
  PERFORM app_private.seal_workout_version(v_version_id);

  UPDATE public.workout_templates SET updated_at = now() WHERE id = p_template_id;

  PERFORM app_private.write_audit_event(
    'version_published', 'workout_template', p_template_id::text, NULL,
    jsonb_build_object('version_id', v_version_id, 'version_number', v_next, 'visibility', v_template.visibility) || v_counts
  );

  RETURN jsonb_build_object('template_id', p_template_id, 'version_id', v_version_id, 'version_number', v_next);
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.publish_new_workout_version_internal(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.publish_new_workout_version_internal(uuid, text, jsonb) TO authenticated;

CREATE FUNCTION public.publish_new_workout_version(
  p_template_id uuid, p_version_notes text, p_blocks jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.publish_new_workout_version_internal(p_template_id, p_version_notes, p_blocks);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.publish_new_workout_version(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_new_workout_version(uuid, text, jsonb) TO authenticated;
