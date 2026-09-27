-- =============================================================================
-- workout_execution_rpcs
-- Roadmap v1.2 · Sprint 4 · Task 4.4 (Section 11, "Complete Mutation API" +
-- "Race-Safe Idempotency Acquisition Protocol")
--
--   public.start_workout_session(...)              → app_private.start_workout_session_internal
--   public.record_session_set(...)                 → app_private.record_session_set_internal
--   public.record_exercise_substitution(...)        → app_private.record_exercise_substitution_internal
--   public.complete_workout_session(...)            → app_private.complete_workout_session_internal
--
-- Every mutation is idempotent: acquire_idempotency() atomically reserves
-- (caller_id, mutation_type, key) with a row lock (ON CONFLICT DO UPDATE
-- blocks a concurrent duplicate call until the first completes) and validates
-- a SHA-256 payload hash so a reused key with a DIFFERENT payload fails closed
-- (42501) instead of silently returning the wrong cached response.
--
-- Row locking: start_workout_session locks the caller's profile FOR UPDATE
-- (serializes concurrent session starts against the partial unique index);
-- every other mutation locks the target session FOR UPDATE first (serializes
-- set recording, substitution and completion against each other; a terminal
-- session can never be mutated afterward — 22000).
--
-- Error codes: 42501 not authorized / idempotency key reused with a different
-- payload · 22023 invalid payload · 22000 illegal state (terminal session,
-- substitution after sets recorded) · 23505 duplicate (already in progress,
-- already substituted) · P0002 not found / not available.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- SHA-256 payload hashing (same core `sha256()` builtin as
-- app_private.hash_invitation_token; no pgcrypto/extensions schema needed).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.hash_payload(p_payload text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path = ''
AS $$
  SELECT encode(sha256(convert_to(p_payload, 'UTF8')), 'hex');
$$;
REVOKE EXECUTE ON FUNCTION app_private.hash_payload(text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Boolean payload reader (rounds out the workout_json_number / workout_json_text
-- family from Sprint 3's workout_create_rpc migration).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.workout_json_bool(p_obj jsonb, p_key text, p_default boolean)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
  v jsonb := p_obj -> p_key;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN p_default;
  END IF;
  IF jsonb_typeof(v) <> 'boolean' THEN
    RAISE EXCEPTION '% must be a boolean', p_key USING ERRCODE = '22023';
  END IF;
  RETURN (p_obj ->> p_key)::boolean;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.workout_json_bool(jsonb, text, boolean) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Race-Safe Idempotency Acquisition Protocol (verbatim from Section 11).
-- acquire_idempotency: atomic reservation + row lock on (caller_id,
-- mutation_type, key). A concurrent duplicate call blocks on the ON CONFLICT
-- DO UPDATE until the first transaction commits or rolls back, then either
-- returns the same cached response (first succeeded) or proceeds itself (first
-- rolled back — no reservation survives a rolled-back transaction, since the
-- INSERT is part of the same transaction as the domain mutation).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.acquire_idempotency(
  p_caller_id uuid, p_mutation_type text, p_key uuid, p_payload_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rec record;
BEGIN
  INSERT INTO app_private.idempotency_keys (caller_id, mutation_type, key, status, payload_hash)
  VALUES (p_caller_id, p_mutation_type, p_key, 'started', p_payload_hash)
  ON CONFLICT (caller_id, mutation_type, key) DO UPDATE
    SET updated_at = now()
  RETURNING status, payload_hash, response_payload INTO v_rec;

  IF v_rec.payload_hash <> p_payload_hash THEN
    RAISE EXCEPTION 'Idempotency key reused with a different payload' USING ERRCODE = '42501';
  END IF;

  IF v_rec.status = 'completed' THEN
    RETURN v_rec.response_payload;
  END IF;

  RETURN NULL;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.acquire_idempotency(uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app_private.complete_idempotency(
  p_caller_id uuid, p_mutation_type text, p_key uuid, p_response jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE app_private.idempotency_keys
  SET status = 'completed', response_payload = p_response, updated_at = now()
  WHERE caller_id = p_caller_id AND mutation_type = p_mutation_type AND key = p_key;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.complete_idempotency(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Mode-aware actual-set validation. Mirrors app_private.validate_workout_set
-- (Sprint 3) field-for-field, adapted to session_sets' actual_* columns and
-- F-S4-01's fixed load consistency rule. session_sets has no notes column
-- (Rule E), so technique_practice has no notes-only fallback.
--
-- Design note (not fully specified by the frozen text — see Sprint 4 STATUS.md
-- "Design decisions"): mode exclusivity (an exercise's actuals may only ever
-- carry the fields its mode supports) always applies, but the PRESENCE of the
-- mode's primary metric is required only when is_completed = true, so an
-- athlete can log "attempted, not completed" without a number.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.validate_session_set(
  p_mode text, p_reps integer, p_duration integer, p_distance numeric,
  p_load numeric, p_load_type text, p_rest integer, p_rpe numeric, p_is_completed boolean
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
  IF p_reps IS NOT NULL AND (p_reps < 0 OR p_reps > 1000) THEN
    RAISE EXCEPTION 'actual_reps must be between 0 and 1000' USING ERRCODE = '22023';
  END IF;
  IF p_duration IS NOT NULL AND (p_duration < 0 OR p_duration > 7200) THEN
    RAISE EXCEPTION 'actual_duration_seconds must be between 0 and 7200' USING ERRCODE = '22023';
  END IF;
  IF p_distance IS NOT NULL AND (p_distance < 0 OR p_distance > 100000) THEN
    RAISE EXCEPTION 'actual_distance_meters must be between 0 and 100000' USING ERRCODE = '22023';
  END IF;
  IF p_load IS NOT NULL AND (p_load < 0 OR p_load > 500) THEN
    RAISE EXCEPTION 'actual_load_kg must be between 0 and 500' USING ERRCODE = '22023';
  END IF;
  IF p_rest IS NOT NULL AND (p_rest < 0 OR p_rest > 1800) THEN
    RAISE EXCEPTION 'actual_rest_seconds must be between 0 and 1800' USING ERRCODE = '22023';
  END IF;
  IF p_rpe IS NOT NULL AND (p_rpe < 1 OR p_rpe > 10) THEN
    RAISE EXCEPTION 'rpe must be between 1 and 10' USING ERRCODE = '22023';
  END IF;
  IF p_load_type IS NOT NULL AND p_load_type NOT IN ('bodyweight', 'added', 'assisted') THEN
    RAISE EXCEPTION 'load_type must be bodyweight, added or assisted' USING ERRCODE = '22023';
  END IF;

  -- Mirrors session_set_load_consistency (F-S4-01 fixed).
  IF p_load IS NOT NULL AND p_load > 0 AND (p_load_type IS NULL OR p_load_type NOT IN ('added', 'assisted')) THEN
    RAISE EXCEPTION 'A load greater than 0 must have load_type added or assisted' USING ERRCODE = '22023';
  END IF;
  IF (p_load IS NULL OR p_load = 0) AND p_load_type IS NOT NULL AND p_load_type <> 'bodyweight' THEN
    RAISE EXCEPTION 'load_type % needs an actual_load_kg greater than 0', p_load_type USING ERRCODE = '22023';
  END IF;

  CASE p_mode
    WHEN 'reps' THEN
      IF p_is_completed AND p_reps IS NULL THEN
        RAISE EXCEPTION 'A completed reps set needs actual_reps' USING ERRCODE = '22023';
      END IF;
      IF p_duration IS NOT NULL OR p_distance IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A reps set takes only actual_reps (no duration, distance or load)' USING ERRCODE = '22023';
      END IF;
    WHEN 'duration', 'holds' THEN
      IF p_is_completed AND p_duration IS NULL THEN
        RAISE EXCEPTION 'A completed % set needs actual_duration_seconds', p_mode USING ERRCODE = '22023';
      END IF;
      IF p_reps IS NOT NULL OR p_distance IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A % set takes only actual_duration_seconds (no reps, distance or load)', p_mode USING ERRCODE = '22023';
      END IF;
    WHEN 'distance' THEN
      IF p_is_completed AND p_distance IS NULL THEN
        RAISE EXCEPTION 'A completed distance set needs actual_distance_meters' USING ERRCODE = '22023';
      END IF;
      IF p_reps IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A distance set takes no reps or load' USING ERRCODE = '22023';
      END IF;
    WHEN 'added_weight' THEN
      IF p_load IS NOT NULL AND p_load_type IS DISTINCT FROM 'added' THEN
        RAISE EXCEPTION 'An added_weight set''s load must be typed added' USING ERRCODE = '22023';
      END IF;
      IF p_is_completed AND (p_load IS NULL OR p_load <= 0) THEN
        RAISE EXCEPTION 'A completed added_weight set needs actual_load_kg greater than 0' USING ERRCODE = '22023';
      END IF;
      IF p_is_completed AND p_reps IS NULL AND p_duration IS NULL THEN
        RAISE EXCEPTION 'A completed added_weight set needs actual_reps or actual_duration_seconds' USING ERRCODE = '22023';
      END IF;
      IF p_distance IS NOT NULL THEN RAISE EXCEPTION 'An added_weight set takes no distance' USING ERRCODE = '22023'; END IF;
    WHEN 'assisted_weight' THEN
      IF p_load IS NOT NULL AND p_load_type IS DISTINCT FROM 'assisted' THEN
        RAISE EXCEPTION 'An assisted_weight set''s load must be typed assisted' USING ERRCODE = '22023';
      END IF;
      IF p_is_completed AND (p_load IS NULL OR p_load <= 0) THEN
        RAISE EXCEPTION 'A completed assisted_weight set needs actual_load_kg greater than 0' USING ERRCODE = '22023';
      END IF;
      IF p_is_completed AND p_reps IS NULL AND p_duration IS NULL THEN
        RAISE EXCEPTION 'A completed assisted_weight set needs actual_reps or actual_duration_seconds' USING ERRCODE = '22023';
      END IF;
      IF p_distance IS NOT NULL THEN RAISE EXCEPTION 'An assisted_weight set takes no distance' USING ERRCODE = '22023'; END IF;
    WHEN 'until_failure' THEN
      IF p_distance IS NOT NULL THEN RAISE EXCEPTION 'An until_failure set takes no distance' USING ERRCODE = '22023'; END IF;
    WHEN 'technique_practice' THEN
      IF p_distance IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A technique_practice set takes no distance or load' USING ERRCODE = '22023';
      END IF;
    ELSE
      RAISE EXCEPTION 'Unknown performed_measurement_mode %', p_mode USING ERRCODE = '22023';
  END CASE;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.validate_session_set(text, integer, integer, numeric, numeric, text, integer, numeric, boolean) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared: apply one actual set to a session_exercise (prescription lineage +
-- mode-aware validation + insert-or-update). Shared by record_session_set
-- (Task 4.4) and sync_offline_session_bundle (Task 4.5) so both realize the
-- IDENTICAL rule, never two hand-maintained copies. Assumes the caller already
-- holds the session's row lock and has verified session ownership/status.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.apply_session_set(p_session_exercise_id uuid, p_set_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_workout_item_id uuid;
  v_mode text;
  v_set_number integer;
  v_prescribed_text text;
  v_prescribed_id uuid;
  v_prescribed_item uuid;
  v_reps integer;
  v_duration integer;
  v_distance numeric;
  v_load numeric;
  v_load_type text;
  v_rest integer;
  v_rpe numeric;
  v_is_completed boolean;
  v_set_id uuid;
BEGIN
  IF jsonb_typeof(p_set_data) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Set data must be an object' USING ERRCODE = '22023';
  END IF;

  SELECT workout_item_id, performed_measurement_mode INTO v_workout_item_id, v_mode
  FROM public.session_exercises WHERE id = p_session_exercise_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That exercise is not part of this session' USING ERRCODE = '22000';
  END IF;

  v_set_number := app_private.workout_json_number(p_set_data, 'set_number', true)::integer;
  IF v_set_number IS NULL OR v_set_number < 1 THEN
    RAISE EXCEPTION 'set_number must be at least 1' USING ERRCODE = '22023';
  END IF;

  -- Prescription lineage verification: a supplied prescribed_item_set_id must
  -- belong to THIS exercise's prescribed item (never an unrelated one).
  v_prescribed_text := app_private.workout_json_text(p_set_data, 'prescribed_item_set_id', 64);
  IF v_prescribed_text IS NOT NULL THEN
    BEGIN
      v_prescribed_id := v_prescribed_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'prescribed_item_set_id must be a valid id' USING ERRCODE = '22023';
    END;
    SELECT workout_item_id INTO v_prescribed_item FROM public.workout_item_sets WHERE id = v_prescribed_id;
    IF NOT FOUND OR v_prescribed_item IS DISTINCT FROM v_workout_item_id THEN
      RAISE EXCEPTION 'prescribed_item_set_id does not belong to this exercise''s prescription' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_reps := app_private.workout_json_number(p_set_data, 'actual_reps', true)::integer;
  v_duration := app_private.workout_json_number(p_set_data, 'actual_duration_seconds', true)::integer;
  v_distance := app_private.workout_json_number(p_set_data, 'actual_distance_meters');
  v_load := app_private.workout_json_number(p_set_data, 'actual_load_kg');
  v_load_type := app_private.workout_json_text(p_set_data, 'load_type', 20);
  v_rest := app_private.workout_json_number(p_set_data, 'actual_rest_seconds', true)::integer;
  v_rpe := app_private.workout_json_number(p_set_data, 'rpe');
  v_is_completed := app_private.workout_json_bool(p_set_data, 'is_completed', true);

  PERFORM app_private.validate_session_set(
    v_mode, v_reps, v_duration, v_distance, v_load, v_load_type, v_rest, v_rpe, v_is_completed
  );

  INSERT INTO public.session_sets (
    session_exercise_id, prescribed_item_set_id, set_number, actual_reps, actual_load_kg, load_type,
    actual_duration_seconds, actual_distance_meters, actual_rest_seconds, rpe, is_completed
  )
  VALUES (
    p_session_exercise_id, v_prescribed_id, v_set_number, v_reps, v_load, v_load_type,
    v_duration, v_distance, v_rest, v_rpe, v_is_completed
  )
  ON CONFLICT ON CONSTRAINT uq_session_set_number DO UPDATE SET
    prescribed_item_set_id = excluded.prescribed_item_set_id,
    actual_reps = excluded.actual_reps,
    actual_load_kg = excluded.actual_load_kg,
    load_type = excluded.load_type,
    actual_duration_seconds = excluded.actual_duration_seconds,
    actual_distance_meters = excluded.actual_distance_meters,
    actual_rest_seconds = excluded.actual_rest_seconds,
    rpe = excluded.rpe,
    is_completed = excluded.is_completed
  RETURNING id INTO v_set_id;

  RETURN jsonb_build_object('set_id', v_set_id, 'set_number', v_set_number);
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.apply_session_set(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared: apply one exercise substitution (Option A single-substitution rule +
-- F-S4-P14 lineage invariant + exercise accessibility/mode checks + the
-- session_exercises update). Shared by record_exercise_substitution (Task 4.4)
-- and sync_offline_session_bundle (Task 4.5). Assumes the caller already holds
-- the session's row lock and has verified session ownership/status; the AFTER
-- INSERT trigger on session_modifications (Task 4.3) writes the single,
-- uniformly-redacted audit row.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.apply_session_substitution(
  p_session_id uuid,
  p_uid uuid,
  p_original_workout_item_id uuid,
  p_replacement_exercise_id uuid,
  p_performed_measurement_mode text,
  p_reason_code text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_session_exercise_id uuid;
  v_replacement public.exercises%ROWTYPE;
BEGIN
  SELECT id INTO v_session_exercise_id FROM public.session_exercises
  WHERE session_id = p_session_id AND workout_item_id = p_original_workout_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prescribed item not found in session' USING ERRCODE = '22000';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.session_modifications
    WHERE session_id = p_session_id AND original_workout_item_id = p_original_workout_item_id
  ) THEN
    RAISE EXCEPTION 'This exercise has already been substituted in this session' USING ERRCODE = '23505';
  END IF;

  IF EXISTS (SELECT 1 FROM public.session_sets WHERE session_exercise_id = v_session_exercise_id) THEN
    RAISE EXCEPTION 'Cannot substitute an exercise after sets have been recorded' USING ERRCODE = '22000';
  END IF;

  IF p_reason_code IS NULL OR p_reason_code NOT IN (
    'equipment_unavailable', 'pain_discomfort', 'too_difficult',
    'too_easy', 'injury_limitation', 'personal_adjustment', 'other'
  ) THEN
    RAISE EXCEPTION 'A valid substitution reason is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_replacement FROM public.exercises WHERE id = p_replacement_exercise_id;
  IF NOT FOUND OR NOT (
    (v_replacement.status = 'approved' AND v_replacement.is_official)
    OR v_replacement.created_by = p_uid
  ) THEN
    RAISE EXCEPTION 'That exercise is not available to you' USING ERRCODE = '22023';
  END IF;

  IF p_performed_measurement_mode IS NULL
     OR p_performed_measurement_mode NOT IN (
       'reps', 'duration', 'holds', 'distance', 'until_failure',
       'added_weight', 'assisted_weight', 'technique_practice'
     )
     OR NOT (p_performed_measurement_mode = ANY (v_replacement.measurement_types)) THEN
    RAISE EXCEPTION '% does not support the measurement mode %', v_replacement.name, p_performed_measurement_mode
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.session_modifications (session_id, original_workout_item_id, replacement_exercise_id, reason_code)
  VALUES (p_session_id, p_original_workout_item_id, p_replacement_exercise_id, p_reason_code);

  UPDATE public.session_exercises
  SET exercise_id = p_replacement_exercise_id, is_substituted = true, performed_measurement_mode = p_performed_measurement_mode
  WHERE id = v_session_exercise_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.apply_session_substitution(uuid, uuid, uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared: instantiate one session_exercises row per prescribed item of a
-- sealed version, in block/item order. Shared by start_workout_session (Task
-- 4.4) and the brand-new-offline-session path of sync_offline_session_bundle
-- (Task 4.5).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.instantiate_session_exercises(p_session_id uuid, p_workout_version_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_order integer := 0;
  v_item record;
BEGIN
  FOR v_item IN
    SELECT i.id AS workout_item_id, i.exercise_id, i.measurement_mode
    FROM public.workout_items i
    JOIN public.workout_blocks b ON b.id = i.block_id
    WHERE b.workout_version_id = p_workout_version_id
    ORDER BY b.order_in_workout, i.order_in_block
  LOOP
    v_order := v_order + 1;
    INSERT INTO public.session_exercises
      (session_id, workout_item_id, exercise_id, order_in_session, is_substituted, performed_measurement_mode)
    VALUES
      (p_session_id, v_item.workout_item_id, v_item.exercise_id, v_order, false, v_item.measurement_mode);
  END LOOP;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.instantiate_session_exercises(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared: bidirectional abandonment reason consistency (mirrors
-- session_abandoned_reason_consistency). Shared by complete_workout_session
-- (Task 4.4) and sync_offline_session_bundle (Task 4.5).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.validate_abandonment(p_status text, p_abandonment_reason_code text)
RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
  IF p_status = 'abandoned' THEN
    IF p_abandonment_reason_code IS NULL OR p_abandonment_reason_code NOT IN (
      'time_constraint', 'equipment_issue', 'general_fatigue', 'personal_emergency', 'facility_closed', 'other'
    ) THEN
      RAISE EXCEPTION 'A valid abandonment reason code is required' USING ERRCODE = '22000';
    END IF;
  ELSIF p_abandonment_reason_code IS NOT NULL THEN
    RAISE EXCEPTION 'An abandonment reason must be empty for a completed session' USING ERRCODE = '22000';
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.validate_abandonment(text, text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared: apply the Rule E split feedback (ordinary + private) on session
-- completion. Shared by complete_workout_session (Task 4.4) and
-- sync_offline_session_bundle (Task 4.5). Each insert fires its own
-- AFTER INSERT trigger where one exists (session_private_feedback, Task 4.3).
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.apply_session_feedback(p_session_id uuid, p_feedback jsonb, p_private_feedback jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_difficulty integer;
  v_energy integer;
  v_has_discomfort boolean;
  v_discomfort_area text;
  v_note text;
BEGIN
  IF p_feedback IS NOT NULL THEN
    v_difficulty := app_private.workout_json_number(p_feedback, 'difficulty_rating', true)::integer;
    v_energy := app_private.workout_json_number(p_feedback, 'energy_level', true)::integer;
    IF v_difficulty IS NULL OR v_difficulty < 1 OR v_difficulty > 10 THEN
      RAISE EXCEPTION 'difficulty_rating must be between 1 and 10' USING ERRCODE = '22023';
    END IF;
    IF v_energy IS NULL OR v_energy < 1 OR v_energy > 5 THEN
      RAISE EXCEPTION 'energy_level must be between 1 and 5' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.session_feedback (session_id, difficulty_rating, energy_level)
    VALUES (p_session_id, v_difficulty, v_energy);
  END IF;

  IF p_private_feedback IS NOT NULL THEN
    v_has_discomfort := app_private.workout_json_bool(p_private_feedback, 'has_discomfort', false);
    v_discomfort_area := app_private.workout_json_text(p_private_feedback, 'discomfort_area', 100);
    v_note := app_private.workout_json_text(p_private_feedback, 'note_to_coach', 1000);
    IF v_has_discomfort AND v_discomfort_area IS NULL THEN
      RAISE EXCEPTION 'discomfort_area is required when has_discomfort is true' USING ERRCODE = '22023';
    END IF;
    IF NOT v_has_discomfort AND v_discomfort_area IS NOT NULL THEN
      RAISE EXCEPTION 'discomfort_area must be empty when has_discomfort is false' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.session_private_feedback (session_id, has_discomfort, discomfort_area, note_to_coach)
    VALUES (p_session_id, v_has_discomfort, v_discomfort_area, v_note);
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.apply_session_feedback(uuid, jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 1. start_workout_session
-- =============================================================================
CREATE FUNCTION app_private.start_workout_session_internal(
  p_workout_version_id uuid, p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_hash text;
  v_cached jsonb;
  v_version public.workout_versions%ROWTYPE;
  v_session_id uuid;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(p_workout_version_id::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'START_SESSION', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  -- Serializes concurrent session starts by the same athlete.
  PERFORM 1 FROM public.profiles WHERE id = v_uid FOR UPDATE;

  IF EXISTS (SELECT 1 FROM public.workout_sessions WHERE athlete_id = v_uid AND status = 'in_progress') THEN
    RAISE EXCEPTION 'You already have an active workout session in progress' USING ERRCODE = '23505';
  END IF;

  SELECT * INTO v_version FROM public.workout_versions WHERE id = p_workout_version_id;
  IF NOT FOUND OR NOT v_version.is_sealed OR NOT app_private.can_view_workout_version(p_workout_version_id) THEN
    RAISE EXCEPTION 'That workout version is not available to you' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.workout_sessions (athlete_id, workout_version_id, status, started_at)
  VALUES (v_uid, p_workout_version_id, 'in_progress', now())
  RETURNING id INTO v_session_id;

  PERFORM app_private.instantiate_session_exercises(v_session_id, p_workout_version_id);

  v_response := jsonb_build_object(
    'session_id', v_session_id,
    'status', 'in_progress',
    'exercise_mapping', (
      SELECT COALESCE(jsonb_object_agg(workout_item_id::text, id::text), '{}'::jsonb)
      FROM public.session_exercises WHERE session_id = v_session_id
    )
  );
  PERFORM app_private.complete_idempotency(v_uid, 'START_SESSION', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'started', 'workout_session', v_session_id::text, NULL,
    jsonb_build_object('workout_version_id', p_workout_version_id)
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.start_workout_session_internal(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.start_workout_session_internal(uuid, uuid) TO authenticated;

CREATE FUNCTION public.start_workout_session(p_workout_version_id uuid, p_idempotency_key uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.start_workout_session_internal(p_workout_version_id, p_idempotency_key);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.start_workout_session(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_workout_session(uuid, uuid) TO authenticated;

-- =============================================================================
-- 2. record_session_set
-- =============================================================================
CREATE FUNCTION app_private.record_session_set_internal(
  p_session_id uuid, p_session_exercise_id uuid, p_set_data jsonb, p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_hash text;
  v_cached jsonb;
  v_session public.workout_sessions%ROWTYPE;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'session_id', p_session_id, 'session_exercise_id', p_session_exercise_id, 'set_data', p_set_data
  )::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'RECORD_SET', p_idempotency_key, v_hash);
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

  IF NOT EXISTS (
    SELECT 1 FROM public.session_exercises WHERE id = p_session_exercise_id AND session_id = p_session_id
  ) THEN
    RAISE EXCEPTION 'That exercise is not part of this session' USING ERRCODE = '22000';
  END IF;

  v_response := app_private.apply_session_set(p_session_exercise_id, p_set_data);
  PERFORM app_private.complete_idempotency(v_uid, 'RECORD_SET', p_idempotency_key, v_response);
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.record_session_set_internal(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.record_session_set_internal(uuid, uuid, jsonb, uuid) TO authenticated;

CREATE FUNCTION public.record_session_set(
  p_session_id uuid, p_session_exercise_id uuid, p_set_data jsonb, p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.record_session_set_internal(p_session_id, p_session_exercise_id, p_set_data, p_idempotency_key);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.record_session_set(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_session_set(uuid, uuid, jsonb, uuid) TO authenticated;

-- =============================================================================
-- 3. record_exercise_substitution
-- =============================================================================
CREATE FUNCTION app_private.record_exercise_substitution_internal(
  p_session_id uuid,
  p_original_workout_item_id uuid,
  p_replacement_exercise_id uuid,
  p_performed_measurement_mode text,
  p_reason_code text,
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
  v_session_exercise_id uuid;
  v_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'session_id', p_session_id, 'original_workout_item_id', p_original_workout_item_id,
    'replacement_exercise_id', p_replacement_exercise_id,
    'performed_measurement_mode', p_performed_measurement_mode, 'reason_code', p_reason_code
  )::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'SUBSTITUTE_EXERCISE', p_idempotency_key, v_hash);
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

  PERFORM app_private.apply_session_substitution(
    p_session_id, v_uid, p_original_workout_item_id, p_replacement_exercise_id,
    p_performed_measurement_mode, p_reason_code
  );
  SELECT id INTO v_session_exercise_id FROM public.session_exercises
  WHERE session_id = p_session_id AND workout_item_id = p_original_workout_item_id;

  v_response := jsonb_build_object('status', 'substituted', 'session_id', p_session_id, 'session_exercise_id', v_session_exercise_id);
  PERFORM app_private.complete_idempotency(v_uid, 'SUBSTITUTE_EXERCISE', p_idempotency_key, v_response);
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.record_exercise_substitution_internal(uuid, uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.record_exercise_substitution_internal(uuid, uuid, uuid, text, text, uuid) TO authenticated;

CREATE FUNCTION public.record_exercise_substitution(
  p_session_id uuid,
  p_original_workout_item_id uuid,
  p_replacement_exercise_id uuid,
  p_performed_measurement_mode text,
  p_reason_code text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.record_exercise_substitution_internal(
    p_session_id, p_original_workout_item_id, p_replacement_exercise_id,
    p_performed_measurement_mode, p_reason_code, p_idempotency_key
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.record_exercise_substitution(uuid, uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_exercise_substitution(uuid, uuid, uuid, text, text, uuid) TO authenticated;

-- =============================================================================
-- 4. complete_workout_session
-- =============================================================================
CREATE FUNCTION app_private.complete_workout_session_internal(
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
  WHERE id = p_session_id;

  PERFORM app_private.apply_session_feedback(p_session_id, p_feedback, p_private_feedback);

  v_response := jsonb_build_object('session_id', p_session_id, 'status', p_status);
  PERFORM app_private.complete_idempotency(v_uid, 'COMPLETE_SESSION', p_idempotency_key, v_response);
  PERFORM app_private.write_audit_event(
    'completed', 'workout_session', p_session_id::text, NULL,
    jsonb_build_object('status', p_status, 'abandonment_reason_code', p_abandonment_reason_code)
  );
  RETURN v_response;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.complete_workout_session_internal(uuid, text, text, jsonb, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.complete_workout_session_internal(uuid, text, text, jsonb, jsonb, uuid) TO authenticated;

CREATE FUNCTION public.complete_workout_session(
  p_session_id uuid,
  p_status text,
  p_abandonment_reason_code text,
  p_feedback jsonb,
  p_private_feedback jsonb,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;
  RETURN app_private.complete_workout_session_internal(
    p_session_id, p_status, p_abandonment_reason_code, p_feedback, p_private_feedback, p_idempotency_key
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.complete_workout_session(uuid, text, text, jsonb, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_workout_session(uuid, text, text, jsonb, jsonb, uuid) TO authenticated;
