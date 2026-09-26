-- =============================================================================
-- exercise_workflow
-- Roadmap v1.2 · Sprint 2 · Task 2.8 (Section 9 §4, §5; D4)
--
--   * Column-level privileges: clients never write the workflow columns
--     (status, is_official, reviewed_by, reviewed_at, rejection_reason).
--   * Visibility RLS, every policy fail-closed on inactive/suspended callers.
--   * State transitions only through public wrappers → app_private internals.
--
-- Error codes: 42501 not authorized · P0002 not found · 55000 illegal state
-- transition · 22023 invalid action / missing rejection reason · 23505 slug clash.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Column-Level Privilege Controls (Section 9 §5)
-- -----------------------------------------------------------------------------
GRANT SELECT ON public.exercises TO authenticated;
-- Creation: content columns only; workflow columns take their defaults.
GRANT INSERT (name, slug, category, description, measurement_types, equipment_needed, created_by)
ON public.exercises TO authenticated;
-- Revoke table-level updates
REVOKE UPDATE ON public.exercises FROM authenticated, anon, PUBLIC;
-- Grant update exclusively on creator-editable content fields
GRANT UPDATE (name, description, measurement_types, equipment_needed)
ON public.exercises TO authenticated;

-- -----------------------------------------------------------------------------
-- Granular RLS Policies (Section 9 §5). Helper calls are wrapped in (SELECT …)
-- so they are evaluated once per statement, not once per row.
-- -----------------------------------------------------------------------------
-- SELECT: Approved Official
CREATE POLICY exercises_select_approved ON public.exercises
FOR SELECT TO authenticated
USING ((SELECT app_private.is_active_member()) AND status = 'approved' AND is_official = true);

-- SELECT: Creator Drafts/Pending/Rejected
CREATE POLICY exercises_select_own ON public.exercises
FOR SELECT TO authenticated
USING ((SELECT app_private.is_active_member()) AND created_by = (SELECT auth.uid()));

-- SELECT: Review Queue
CREATE POLICY exercises_select_review_queue ON public.exercises
FOR SELECT TO authenticated
USING (
  (SELECT app_private.is_active_member())
  AND status = 'pending_approval'
  AND (SELECT app_private.has_permission('exercises:approve'))
);

-- INSERT
CREATE POLICY exercises_insert_own ON public.exercises
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT app_private.is_active_member())
  AND created_by = (SELECT auth.uid())
  AND status = 'private'
  AND is_official = false
  AND rejection_reason IS NULL
  AND reviewed_by IS NULL
  AND reviewed_at IS NULL
);

-- UPDATE (Draft content edits)
CREATE POLICY exercises_update_own_draft ON public.exercises
FOR UPDATE TO authenticated
USING ((SELECT app_private.is_active_member()) AND created_by = (SELECT auth.uid()) AND status = 'private')
WITH CHECK (
  (SELECT app_private.is_active_member())
  AND created_by = (SELECT auth.uid())
  AND status = 'private'
  AND is_official = false
);

-- -----------------------------------------------------------------------------
-- Submit Transition: private → pending_approval (creator only)
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.submit_custom_exercise_internal(p_exercise_id uuid)
RETURNS public.exercises
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.exercises%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.exercises e WHERE e.id = p_exercise_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Exercise not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_row.created_by IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Only the creator can submit this exercise' USING ERRCODE = '42501';
  END IF;
  IF v_row.status <> 'private' THEN
    RAISE EXCEPTION 'Only private exercises can be submitted (current status: %)', v_row.status
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.exercises
  SET status = 'pending_approval'
  WHERE id = p_exercise_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.submit_custom_exercise_internal(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.submit_custom_exercise_internal(uuid) TO authenticated;

CREATE FUNCTION public.submit_custom_exercise(p_exercise_id uuid)
RETURNS public.exercises
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.submit_custom_exercise_internal(p_exercise_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.submit_custom_exercise(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_custom_exercise(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- Review Transition: pending_approval → approved | rejected (exercises:approve)
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.review_custom_exercise_internal(
  p_exercise_id uuid,
  p_action text,
  p_rejection_reason text
)
RETURNS public.exercises
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_row    public.exercises%ROWTYPE;
  v_reason text := NULLIF(btrim(p_rejection_reason), '');
BEGIN
  IF v_uid IS NULL
     OR NOT app_private.is_active_member()
     OR NOT app_private.has_permission('exercises:approve') THEN
    RAISE EXCEPTION 'Not authorized to review exercises' USING ERRCODE = '42501';
  END IF;

  IF p_action IS NULL OR p_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'Review action must be approve or reject' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.exercises e WHERE e.id = p_exercise_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Exercise not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'Only exercises pending approval can be reviewed (current status: %)', v_row.status
      USING ERRCODE = '55000';
  END IF;

  IF p_action = 'approve' THEN
    BEGIN
      UPDATE public.exercises
      SET status = 'approved',
          is_official = true,
          reviewed_by = v_uid,
          reviewed_at = CURRENT_TIMESTAMP
      WHERE id = p_exercise_id
      RETURNING * INTO v_row;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'An official exercise named "%" already exists', v_row.name USING ERRCODE = '23505';
    END;
  ELSE
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'A rejection reason is required' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exercises
    SET status = 'rejected',
        rejection_reason = v_reason,
        reviewed_by = v_uid,
        reviewed_at = CURRENT_TIMESTAMP
    WHERE id = p_exercise_id
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.review_custom_exercise_internal(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.review_custom_exercise_internal(uuid, text, text) TO authenticated;

CREATE FUNCTION public.review_custom_exercise(
  p_exercise_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL
)
RETURNS public.exercises
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.review_custom_exercise_internal(p_exercise_id, p_action, p_rejection_reason);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.review_custom_exercise(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_custom_exercise(uuid, text, text) TO authenticated;
