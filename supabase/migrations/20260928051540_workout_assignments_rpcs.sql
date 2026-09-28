-- =============================================================================
-- workout_assignments_rpcs
-- Roadmap v1.2 · Sprint 5 · Task 5.4 (Section 12, "Complete Mutation API &
-- Public RPC Wrappers" 1–2; F-S5-P05, F-S5-P06, F-S5-P12, F-S5-P13, F-S5-P14)
--
--   public.create_workout_assignment(...)  → app_private.create_workout_assignment_internal
--   public.cancel_workout_assignment(...)  → app_private.cancel_workout_assignment_internal
--
-- Public wrappers are SECURITY INVOKER (active member + workout:assign); the
-- internals are SECURITY DEFINER with `SET search_path = ''` and are the only
-- writers of the four assignment tables. Both mutations are idempotent through
-- the race-safe acquire_idempotency() protocol from Sprint 4
-- (mutation types CREATE_ASSIGNMENT / CANCEL_ASSIGNMENT, added in Task 5.1).
--
-- Error codes: 42501 not authorized / out of scope / idempotency key reused with
-- a different payload · 22023 invalid payload · 22000 illegal state · P0002 not found.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Weekday normalization (F-S5-P14): validates ISO weekdays 1–7 and returns the
-- deterministic sorted, distinct array (array_agg(DISTINCT d ORDER BY d)).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.normalize_days_of_week(p_days jsonb)
RETURNS smallint[]
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
  v_elem jsonb;
  v_result smallint[];
BEGIN
  IF p_days IS NULL OR jsonb_typeof(p_days) <> 'array' THEN
    RAISE EXCEPTION 'days_of_week must be an array of ISO weekdays (1 = Monday ... 7 = Sunday)' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_days) = 0 OR jsonb_array_length(p_days) > 50 THEN
    RAISE EXCEPTION 'days_of_week must list between 1 and 7 weekdays' USING ERRCODE = '22023';
  END IF;
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_days)
  LOOP
    IF jsonb_typeof(v_elem) <> 'number' OR (v_elem #>> '{}') !~ '^[1-7]$' THEN
      RAISE EXCEPTION 'days_of_week entries must be whole ISO weekdays between 1 and 7' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  SELECT array_agg(DISTINCT d ORDER BY d) INTO v_result
  FROM (SELECT (e #>> '{}')::smallint AS d FROM jsonb_array_elements(p_days) AS e) AS days;
  RETURN v_result;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.normalize_days_of_week(jsonb) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Temporal management authority (F-S5-P06) shared by cancel (here) and Rule C
-- version migration (Task 5.5). Creating an assignment confers NO permanent
-- right over it: authority is re-derived from the caller's CURRENT position and
-- coaching relationships.
--   * active member holding workout:assign, and either
--   * leadership (training:view_org) in the assignment's own organization, or
--   * the current primary coach of EVERY athlete currently targeted — if even one
--     target was reassigned or left, only organization leadership can act.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.can_manage_assignment(p_assignment_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_assignment_org uuid;
  v_current_org uuid;
  v_target record;
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member()
     OR NOT app_private.has_permission('workout:assign') THEN
    RETURN false;
  END IF;

  SELECT organization_id INTO v_assignment_org FROM public.workout_assignments WHERE id = p_assignment_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NOT NULL
     AND v_assignment_org IS NOT DISTINCT FROM v_current_org
     AND app_private.has_permission('training:view_org') THEN
    RETURN true;
  END IF;

  FOR v_target IN SELECT athlete_id FROM public.assignment_targets WHERE assignment_id = p_assignment_id
  LOOP
    IF NOT app_private.can_assign_training_to(v_target.athlete_id) THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN EXISTS (SELECT 1 FROM public.assignment_targets WHERE assignment_id = p_assignment_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_manage_assignment(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_manage_assignment(uuid) TO authenticated;

-- =============================================================================
-- 1. create_workout_assignment
-- =============================================================================
CREATE FUNCTION app_private.create_workout_assignment_internal(
  p_workout_template_id uuid,
  p_workout_version_id uuid,
  p_target_athlete_ids uuid[],
  p_target_date date,
  p_is_recurring boolean,
  p_recurrence_rule jsonb,
  p_notes text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_targets uuid[];
  v_hash text;
  v_cached jsonb;
  v_current_org uuid;
  v_org_tz text;
  v_template public.workout_templates%ROWTYPE;
  v_version public.workout_versions%ROWTYPE;
  v_athlete uuid;
  v_notes text;
  v_rule jsonb;
  v_days smallint[];
  v_start date;
  v_end date;
  v_rule_tz text;
  v_assignment_id uuid;
  v_created integer := 0;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_workout_template_id IS NULL THEN
    RAISE EXCEPTION 'workout_template_id is required' USING ERRCODE = '22023';
  END IF;
  IF p_is_recurring IS NULL THEN
    RAISE EXCEPTION 'is_recurring is required' USING ERRCODE = '22023';
  END IF;
  IF p_target_athlete_ids IS NULL OR cardinality(p_target_athlete_ids) < 1 THEN
    RAISE EXCEPTION 'At least one target athlete is required' USING ERRCODE = '22023';
  END IF;
  IF array_position(p_target_athlete_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Target athlete ids must not be null' USING ERRCODE = '22023';
  END IF;
  -- Sorted, distinct target set: both the hash and the inserts use it, so the
  -- same logical request is the same payload however the client ordered it.
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_targets FROM unnest(p_target_athlete_ids) AS x;

  v_rule := CASE WHEN p_recurrence_rule IS NULL OR jsonb_typeof(p_recurrence_rule) = 'null' THEN NULL ELSE p_recurrence_rule END;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'workout_template_id', p_workout_template_id,
    'workout_version_id', p_workout_version_id,
    'target_athlete_ids', to_jsonb(v_targets),
    'target_date', p_target_date,
    'is_recurring', p_is_recurring,
    'recurrence_rule', v_rule,
    'notes', p_notes
  )::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'CREATE_ASSIGNMENT', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  -- Organization context: the assignment's organization is the caller's current one.
  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NULL THEN
    RAISE EXCEPTION 'You must belong to an organization to assign workouts' USING ERRCODE = '42501';
  END IF;
  SELECT timezone INTO v_org_tz FROM public.organizations WHERE id = v_current_org;

  -- Template & sealed-version source eligibility (F-S5-P05, F-S5-P13).
  SELECT * INTO v_template FROM public.workout_templates WHERE id = p_workout_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That workout template is not available' USING ERRCODE = 'P0002';
  END IF;

  IF p_workout_version_id IS NULL THEN
    SELECT * INTO v_version FROM public.workout_versions
    WHERE template_id = v_template.id AND is_sealed = true
    ORDER BY version_number DESC LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'This workout template has no sealed version to assign' USING ERRCODE = '22000';
    END IF;
  ELSE
    SELECT * INTO v_version FROM public.workout_versions WHERE id = p_workout_version_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That workout version is not available' USING ERRCODE = 'P0002';
    END IF;
    IF v_version.template_id <> v_template.id THEN
      RAISE EXCEPTION 'That workout version does not belong to the template' USING ERRCODE = '22023';
    END IF;
    IF NOT v_version.is_sealed THEN
      RAISE EXCEPTION 'Only a sealed workout version can be assigned' USING ERRCODE = '22000';
    END IF;
  END IF;

  IF NOT app_private.can_view_workout_version(v_version.id) THEN
    RAISE EXCEPTION 'That workout version is not available to you' USING ERRCODE = '42501';
  END IF;

  IF v_template.visibility = 'organization' THEN
    -- Organization template: must belong to the caller's organization (targets are
    -- checked against that same organization below).
    IF v_template.organization_id IS DISTINCT FROM v_current_org THEN
      RAISE EXCEPTION 'That workout template belongs to another organization' USING ERRCODE = '42501';
    END IF;
  ELSE
    -- Private template: assignable strictly back to its own creator. A coach may
    -- program an athlete's own private routine to that athlete, never one
    -- member's private routine to somebody else.
    IF EXISTS (SELECT 1 FROM unnest(v_targets) AS t WHERE t <> v_template.created_by) THEN
      RAISE EXCEPTION 'A private routine can only be assigned to its creator' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Target athletes: in the caller's scope AND in the assignment's organization.
  FOREACH v_athlete IN ARRAY v_targets
  LOOP
    IF NOT app_private.can_assign_training_to(v_athlete)
       OR app_private.organization_of(v_athlete) IS DISTINCT FROM v_current_org THEN
      RAISE EXCEPTION 'You cannot assign training to one or more of these athletes' USING ERRCODE = '42501';
    END IF;
  END LOOP;

  IF p_notes IS NOT NULL AND length(p_notes) > 2000 THEN
    RAISE EXCEPTION 'notes must be at most 2000 characters' USING ERRCODE = '22023';
  END IF;
  v_notes := nullif(btrim(p_notes), '');

  -- Schedule parameters (F-S5-P14).
  IF NOT p_is_recurring THEN
    IF p_target_date IS NULL THEN
      RAISE EXCEPTION 'target_date is required for a single-date assignment' USING ERRCODE = '22023';
    END IF;
    IF v_rule IS NOT NULL THEN
      RAISE EXCEPTION 'recurrence_rule must be empty for a single-date assignment' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF p_target_date IS NOT NULL THEN
      RAISE EXCEPTION 'target_date must be empty for a recurring assignment' USING ERRCODE = '22023';
    END IF;
    IF v_rule IS NULL OR jsonb_typeof(v_rule) <> 'object' THEN
      RAISE EXCEPTION 'recurrence_rule is required for a recurring assignment' USING ERRCODE = '22023';
    END IF;
    v_days := app_private.normalize_days_of_week(v_rule -> 'days_of_week');
    BEGIN
      v_start := (app_private.workout_json_text(v_rule, 'start_date', 10, true))::date;
      v_end := (app_private.workout_json_text(v_rule, 'end_date', 10))::date;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
      RAISE EXCEPTION 'start_date and end_date must be valid YYYY-MM-DD dates' USING ERRCODE = '22023';
    END;
    IF v_end IS NOT NULL AND v_end < v_start THEN
      RAISE EXCEPTION 'end_date must not be before start_date' USING ERRCODE = '22023';
    END IF;
    v_rule_tz := COALESCE(app_private.workout_json_text(v_rule, 'timezone', 64), v_org_tz);
    IF v_rule_tz IS DISTINCT FROM v_org_tz THEN
      RAISE EXCEPTION 'Recurrence timezone (%) must match the organization timezone (%)', v_rule_tz, v_org_tz
        USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.workout_assignments
    (organization_id, workout_template_id, workout_version_id, assigned_by, target_date, is_recurring, notes)
  VALUES
    (v_current_org, v_template.id, v_version.id, v_uid, p_target_date, p_is_recurring, v_notes)
  RETURNING id INTO v_assignment_id;

  INSERT INTO public.assignment_targets (assignment_id, athlete_id)
  SELECT v_assignment_id, t FROM unnest(v_targets) AS t;

  IF p_is_recurring THEN
    INSERT INTO public.recurring_schedules (assignment_id, days_of_week, start_date, end_date, timezone)
    VALUES (v_assignment_id, v_days, v_start, v_end, v_org_tz);
    v_created := app_private.generate_assignment_occurrences(v_assignment_id);
  ELSE
    INSERT INTO public.assignment_occurrences
      (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime)
    SELECT
      v_assignment_id, t, v_version.id, p_target_date,
      p_target_date::timestamp AT TIME ZONE v_org_tz,
      (p_target_date + 1)::timestamp AT TIME ZONE v_org_tz
    FROM unnest(v_targets) AS t;
    GET DIAGNOSTICS v_created = ROW_COUNT;
  END IF;

  v_response := jsonb_build_object('assignment_id', v_assignment_id, 'occurrences_created', v_created, 'status', 'active');
  PERFORM app_private.complete_idempotency(v_uid, 'CREATE_ASSIGNMENT', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'created', 'workout_assignment', v_assignment_id::text, NULL,
    jsonb_build_object(
      'organization_id', v_current_org,
      'workout_template_id', v_template.id,
      'workout_version_id', v_version.id,
      'target_athlete_ids', to_jsonb(v_targets),
      'is_recurring', p_is_recurring,
      'target_date', p_target_date,
      'days_of_week', v_days,
      'occurrences_created', v_created
    )
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.create_workout_assignment_internal(uuid, uuid, uuid[], date, boolean, jsonb, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.create_workout_assignment_internal(uuid, uuid, uuid[], date, boolean, jsonb, text, uuid) TO authenticated;

CREATE FUNCTION public.create_workout_assignment(
  p_workout_template_id uuid,
  p_workout_version_id uuid,
  p_target_athlete_ids uuid[],
  p_target_date date,
  p_is_recurring boolean,
  p_recurrence_rule jsonb,
  p_notes text,
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
  RETURN app_private.create_workout_assignment_internal(
    p_workout_template_id, p_workout_version_id, p_target_athlete_ids, p_target_date,
    p_is_recurring, p_recurrence_rule, p_notes, p_idempotency_key
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.create_workout_assignment(uuid, uuid, uuid[], date, boolean, jsonb, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_workout_assignment(uuid, uuid, uuid[], date, boolean, jsonb, text, uuid) TO authenticated;

-- =============================================================================
-- 2. cancel_workout_assignment
-- Lock order (Section 12): assignment FOR UPDATE, then the occurrences it deletes.
-- A racing session start locks the assignment FOR SHARE first, so the two
-- serialize deterministically: a start that commits first leaves its now
-- in_progress occurrence untouched (only `upcoming` rows are deleted); a
-- cancellation that commits first makes the start fail closed (22000).
-- =============================================================================
CREATE FUNCTION app_private.cancel_workout_assignment_internal(
  p_assignment_id uuid, p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_hash text;
  v_cached jsonb;
  v_assignment public.workout_assignments%ROWTYPE;
  v_org_tz text;
  v_org_today date;
  v_deleted integer;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_assignment_id IS NULL THEN
    RAISE EXCEPTION 'assignment_id is required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(p_assignment_id::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'CANCEL_ASSIGNMENT', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_assignment FROM public.workout_assignments WHERE id = p_assignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignment not found' USING ERRCODE = 'P0002';
  END IF;

  -- Temporal authority (F-S5-P06): leadership of the assignment's organization, or
  -- the current coach of EVERY currently assigned athlete.
  IF NOT app_private.can_manage_assignment(p_assignment_id) THEN
    RAISE EXCEPTION 'You are not authorized to cancel this assignment' USING ERRCODE = '42501';
  END IF;

  IF v_assignment.status <> 'active' THEN
    RAISE EXCEPTION 'This assignment is already %', v_assignment.status USING ERRCODE = '22000';
  END IF;

  SELECT timezone INTO v_org_tz FROM public.organizations WHERE id = v_assignment.organization_id;
  v_org_today := (now() AT TIME ZONE v_org_tz)::date;

  UPDATE public.workout_assignments SET status = 'cancelled' WHERE id = p_assignment_id;
  IF v_assignment.is_recurring THEN
    UPDATE public.recurring_schedules SET is_active = false WHERE assignment_id = p_assignment_id;
  END IF;

  -- F-S5-P12: only FUTURE/TODAY unstarted occurrences are purged. Overdue upcoming
  -- rows (scheduled_date < org today) stay for overdue -> missed processing, and
  -- in_progress / completed / partially_completed / abandoned / missed history is
  -- never touched (the lifecycle trigger would reject it anyway).
  DELETE FROM public.assignment_occurrences
  WHERE assignment_id = p_assignment_id
    AND status = 'upcoming'
    AND scheduled_date >= v_org_today;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  v_response := jsonb_build_object('assignment_id', p_assignment_id, 'status', 'cancelled');
  PERFORM app_private.complete_idempotency(v_uid, 'CANCEL_ASSIGNMENT', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'cancelled', 'workout_assignment', p_assignment_id::text,
    jsonb_build_object('status', v_assignment.status),
    jsonb_build_object('status', 'cancelled', 'deleted_occurrences', v_deleted)
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.cancel_workout_assignment_internal(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.cancel_workout_assignment_internal(uuid, uuid) TO authenticated;

CREATE FUNCTION public.cancel_workout_assignment(p_assignment_id uuid, p_idempotency_key uuid)
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
  RETURN app_private.cancel_workout_assignment_internal(p_assignment_id, p_idempotency_key);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.cancel_workout_assignment(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_workout_assignment(uuid, uuid) TO authenticated;
