-- =============================================================================
-- sync_offline_session_bundle
-- Roadmap v1.2 · Sprint 4 · Task 4.5 (Section 11, "5. sync_offline_session_bundle"
-- + "Offline Bundle Wire Format & Immutable Correlation Rules")
--
--   public.sync_offline_session_bundle(...)   SECURITY INVOKER wrapper
--     → app_private.sync_offline_session_bundle_internal   SECURITY DEFINER
--
-- Handles BOTH paths atomically, reusing the exact shared helpers Task 4.4's
-- granular RPCs use (apply_session_substitution, apply_session_set,
-- apply_session_feedback, instantiate_session_exercises, validate_abandonment)
-- so a bundle synced offline is validated by IDENTICAL rules to the granular,
-- online path — never a second, hand-maintained copy:
--   * existing_session_id present: the athlete started online, went offline,
--     and now completes an already-`in_progress` session (locked FOR UPDATE,
--     ownership verified, its workout_version_id must match the bundle's).
--   * existing_session_id absent: the whole session (start → finish) happened
--     offline; a new session and its session_exercises are created first,
--     using the CLIENT's own started_at/completed_at wall-clock timestamps
--     (the whole point of the offline record is preserving when it actually
--     happened).
-- Every item in the bundle correlates by the immutable workout_item_id, never
-- a server-generated execution id the client couldn't have known offline.
-- =============================================================================

CREATE FUNCTION app_private.sync_offline_session_bundle_internal(
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
    v_session_id := v_existing_id;
  ELSE
    -- Brand new session, completed entirely offline ------------------------------
    PERFORM 1 FROM public.profiles WHERE id = v_uid FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.workout_sessions WHERE athlete_id = v_uid AND status = 'in_progress') THEN
      RAISE EXCEPTION 'You already have an active workout session in progress' USING ERRCODE = '23505';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.workout_versions v WHERE v.id = v_workout_version_id AND v.is_sealed = true
    ) OR NOT app_private.can_view_workout_version(v_workout_version_id) THEN
      RAISE EXCEPTION 'That workout version is not available to you' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO public.workout_sessions (athlete_id, workout_version_id, status, started_at)
    VALUES (v_uid, v_workout_version_id, 'in_progress', v_started_at)
    RETURNING id INTO v_session_id;

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

  v_response := jsonb_build_object('status', 'synced', 'session_id', v_session_id);
  PERFORM app_private.complete_idempotency(v_uid, 'SYNC_BUNDLE', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'completed', 'workout_session', v_session_id::text, NULL,
    jsonb_build_object('status', v_status, 'abandonment_reason_code', v_abandonment, 'source', 'offline_sync')
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.sync_offline_session_bundle_internal(jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.sync_offline_session_bundle_internal(jsonb, uuid) TO authenticated;

CREATE FUNCTION public.sync_offline_session_bundle(p_bundle jsonb, p_idempotency_key uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.sync_offline_session_bundle_internal(p_bundle, p_idempotency_key);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.sync_offline_session_bundle(jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_offline_session_bundle(jsonb, uuid) TO authenticated;
