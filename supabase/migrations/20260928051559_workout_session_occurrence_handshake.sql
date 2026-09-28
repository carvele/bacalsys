-- =============================================================================
-- workout_session_occurrence_handshake
-- Roadmap v1.2 · Sprint 5 · Task 5.6 (Section 12, "Updated start_workout_session
-- Signature Strategy & Lock Ordering", "Updated complete_workout_session
-- Occurrence Transition", "Updated sync_offline_session_bundle & Structural
-- Reconciliation"; F-S5-P02, F-S5-P03, F-S5-P11, F-S5-P12, F-S5-P15)
--
-- Signature strategy (F-S5-P11) — exactly this inventory, checked by pgTAP:
--   public.start_workout_session(uuid, uuid)          2-arg wrapper → internal(..., NULL)
--   public.start_workout_session(uuid, uuid, uuid)    3-arg wrapper → internal(..., occurrence)
--   app_private.start_workout_session_internal(uuid, uuid, uuid DEFAULT NULL)   the ONE implementation
--
-- Lock ordering (F-S5-P12), identical for every writer that touches an
-- occurrence: the parent assignment FOR SHARE (a cancelled assignment fails
-- closed, 22000), then the occurrence FOR UPDATE, and only then the athlete's
-- profile row. Cancellation (assignment FOR UPDATE), Rule C migration
-- (assignment FOR UPDATE, occurrences FOR UPDATE), the generator (assignment
-- FOR SHARE) and the overdue job (occurrence FOR UPDATE SKIP LOCKED) all agree
-- with it, so every pair serializes instead of deadlocking. The occurrence-state
-- check runs BEFORE the profile lock, so a second start of the SAME occurrence
-- with a different idempotency key wakes up after the first commits and fails
-- with 22000 ("no longer upcoming"); the unique session/occurrence index stays
-- defense in depth.
--
-- Shared helper app_private.complete_assignment_occurrence() performs the one
-- and only in_progress → terminal occurrence transition, so the granular
-- complete RPC and the offline bundle can never disagree about it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Shared: in_progress → completed | partially_completed | abandoned.
--   completed session                    → completed
--   abandoned session with ≥ 1 set       → partially_completed
--   abandoned session with 0 sets        → abandoned
-- Locks the occurrence FOR UPDATE; raises 22000 unless it is in_progress.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.complete_assignment_occurrence(
  p_occurrence_id uuid, p_session_status text, p_completed_at timestamptz, p_set_count integer
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_status text;
  v_final text;
BEGIN
  SELECT status INTO v_status FROM public.assignment_occurrences WHERE id = p_occurrence_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The linked assignment occurrence no longer exists' USING ERRCODE = '22000';
  END IF;
  IF v_status <> 'in_progress' THEN
    RAISE EXCEPTION 'The linked assignment occurrence is % rather than in_progress', v_status USING ERRCODE = '22000';
  END IF;

  IF p_session_status = 'completed' THEN
    v_final := 'completed';
  ELSIF p_set_count >= 1 THEN
    v_final := 'partially_completed';
  ELSE
    v_final := 'abandoned';
  END IF;

  UPDATE public.assignment_occurrences
  SET status = v_final, completed_at = p_completed_at
  WHERE id = p_occurrence_id;
  RETURN v_final;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.complete_assignment_occurrence(uuid, text, timestamptz, integer) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1. start_workout_session — single authoritative 3-parameter implementation
-- -----------------------------------------------------------------------------
DROP FUNCTION app_private.start_workout_session_internal(uuid, uuid);

CREATE FUNCTION app_private.start_workout_session_internal(
  p_workout_version_id uuid,
  p_idempotency_key uuid,
  p_assignment_occurrence_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_hash text;
  v_cached jsonb;
  v_version public.workout_versions%ROWTYPE;
  v_occ public.assignment_occurrences%ROWTYPE;
  v_assignment_status text;
  v_session_id uuid;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_workout_version_id IS NULL THEN
    RAISE EXCEPTION 'A workout version is required' USING ERRCODE = '22023';
  END IF;

  -- The payload hash carries the occurrence identity (F-S5-P11): the same key
  -- reused for a different occurrence (or direct vs assigned) fails closed.
  v_hash := app_private.hash_payload(p_workout_version_id::text || ':' || COALESCE(p_assignment_occurrence_id::text, 'direct'));
  v_cached := app_private.acquire_idempotency(v_uid, 'START_SESSION', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF p_assignment_occurrence_id IS NOT NULL THEN
    -- Ownership first, WITHOUT locks: a non-owner must never be able to queue on
    -- (and briefly block) somebody else's occurrence.
    SELECT * INTO v_occ FROM public.assignment_occurrences WHERE id = p_assignment_occurrence_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That assignment occurrence is no longer available' USING ERRCODE = '22000';
    END IF;
    IF v_occ.athlete_id <> v_uid THEN
      RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
    END IF;

    -- Lock order step 1: the parent assignment FOR SHARE (fails if cancelled).
    SELECT a.status INTO v_assignment_status
    FROM public.workout_assignments a
    JOIN public.assignment_occurrences ao ON ao.assignment_id = a.id
    WHERE ao.id = p_assignment_occurrence_id
    FOR SHARE OF a;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That assignment occurrence is no longer available' USING ERRCODE = '22000';
    END IF;
    IF v_assignment_status = 'cancelled' THEN
      RAISE EXCEPTION 'Cannot start workout on cancelled assignment' USING ERRCODE = '22000';
    END IF;

    -- Lock order step 2: the occurrence FOR UPDATE.
    SELECT * INTO v_occ FROM public.assignment_occurrences WHERE id = p_assignment_occurrence_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That assignment occurrence is no longer available' USING ERRCODE = '22000';
    END IF;
    IF v_occ.status <> 'upcoming' THEN
      RAISE EXCEPTION 'That assignment occurrence is % and can no longer be started', v_occ.status USING ERRCODE = '22000';
    END IF;
    IF v_occ.workout_version_id <> p_workout_version_id THEN
      RAISE EXCEPTION 'That workout version is not the one assigned for this occurrence' USING ERRCODE = '22000';
    END IF;
  END IF;

  -- Serializes concurrent session starts by the same athlete (always taken AFTER
  -- the assignment/occurrence locks above).
  PERFORM 1 FROM public.profiles WHERE id = v_uid FOR UPDATE;

  IF EXISTS (SELECT 1 FROM public.workout_sessions WHERE athlete_id = v_uid AND status = 'in_progress') THEN
    RAISE EXCEPTION 'You already have an active workout session in progress' USING ERRCODE = '23505';
  END IF;

  SELECT * INTO v_version FROM public.workout_versions WHERE id = p_workout_version_id;
  IF NOT FOUND OR NOT v_version.is_sealed OR NOT app_private.can_view_workout_version(p_workout_version_id) THEN
    RAISE EXCEPTION 'That workout version is not available to you' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.workout_sessions (athlete_id, workout_version_id, assignment_occurrence_id, status, started_at)
  VALUES (v_uid, p_workout_version_id, p_assignment_occurrence_id, 'in_progress', now())
  RETURNING id INTO v_session_id;

  IF p_assignment_occurrence_id IS NOT NULL THEN
    UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = p_assignment_occurrence_id;
  END IF;

  PERFORM app_private.instantiate_session_exercises(v_session_id, p_workout_version_id);

  v_response := jsonb_build_object(
    'session_id', v_session_id,
    'status', 'in_progress',
    'assignment_occurrence_id', p_assignment_occurrence_id,
    'exercise_mapping', (
      SELECT COALESCE(jsonb_object_agg(workout_item_id::text, id::text), '{}'::jsonb)
      FROM public.session_exercises WHERE session_id = v_session_id
    )
  );
  PERFORM app_private.complete_idempotency(v_uid, 'START_SESSION', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'started', 'workout_session', v_session_id::text, NULL,
    jsonb_build_object('workout_version_id', p_workout_version_id, 'assignment_occurrence_id', p_assignment_occurrence_id)
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.start_workout_session_internal(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.start_workout_session_internal(uuid, uuid, uuid) TO authenticated;

-- 2-arg public wrapper (direct, unassigned workouts) — same signature as Sprint 4.
CREATE OR REPLACE FUNCTION public.start_workout_session(p_workout_version_id uuid, p_idempotency_key uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.start_workout_session_internal(p_workout_version_id, p_idempotency_key, NULL);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.start_workout_session(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_workout_session(uuid, uuid) TO authenticated;

-- 3-arg public wrapper (assigned workouts).
CREATE FUNCTION public.start_workout_session(
  p_workout_version_id uuid, p_idempotency_key uuid, p_assignment_occurrence_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.start_workout_session_internal(p_workout_version_id, p_idempotency_key, p_assignment_occurrence_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.start_workout_session(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_workout_session(uuid, uuid, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. complete_workout_session — adds the occurrence transition (F-S5-P02)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_private.complete_workout_session_internal(
  p_session_id uuid,
  p_status text,
  p_abandonment_reason_code text,
  p_feedback jsonb,
  p_private_feedback jsonb,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_hash text;
  v_cached jsonb;
  v_session public.workout_sessions%ROWTYPE;
  v_completed_at timestamptz;
  v_set_count integer;
  v_occurrence_status text;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'session_id', p_session_id, 'status', p_status, 'abandonment_reason_code', p_abandonment_reason_code,
    'feedback', p_feedback, 'private_feedback', p_private_feedback
  )::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'COMPLETE_SESSION', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_session FROM public.workout_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Session not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_session.athlete_id <> v_uid THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;
  IF v_session.status <> 'in_progress' THEN
    RAISE EXCEPTION 'This session has already ended' USING ERRCODE = '22000';
  END IF;

  IF p_status IS NULL OR p_status NOT IN ('completed', 'abandoned') THEN
    RAISE EXCEPTION 'status must be completed or abandoned' USING ERRCODE = '22023';
  END IF;
  PERFORM app_private.validate_abandonment(p_status, p_abandonment_reason_code);

  UPDATE public.workout_sessions
  SET status = p_status, completed_at = now(), abandonment_reason_code = p_abandonment_reason_code
  WHERE id = p_session_id
  RETURNING completed_at INTO v_completed_at;

  PERFORM app_private.apply_session_feedback(p_session_id, p_feedback, p_private_feedback);

  -- An assigned session moves its occurrence through the normal state machine.
  IF v_session.assignment_occurrence_id IS NOT NULL THEN
    SELECT count(*) INTO v_set_count
    FROM public.session_sets ss JOIN public.session_exercises se ON se.id = ss.session_exercise_id
    WHERE se.session_id = p_session_id;
    v_occurrence_status := app_private.complete_assignment_occurrence(
      v_session.assignment_occurrence_id, p_status, v_completed_at, v_set_count
    );
  END IF;

  v_response := jsonb_build_object('session_id', p_session_id, 'status', p_status);
  PERFORM app_private.complete_idempotency(v_uid, 'COMPLETE_SESSION', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'completed', 'workout_session', p_session_id::text, NULL,
    jsonb_build_object('status', p_status, 'abandonment_reason_code', p_abandonment_reason_code,
                       'occurrence_status', v_occurrence_status)
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.complete_workout_session_internal(uuid, text, text, jsonb, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.complete_workout_session_internal(uuid, text, text, jsonb, jsonb, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. sync_offline_session_bundle — occurrence identity, structural late-sync
--    reconciliation and offline resilience (F-S5-P03, F-S5-P15)
--
--   bundle.assignment_occurrence_id is nullable.
--   existing_session_id path : the bundle's occurrence id must equal the
--       session's own (IS NOT DISTINCT FROM, else 22000); the occurrence then
--       moves in_progress → terminal.
--   brand-new session path   : the occurrence id is only a claim, resolved in the
--       standard lock order (assignment FOR SHARE → occurrence FOR UPDATE):
--       * occurrence deleted (legitimate cancellation while offline) or its
--         assignment cancelled, or it already has its own execution, or it is
--         missed and the workout started AT/AFTER the deadline
--            → the performance is preserved as a direct/unassigned session
--              (assignment_occurrence_id = NULL). The occurrence is never
--              recreated or touched, so cancelled-assignment adherence is intact,
--              and every ordinary direct-session rule still applies.
--       * `upcoming` → session inserted in_progress, linked, occurrence
--         upcoming → in_progress, bundle applied, session completed, occurrence
--         in_progress → terminal.
--       * `missed` with scheduled_at <= started_at < due_datetime → structural
--         reconciliation: the linked in_progress session is inserted FIRST, and
--         only then does the lifecycle trigger permit missed → in_progress (it
--         verifies that session in database state — no GUC, no bypass); the
--         bundle is applied, the session completed, the occurrence moves through
--         the ordinary in_progress → terminal transition, and
--         'reconciled_from_missed' is audited.
--       * a different athlete's occurrence → 42501; a version other than the
--         occurrence's pinned version → 22000.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_private.sync_offline_session_bundle_internal(
  p_bundle jsonb, p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_hash text;
  v_cached jsonb;
  v_existing_text text;
  v_existing_id uuid;
  v_occ_text text;
  v_occ_id uuid;
  v_workout_version_id uuid;
  v_status text;
  v_abandonment text;
  v_started_at_text text;
  v_completed_at_text text;
  v_started_at timestamptz;
  v_completed_at timestamptz;
  v_substitutions jsonb;
  v_sets jsonb;
  v_feedback jsonb;
  v_private_feedback jsonb;
  v_session public.workout_sessions%ROWTYPE;
  v_session_id uuid;
  v_sub jsonb;
  v_set jsonb;
  v_original_item_id uuid;
  v_session_exercise_id uuid;
  v_occ public.assignment_occurrences%ROWTYPE;
  v_assignment_status text;
  v_link_occ uuid;
  v_link_kind text := 'unassigned';
  v_set_count integer;
  v_occurrence_final text;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_bundle) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'The offline bundle must be an object' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(p_bundle::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'SYNC_BUNDLE', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  -- Required top-level fields (OfflineSessionBundle JSON Schema).
  BEGIN
    v_workout_version_id := (app_private.workout_json_text(p_bundle, 'workout_version_id', 64, true))::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'workout_version_id must be a valid id' USING ERRCODE = '22023';
  END;

  v_occ_text := app_private.workout_json_text(p_bundle, 'assignment_occurrence_id', 64);
  IF v_occ_text IS NOT NULL THEN
    BEGIN
      v_occ_id := v_occ_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'assignment_occurrence_id must be a valid id' USING ERRCODE = '22023';
    END;
  END IF;

  v_status := app_private.workout_json_text(p_bundle, 'status', 20, true);
  IF v_status NOT IN ('completed', 'abandoned') THEN
    RAISE EXCEPTION 'status must be completed or abandoned' USING ERRCODE = '22023';
  END IF;
  v_abandonment := app_private.workout_json_text(p_bundle, 'abandonment_reason_code', 30);
  PERFORM app_private.validate_abandonment(v_status, v_abandonment);

  v_started_at_text := app_private.workout_json_text(p_bundle, 'started_at', 64, true);
  v_completed_at_text := app_private.workout_json_text(p_bundle, 'completed_at', 64, true);
  BEGIN
    v_started_at := v_started_at_text::timestamptz;
    v_completed_at := v_completed_at_text::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'started_at and completed_at must be valid timestamps' USING ERRCODE = '22023';
  END;
  IF v_completed_at < v_started_at THEN
    RAISE EXCEPTION 'completed_at must not be before started_at' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(p_bundle -> 'sets') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'sets must be an array' USING ERRCODE = '22023';
  END IF;
  v_sets := p_bundle -> 'sets';
  v_substitutions := COALESCE(p_bundle -> 'substitutions', '[]'::jsonb);
  IF jsonb_typeof(v_substitutions) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'substitutions must be an array' USING ERRCODE = '22023';
  END IF;
  v_feedback := p_bundle -> 'feedback';
  v_private_feedback := p_bundle -> 'private_feedback';

  -- Interrupted-connectivity continuation path -------------------------------------
  v_existing_text := app_private.workout_json_text(p_bundle, 'existing_session_id', 64);
  IF v_existing_text IS NOT NULL THEN
    BEGIN
      v_existing_id := v_existing_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'existing_session_id must be a valid id' USING ERRCODE = '22023';
    END;

    SELECT * INTO v_session FROM public.workout_sessions WHERE id = v_existing_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Session not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_session.athlete_id <> v_uid THEN
      RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
    END IF;
    IF v_session.status <> 'in_progress' THEN
      RAISE EXCEPTION 'This session has already ended' USING ERRCODE = '22000';
    END IF;
    IF v_session.workout_version_id IS DISTINCT FROM v_workout_version_id THEN
      RAISE EXCEPTION 'workout_version_id does not match the existing session' USING ERRCODE = '22023';
    END IF;
    IF v_occ_id IS DISTINCT FROM v_session.assignment_occurrence_id THEN
      RAISE EXCEPTION 'assignment_occurrence_id does not match the existing session' USING ERRCODE = '22000';
    END IF;
    v_session_id := v_existing_id;
    v_link_occ := v_session.assignment_occurrence_id;
    IF v_link_occ IS NOT NULL THEN
      v_link_kind := 'linked';
    END IF;
  ELSE
    -- Brand new session, completed entirely offline ------------------------------
    -- Resolve the occurrence claim FIRST, in the standard lock order
    -- (assignment FOR SHARE → occurrence FOR UPDATE), before the profile lock.
    IF v_occ_id IS NOT NULL THEN
      SELECT * INTO v_occ FROM public.assignment_occurrences WHERE id = v_occ_id;
      IF FOUND THEN
        IF v_occ.athlete_id <> v_uid THEN
          RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
        END IF;

        SELECT status INTO v_assignment_status FROM public.workout_assignments WHERE id = v_occ.assignment_id FOR SHARE;
        SELECT * INTO v_occ FROM public.assignment_occurrences WHERE id = v_occ_id FOR UPDATE;

        IF FOUND AND v_assignment_status IS DISTINCT FROM 'cancelled' THEN
          IF v_occ.workout_version_id IS DISTINCT FROM v_workout_version_id THEN
            RAISE EXCEPTION 'workout_version_id does not match the occurrence''s assigned version' USING ERRCODE = '22000';
          END IF;

          IF v_occ.status = 'upcoming' THEN
            v_link_occ := v_occ.id;
            v_link_kind := 'linked';
          ELSIF v_occ.status = 'missed'
                AND v_started_at >= v_occ.scheduled_at AND v_started_at < v_occ.due_datetime THEN
            v_link_occ := v_occ.id;
            v_link_kind := 'reconciled';
          END IF;
          -- Any other state (missed with a post-deadline start, in_progress,
          -- terminal) leaves v_link_occ NULL: the workout is preserved as an
          -- unassigned session and the occurrence is left exactly as it is.
        END IF;
        -- Occurrence deleted mid-flight, or assignment cancelled: same fallback.
      END IF;
    END IF;

    PERFORM 1 FROM public.profiles WHERE id = v_uid FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.workout_sessions WHERE athlete_id = v_uid AND status = 'in_progress') THEN
      RAISE EXCEPTION 'You already have an active workout session in progress' USING ERRCODE = '23505';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.workout_versions v WHERE v.id = v_workout_version_id AND v.is_sealed = true
    ) OR NOT app_private.can_view_workout_version(v_workout_version_id) THEN
      RAISE EXCEPTION 'That workout version is not available to you' USING ERRCODE = 'P0002';
    END IF;

    -- The linked in_progress session is inserted FIRST (F-S5-P15): the lifecycle
    -- trigger only lets a missed occurrence resume when it can see this row.
    INSERT INTO public.workout_sessions (athlete_id, workout_version_id, assignment_occurrence_id, status, started_at)
    VALUES (v_uid, v_workout_version_id, v_link_occ, 'in_progress', v_started_at)
    RETURNING id INTO v_session_id;

    IF v_link_occ IS NOT NULL THEN
      UPDATE public.assignment_occurrences SET status = 'in_progress' WHERE id = v_link_occ;
    END IF;

    PERFORM app_private.instantiate_session_exercises(v_session_id, v_workout_version_id);
  END IF;

  -- Apply substitutions, in bundle order, before any of the bundle's sets (the
  -- F-S4-P14 lineage invariant inside apply_session_substitution enforces this
  -- per item regardless of order, but the client always emits them first).
  FOR v_sub IN SELECT * FROM jsonb_array_elements(v_substitutions)
  LOOP
    BEGIN
      v_original_item_id := (app_private.workout_json_text(v_sub, 'original_workout_item_id', 64, true))::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'original_workout_item_id must be a valid id' USING ERRCODE = '22023';
    END;
    PERFORM app_private.apply_session_substitution(
      v_session_id, v_uid, v_original_item_id,
      (app_private.workout_json_text(v_sub, 'replacement_exercise_id', 64, true))::uuid,
      app_private.workout_json_text(v_sub, 'performed_measurement_mode', 30, true),
      app_private.workout_json_text(v_sub, 'reason_code', 30, true)
    );
  END LOOP;

  -- Merge sets, correlated by the immutable workout_item_id (never a
  -- server-generated execution id the client could not have known offline).
  FOR v_set IN SELECT * FROM jsonb_array_elements(v_sets)
  LOOP
    BEGIN
      v_original_item_id := (app_private.workout_json_text(v_set, 'workout_item_id', 64, true))::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'workout_item_id must be a valid id' USING ERRCODE = '22023';
    END;
    SELECT id INTO v_session_exercise_id FROM public.session_exercises
    WHERE session_id = v_session_id AND workout_item_id = v_original_item_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That exercise is not part of this session' USING ERRCODE = '22000';
    END IF;
    PERFORM app_private.apply_session_set(v_session_exercise_id, v_set);
  END LOOP;

  PERFORM app_private.apply_session_feedback(v_session_id, v_feedback, v_private_feedback);

  UPDATE public.workout_sessions
  SET status = v_status, completed_at = v_completed_at, abandonment_reason_code = v_abandonment
  WHERE id = v_session_id;

  -- The occurrence completes through the ordinary in_progress → terminal transition.
  IF v_link_occ IS NOT NULL THEN
    SELECT count(*) INTO v_set_count
    FROM public.session_sets ss JOIN public.session_exercises se ON se.id = ss.session_exercise_id
    WHERE se.session_id = v_session_id;
    v_occurrence_final := app_private.complete_assignment_occurrence(v_link_occ, v_status, v_completed_at, v_set_count);

    IF v_link_kind = 'reconciled' THEN
      PERFORM app_private.write_audit_event(
        'reconciled_from_missed', 'assignment_occurrence', v_link_occ::text,
        jsonb_build_object('status', 'missed'),
        jsonb_build_object(
          'status', v_occurrence_final,
          'reason', 'offline_started_before_due',
          'started_at', v_started_at,
          'due_datetime', v_occ.due_datetime,
          'session_id', v_session_id
        )
      );
    END IF;
  END IF;

  v_response := jsonb_build_object(
    'status', 'synced',
    'session_id', v_session_id,
    'assignment_occurrence_id', v_link_occ,
    'occurrence_link', v_link_kind
  );
  PERFORM app_private.complete_idempotency(v_uid, 'SYNC_BUNDLE', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'completed', 'workout_session', v_session_id::text, NULL,
    jsonb_build_object('status', v_status, 'abandonment_reason_code', v_abandonment, 'source', 'offline_sync',
                       'assignment_occurrence_id', v_link_occ, 'occurrence_link', v_link_kind)
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.sync_offline_session_bundle_internal(jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.sync_offline_session_bundle_internal(jsonb, uuid) TO authenticated;
