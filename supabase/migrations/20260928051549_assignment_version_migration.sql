-- =============================================================================
-- assignment_version_migration
-- Roadmap v1.2 · Sprint 5 · Task 5.5 (Section 12, "Complete Mutation API" 3 —
-- Rule C; F-S5-P01, F-S5-P10, F-S5-P13)
--
--   public.migrate_assignment_version(...)  → app_private.migrate_assignment_version_internal
--
-- Three mutually exclusive choices when a template gains a new sealed version:
--   template_only                  changes NO assignment or occurrence row
--   future_assignments_only        sets workout_assignments.workout_version_id;
--                                  existing occurrences stay pinned, only
--                                  occurrences generated afterwards use it
--   selected_upcoming_assignments  updates ONLY the explicitly selected occurrences
--                                  and ONLY while `upcoming`; the assignment's
--                                  default version is left untouched
-- An in_progress or terminal occurrence can never be migrated (22000) and a
-- workout session is never mutated (history is version-pinned).
--
-- Lock order: assignment FOR UPDATE, then the selected occurrences FOR UPDATE in
-- id order — the same order a racing session start uses (assignment FOR SHARE
-- then occurrence FOR UPDATE), so the two serialize instead of deadlocking.
-- =============================================================================
CREATE FUNCTION app_private.migrate_assignment_version_internal(
  p_assignment_id uuid,
  p_new_version_id uuid,
  p_migration_choice text,
  p_selected_occurrence_ids uuid[],
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_selected uuid[];
  v_hash text;
  v_cached jsonb;
  v_assignment public.workout_assignments%ROWTYPE;
  v_new_version public.workout_versions%ROWTYPE;
  v_occ_id uuid;
  v_occ public.assignment_occurrences%ROWTYPE;
  v_updated integer := 0;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_assignment_id IS NULL OR p_new_version_id IS NULL THEN
    RAISE EXCEPTION 'assignment_id and new_version_id are required' USING ERRCODE = '22023';
  END IF;
  IF p_migration_choice IS NULL OR p_migration_choice NOT IN
     ('template_only', 'future_assignments_only', 'selected_upcoming_assignments') THEN
    RAISE EXCEPTION 'migration_choice must be template_only, future_assignments_only or selected_upcoming_assignments'
      USING ERRCODE = '22023';
  END IF;

  IF p_selected_occurrence_ids IS NOT NULL AND array_position(p_selected_occurrence_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Selected occurrence ids must not be null' USING ERRCODE = '22023';
  END IF;
  IF p_selected_occurrence_ids IS NOT NULL AND cardinality(p_selected_occurrence_ids) > 0 THEN
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_selected FROM unnest(p_selected_occurrence_ids) AS x;
  END IF;

  -- The three choices are mutually exclusive: only the selected-occurrences
  -- choice takes occurrence ids, and it requires at least one.
  IF p_migration_choice = 'selected_upcoming_assignments' THEN
    IF v_selected IS NULL THEN
      RAISE EXCEPTION 'selected_upcoming_assignments needs at least one occurrence id' USING ERRCODE = '22023';
    END IF;
  ELSIF v_selected IS NOT NULL THEN
    RAISE EXCEPTION 'Occurrence ids are only valid with selected_upcoming_assignments' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'assignment_id', p_assignment_id,
    'new_version_id', p_new_version_id,
    'migration_choice', p_migration_choice,
    'selected_occurrence_ids', to_jsonb(v_selected)
  )::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'MIGRATE_ASSIGNMENT_VERSION', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_assignment FROM public.workout_assignments WHERE id = p_assignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignment not found' USING ERRCODE = 'P0002';
  END IF;

  -- Same temporal authority as cancellation (F-S5-P06).
  IF NOT app_private.can_manage_assignment(p_assignment_id) THEN
    RAISE EXCEPTION 'You are not authorized to change this assignment' USING ERRCODE = '42501';
  END IF;

  IF v_assignment.status <> 'active' THEN
    RAISE EXCEPTION 'This assignment is %', v_assignment.status USING ERRCODE = '22000';
  END IF;

  -- The target version must be a sealed version of THIS assignment's template that
  -- the caller can view (F-S5-P13).
  SELECT * INTO v_new_version FROM public.workout_versions WHERE id = p_new_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That workout version is not available' USING ERRCODE = 'P0002';
  END IF;
  IF v_new_version.template_id <> v_assignment.workout_template_id THEN
    RAISE EXCEPTION 'That workout version does not belong to the assignment''s template' USING ERRCODE = '22023';
  END IF;
  IF NOT v_new_version.is_sealed THEN
    RAISE EXCEPTION 'Only a sealed workout version can be assigned' USING ERRCODE = '22000';
  END IF;
  IF NOT app_private.can_view_workout_version(p_new_version_id) THEN
    RAISE EXCEPTION 'That workout version is not available to you' USING ERRCODE = '42501';
  END IF;

  IF p_migration_choice = 'future_assignments_only' THEN
    UPDATE public.workout_assignments SET workout_version_id = p_new_version_id WHERE id = p_assignment_id;
  ELSIF p_migration_choice = 'selected_upcoming_assignments' THEN
    -- The assignment's default version is deliberately NOT updated here.
    FOREACH v_occ_id IN ARRAY v_selected
    LOOP
      SELECT * INTO v_occ FROM public.assignment_occurrences
      WHERE id = v_occ_id AND assignment_id = p_assignment_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Occurrence % does not belong to this assignment', v_occ_id USING ERRCODE = '22000';
      END IF;
      IF v_occ.status <> 'upcoming' THEN
        RAISE EXCEPTION 'Only an upcoming occurrence can be migrated (occurrence % is %)', v_occ_id, v_occ.status
          USING ERRCODE = '22000';
      END IF;
      UPDATE public.assignment_occurrences SET workout_version_id = p_new_version_id WHERE id = v_occ_id;
      v_updated := v_updated + 1;
    END LOOP;
  END IF;

  v_response := jsonb_build_object('status', 'migrated', 'choice', p_migration_choice, 'updated_occurrences', v_updated);
  PERFORM app_private.complete_idempotency(v_uid, 'MIGRATE_ASSIGNMENT_VERSION', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'version_migrated', 'workout_assignment', p_assignment_id::text, NULL,
    jsonb_build_object(
      'old_version_id', v_assignment.workout_version_id,
      'new_version_id', p_new_version_id,
      'migration_choice', p_migration_choice,
      'migrated_occurrence_ids', to_jsonb(v_selected)
    )
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.migrate_assignment_version_internal(uuid, uuid, text, uuid[], uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.migrate_assignment_version_internal(uuid, uuid, text, uuid[], uuid) TO authenticated;

CREATE FUNCTION public.migrate_assignment_version(
  p_assignment_id uuid,
  p_new_version_id uuid,
  p_migration_choice text,
  p_selected_occurrence_ids uuid[],
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  IF NOT app_private.has_permission('workout:assign') THEN
    RAISE EXCEPTION 'Unauthorized: workout:assign is required' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.migrate_assignment_version_internal(
    p_assignment_id, p_new_version_id, p_migration_choice, p_selected_occurrence_ids, p_idempotency_key
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.migrate_assignment_version(uuid, uuid, text, uuid[], uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.migrate_assignment_version(uuid, uuid, text, uuid[], uuid) TO authenticated;
