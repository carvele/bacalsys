-- =============================================================================
-- workout_create_rpc
-- Roadmap v1.2 · Sprint 3 · Task 3.6 (Section 10, "Complete Mutation API")
--
-- Shared building blocks for every workout mutation RPC (create / publish /
-- clone / visibility / metadata / archive) plus the atomic creation RPC:
--
--   public.create_workout_template(...)            SECURITY INVOKER wrapper
--     → app_private.create_workout_template_internal   SECURITY DEFINER
--
-- Payload (p_blocks, jsonb) — array order IS the order; order_in_workout,
-- order_in_block and set_number are derived from position, so contiguity from 1
-- holds by construction:
--   [{ "title": "Primary Strength", "block_type": "superset",
--      "circuit_rounds": null, "amrap_duration_seconds": null, "notes": null,
--      "items": [{ "exercise_id": "<uuid>", "measurement_mode": "added_weight", "notes": null,
--                  "sets": [{ "target_reps": 5, "target_load_kg": 10, "load_type": "added",
--                             "target_duration_seconds": null, "target_distance_meters": null,
--                             "target_rest_seconds": 120, "target_rpe": 7.5, "notes": null }] }] }]
--
-- Limits: 1–20 blocks, 1–30 items per block, 1–50 sets per item, 500 sets total.
-- Error codes: 42501 not authorized / no organization context · 22023 invalid
-- payload · P0002 not found · 55000 illegal state.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Audit helper for RPC-level events (created / version_published / cloned / ...).
-- The audit table has no client-writable path; only SECURITY DEFINER code calls this.
-- Actor resolution mirrors app_private.log_audit_event().
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.write_audit_event(
  p_action text, p_entity_type text, p_entity_id text, p_old jsonb, p_new jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_setting text := current_setting('bacalsys.actor_type', true);
  v_actor_type public.audit_actor_type;
BEGIN
  IF v_uid IS NOT NULL THEN
    v_actor_type := 'user';
  ELSIF v_setting IN ('system', 'cron', 'migration') THEN
    v_actor_type := v_setting::public.audit_actor_type;
  ELSE
    v_actor_type := 'system';
  END IF;

  INSERT INTO public.audit_logs (actor_user_id, actor_type, action, entity_type, entity_id, old_values, new_values)
  VALUES (v_uid, v_actor_type, p_action, p_entity_type, p_entity_id, p_old, p_new);
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.write_audit_event(text, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Payload readers: typed extraction with member-readable 22023 errors.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.workout_json_number(p_obj jsonb, p_key text, p_integer boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
  v jsonb := p_obj -> p_key;
  n numeric;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'number' THEN
    RAISE EXCEPTION '% must be a number', p_key USING ERRCODE = '22023';
  END IF;
  n := (v #>> '{}')::numeric;
  IF p_integer AND n <> trunc(n) THEN
    RAISE EXCEPTION '% must be a whole number', p_key USING ERRCODE = '22023';
  END IF;
  RETURN n;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.workout_json_number(jsonb, text, boolean) FROM PUBLIC, anon, authenticated;

-- Trimmed text, NULL when absent or blank.
CREATE FUNCTION app_private.workout_json_text(p_obj jsonb, p_key text, p_max integer, p_required boolean DEFAULT false)
RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
  v jsonb := p_obj -> p_key;
  t text;
BEGIN
  IF v IS NOT NULL AND jsonb_typeof(v) NOT IN ('null', 'string') THEN
    RAISE EXCEPTION '% must be text', p_key USING ERRCODE = '22023';
  END IF;
  t := nullif(btrim(COALESCE(v #>> '{}', '')), '');
  IF t IS NULL AND p_required THEN
    RAISE EXCEPTION '% is required', p_key USING ERRCODE = '22023';
  END IF;
  IF t IS NOT NULL AND length(t) > p_max THEN
    RAISE EXCEPTION '% must be at most % characters', p_key, p_max USING ERRCODE = '22023';
  END IF;
  RETURN t;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.workout_json_text(jsonb, text, integer, boolean) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Mode-aware set validation (Section 10 "Mode-Aware Set Validation Rules").
-- Range checks mirror the workout_item_sets CHECK constraints, with readable text.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.validate_workout_set(
  p_mode text,
  p_reps integer, p_duration integer, p_distance numeric,
  p_load numeric, p_load_type text, p_rest integer, p_rpe numeric, p_notes text
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
  IF p_reps IS NOT NULL AND (p_reps < 1 OR p_reps > 1000) THEN
    RAISE EXCEPTION 'target_reps must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;
  IF p_duration IS NOT NULL AND (p_duration < 1 OR p_duration > 7200) THEN
    RAISE EXCEPTION 'target_duration_seconds must be between 1 and 7200' USING ERRCODE = '22023';
  END IF;
  IF p_distance IS NOT NULL AND (p_distance <= 0 OR p_distance > 100000) THEN
    RAISE EXCEPTION 'target_distance_meters must be greater than 0 and at most 100000' USING ERRCODE = '22023';
  END IF;
  IF p_load IS NOT NULL AND (p_load < 0 OR p_load > 500) THEN
    RAISE EXCEPTION 'target_load_kg must be between 0 and 500' USING ERRCODE = '22023';
  END IF;
  IF p_rest IS NOT NULL AND (p_rest < 0 OR p_rest > 1800) THEN
    RAISE EXCEPTION 'target_rest_seconds must be between 0 and 1800' USING ERRCODE = '22023';
  END IF;
  IF p_rpe IS NOT NULL AND (p_rpe < 1 OR p_rpe > 10) THEN
    RAISE EXCEPTION 'target_rpe must be between 1 and 10' USING ERRCODE = '22023';
  END IF;
  IF p_load_type IS NOT NULL AND p_load_type NOT IN ('bodyweight', 'added', 'assisted') THEN
    RAISE EXCEPTION 'load_type must be bodyweight, added or assisted' USING ERRCODE = '22023';
  END IF;

  -- A load, when present, must be positive and typed; without one the set is bodyweight.
  IF p_load IS NOT NULL AND (p_load <= 0 OR p_load_type IS NULL OR p_load_type NOT IN ('added', 'assisted')) THEN
    RAISE EXCEPTION 'A load must be greater than 0 with load_type added or assisted' USING ERRCODE = '22023';
  END IF;
  IF p_load IS NULL AND p_load_type IS NOT NULL AND p_load_type <> 'bodyweight' THEN
    RAISE EXCEPTION 'load_type % needs a target_load_kg', p_load_type USING ERRCODE = '22023';
  END IF;

  CASE p_mode
    WHEN 'reps' THEN
      IF p_reps IS NULL THEN RAISE EXCEPTION 'A reps set needs target_reps' USING ERRCODE = '22023'; END IF;
      IF p_duration IS NOT NULL OR p_distance IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A reps set takes only target_reps (no duration, distance or load)' USING ERRCODE = '22023';
      END IF;
    WHEN 'duration', 'holds' THEN
      IF p_duration IS NULL THEN RAISE EXCEPTION 'A % set needs target_duration_seconds', p_mode USING ERRCODE = '22023'; END IF;
      IF p_reps IS NOT NULL OR p_distance IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A % set takes only target_duration_seconds (no reps, distance or load)', p_mode USING ERRCODE = '22023';
      END IF;
    WHEN 'distance' THEN
      IF p_distance IS NULL THEN RAISE EXCEPTION 'A distance set needs target_distance_meters' USING ERRCODE = '22023'; END IF;
      IF p_reps IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A distance set takes no reps or load' USING ERRCODE = '22023';
      END IF;
    WHEN 'added_weight' THEN
      IF p_load IS NULL OR p_load_type IS DISTINCT FROM 'added' THEN
        RAISE EXCEPTION 'An added_weight set needs target_load_kg greater than 0 with load_type added' USING ERRCODE = '22023';
      END IF;
      IF p_reps IS NULL AND p_duration IS NULL THEN
        RAISE EXCEPTION 'An added_weight set needs target_reps or target_duration_seconds' USING ERRCODE = '22023';
      END IF;
      IF p_distance IS NOT NULL THEN RAISE EXCEPTION 'An added_weight set takes no distance' USING ERRCODE = '22023'; END IF;
    WHEN 'assisted_weight' THEN
      IF p_load IS NULL OR p_load_type IS DISTINCT FROM 'assisted' THEN
        RAISE EXCEPTION 'An assisted_weight set needs target_load_kg greater than 0 with load_type assisted' USING ERRCODE = '22023';
      END IF;
      IF p_reps IS NULL AND p_duration IS NULL THEN
        RAISE EXCEPTION 'An assisted_weight set needs target_reps or target_duration_seconds' USING ERRCODE = '22023';
      END IF;
      IF p_distance IS NOT NULL THEN RAISE EXCEPTION 'An assisted_weight set takes no distance' USING ERRCODE = '22023'; END IF;
    WHEN 'until_failure' THEN
      -- A fixed rep target is not required; load and duration are optional.
      IF p_distance IS NOT NULL THEN RAISE EXCEPTION 'An until_failure set takes no distance' USING ERRCODE = '22023'; END IF;
    WHEN 'technique_practice' THEN
      IF p_distance IS NOT NULL OR p_load IS NOT NULL THEN
        RAISE EXCEPTION 'A technique_practice set takes no distance or load' USING ERRCODE = '22023';
      END IF;
      IF p_reps IS NULL AND p_duration IS NULL AND p_notes IS NULL THEN
        RAISE EXCEPTION 'A technique_practice set needs target_reps, target_duration_seconds or notes' USING ERRCODE = '22023';
      END IF;
    ELSE
      RAISE EXCEPTION 'Unknown measurement_mode %', p_mode USING ERRCODE = '22023';
  END CASE;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.validate_workout_set(text, integer, integer, numeric, numeric, text, integer, numeric, text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Validates the nested payload and inserts blocks → items → sets under an
-- UNSEALED version. Runs inside the caller's transaction, so any failure rolls
-- back the whole hierarchy: never a partial version.
--   p_actor          the member whose private exercises may be used
--   p_approved_only  true for organization-visible routines (approved exercises only)
-- Returns the inserted counts.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.build_workout_version(
  p_version_id uuid, p_blocks jsonb, p_actor uuid, p_approved_only boolean
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_block jsonb;
  v_item jsonb;
  v_set jsonb;
  v_block_idx integer;
  v_item_idx integer;
  v_set_idx integer;
  v_block_id uuid;
  v_item_id uuid;
  v_title text;
  v_block_type text;
  v_rounds integer;
  v_amrap integer;
  v_exercise_id uuid;
  v_mode text;
  v_ex public.exercises%ROWTYPE;
  v_reps integer;
  v_duration integer;
  v_distance numeric;
  v_load numeric;
  v_load_type text;
  v_rest integer;
  v_rpe numeric;
  v_set_notes text;
  v_n_blocks integer := 0;
  v_n_items integer := 0;
  v_n_sets integer := 0;
BEGIN
  IF jsonb_typeof(p_blocks) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'A workout needs between 1 and 20 blocks' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_blocks) NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'A workout needs between 1 and 20 blocks' USING ERRCODE = '22023';
  END IF;

  FOR v_block, v_block_idx IN
    SELECT b.value, b.ordinality::integer FROM jsonb_array_elements(p_blocks) WITH ORDINALITY AS b(value, ordinality)
  LOOP
    IF jsonb_typeof(v_block) <> 'object' THEN
      RAISE EXCEPTION 'Block % is malformed', v_block_idx USING ERRCODE = '22023';
    END IF;

    v_title := app_private.workout_json_text(v_block, 'title', 100, true);
    v_block_type := app_private.workout_json_text(v_block, 'block_type', 20, true);
    IF v_block_type NOT IN ('standard_set', 'superset', 'circuit', 'amrap') THEN
      RAISE EXCEPTION 'Block % has an unknown block_type', v_block_idx USING ERRCODE = '22023';
    END IF;
    v_rounds := app_private.workout_json_number(v_block, 'circuit_rounds', true)::integer;
    v_amrap := app_private.workout_json_number(v_block, 'amrap_duration_seconds', true)::integer;

    IF v_block_type = 'amrap' AND (v_amrap IS NULL OR v_amrap < 30) THEN
      RAISE EXCEPTION 'AMRAP block % needs a duration of at least 30 seconds', v_block_idx USING ERRCODE = '22023';
    END IF;
    IF v_block_type <> 'amrap' AND v_amrap IS NOT NULL THEN
      RAISE EXCEPTION 'Only AMRAP blocks take a duration (block %)', v_block_idx USING ERRCODE = '22023';
    END IF;
    IF v_block_type = 'circuit' AND (v_rounds IS NULL OR v_rounds < 1) THEN
      RAISE EXCEPTION 'Circuit block % needs at least 1 round', v_block_idx USING ERRCODE = '22023';
    END IF;
    IF v_block_type <> 'circuit' AND v_rounds IS NOT NULL THEN
      RAISE EXCEPTION 'Only circuit blocks take a round count (block %)', v_block_idx USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_block -> 'items') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Block % needs between 1 and 30 exercises', v_block_idx USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(v_block -> 'items') NOT BETWEEN 1 AND 30 THEN
      RAISE EXCEPTION 'Block % needs between 1 and 30 exercises', v_block_idx USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.workout_blocks
      (workout_version_id, order_in_workout, title, block_type, circuit_rounds, amrap_duration_seconds, notes)
    VALUES
      (p_version_id, v_block_idx, v_title, v_block_type, v_rounds, v_amrap,
       app_private.workout_json_text(v_block, 'notes', 500))
    RETURNING id INTO v_block_id;
    v_n_blocks := v_n_blocks + 1;

    FOR v_item, v_item_idx IN
      SELECT i.value, i.ordinality::integer FROM jsonb_array_elements(v_block -> 'items') WITH ORDINALITY AS i(value, ordinality)
    LOOP
      IF jsonb_typeof(v_item) <> 'object' THEN
        RAISE EXCEPTION 'Exercise % of block % is malformed', v_item_idx, v_block_idx USING ERRCODE = '22023';
      END IF;

      BEGIN
        v_exercise_id := (app_private.workout_json_text(v_item, 'exercise_id', 64, true))::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Exercise % of block % has an invalid exercise_id', v_item_idx, v_block_idx USING ERRCODE = '22023';
      END;
      v_mode := app_private.workout_json_text(v_item, 'measurement_mode', 30, true);

      SELECT * INTO v_ex FROM public.exercises WHERE id = v_exercise_id;
      IF NOT FOUND
         OR NOT ((v_ex.status = 'approved' AND v_ex.is_official)
                 OR (NOT p_approved_only AND v_ex.created_by = p_actor)) THEN
        RAISE EXCEPTION 'Exercise % of block % is not available for this routine', v_item_idx, v_block_idx
          USING ERRCODE = '22023';
      END IF;
      IF v_mode NOT IN ('reps', 'duration', 'holds', 'distance', 'until_failure',
                        'added_weight', 'assisted_weight', 'technique_practice')
         OR NOT (v_mode = ANY (v_ex.measurement_types)) THEN
        RAISE EXCEPTION '% does not support the measurement mode %', v_ex.name, v_mode USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_item -> 'sets') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION '% needs between 1 and 50 sets', v_ex.name USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_item -> 'sets') NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION '% needs between 1 and 50 sets', v_ex.name USING ERRCODE = '22023';
      END IF;

      INSERT INTO public.workout_items (block_id, exercise_id, order_in_block, measurement_mode, notes)
      VALUES (v_block_id, v_exercise_id, v_item_idx, v_mode, app_private.workout_json_text(v_item, 'notes', 500))
      RETURNING id INTO v_item_id;
      v_n_items := v_n_items + 1;

      FOR v_set, v_set_idx IN
        SELECT s.value, s.ordinality::integer FROM jsonb_array_elements(v_item -> 'sets') WITH ORDINALITY AS s(value, ordinality)
      LOOP
        IF jsonb_typeof(v_set) <> 'object' THEN
          RAISE EXCEPTION 'Set % of % is malformed', v_set_idx, v_ex.name USING ERRCODE = '22023';
        END IF;
        v_n_sets := v_n_sets + 1;
        IF v_n_sets > 500 THEN
          RAISE EXCEPTION 'A workout can have at most 500 sets' USING ERRCODE = '22023';
        END IF;

        v_reps := app_private.workout_json_number(v_set, 'target_reps', true)::integer;
        v_duration := app_private.workout_json_number(v_set, 'target_duration_seconds', true)::integer;
        v_distance := app_private.workout_json_number(v_set, 'target_distance_meters');
        v_load := app_private.workout_json_number(v_set, 'target_load_kg');
        v_load_type := app_private.workout_json_text(v_set, 'load_type', 20);
        v_rest := app_private.workout_json_number(v_set, 'target_rest_seconds', true)::integer;
        v_rpe := app_private.workout_json_number(v_set, 'target_rpe');
        v_set_notes := app_private.workout_json_text(v_set, 'notes', 500);

        PERFORM app_private.validate_workout_set(
          v_mode, v_reps, v_duration, v_distance, v_load, v_load_type, v_rest, v_rpe, v_set_notes
        );

        INSERT INTO public.workout_item_sets
          (workout_item_id, set_number, target_reps, target_duration_seconds, target_distance_meters,
           target_load_kg, load_type, target_rest_seconds, target_rpe, notes)
        VALUES
          (v_item_id, v_set_idx, v_reps, v_duration, v_distance, v_load, v_load_type, v_rest, v_rpe, v_set_notes);
      END LOOP;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('blocks', v_n_blocks, 'items', v_n_items, 'sets', v_n_sets);
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.build_workout_version(uuid, jsonb, uuid, boolean) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Seals a fully built version. The trigger stamps sealed_at and from this point
-- the version and all descendants are immutable.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.seal_workout_version(p_version_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.workout_versions SET is_sealed = true WHERE id = p_version_id AND is_sealed = false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout version % could not be sealed', p_version_id USING ERRCODE = '55000';
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.seal_workout_version(uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- D5 temporal authority to mutate (publish a version, edit metadata, archive).
--   private       the creator, even after moving organizations
--   organization  same current organization AND
--                 ((creator AND workouts:publish_org) OR workouts:manage_org)
-- Fails closed when the caller has no organization context.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.can_mutate_workout_template(p_template public.workout_templates)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  IF p_template.visibility = 'private' THEN
    RETURN p_template.created_by = v_uid;
  END IF;

  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NULL OR p_template.organization_id IS DISTINCT FROM v_current_org THEN
    RETURN false;
  END IF;

  RETURN (p_template.created_by = v_uid AND app_private.has_permission('workouts:publish_org'))
      OR app_private.has_permission('workouts:manage_org');
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_mutate_workout_template(public.workout_templates) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- create_workout_template
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.create_workout_template_internal(
  p_name text, p_description text, p_visibility text, p_blocks jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
  v_name text := btrim(COALESCE(p_name, ''));
  v_description text := nullif(btrim(COALESCE(p_description, '')), '');
  v_template_id uuid;
  v_version_id uuid;
  v_counts jsonb;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NULL THEN
    RAISE EXCEPTION 'Active organization context required' USING ERRCODE = '42501';
  END IF;

  IF p_visibility IS NULL OR p_visibility NOT IN ('private', 'organization') THEN
    RAISE EXCEPTION 'visibility must be private or organization' USING ERRCODE = '22023';
  END IF;
  IF p_visibility = 'organization' AND NOT app_private.has_permission('workouts:publish_org') THEN
    RAISE EXCEPTION 'You do not have permission to create organization workout templates' USING ERRCODE = '42501';
  END IF;
  IF v_name = '' OR length(v_name) > 100 THEN
    RAISE EXCEPTION 'A routine name of 1 to 100 characters is required' USING ERRCODE = '22023';
  END IF;
  IF v_description IS NOT NULL AND length(v_description) > 1000 THEN
    RAISE EXCEPTION 'The description can be at most 1000 characters' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.workout_templates (organization_id, name, description, visibility, created_by)
  VALUES (v_current_org, v_name, v_description, p_visibility, v_uid)
  RETURNING id INTO v_template_id;

  INSERT INTO public.workout_versions (template_id, version_number, notes, created_by, is_sealed)
  VALUES (v_template_id, 1, NULL, v_uid, false)
  RETURNING id INTO v_version_id;

  v_counts := app_private.build_workout_version(v_version_id, p_blocks, v_uid, p_visibility = 'organization');
  PERFORM app_private.seal_workout_version(v_version_id);

  PERFORM app_private.write_audit_event(
    'created', 'workout_template', v_template_id::text, NULL,
    jsonb_build_object(
      'name', v_name, 'visibility', p_visibility, 'organization_id', v_current_org,
      'version_id', v_version_id, 'version_number', 1
    ) || v_counts
  );

  RETURN jsonb_build_object('template_id', v_template_id, 'version_id', v_version_id, 'version_number', 1);
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.create_workout_template_internal(text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.create_workout_template_internal(text, text, text, jsonb) TO authenticated;

CREATE FUNCTION public.create_workout_template(
  p_name text, p_description text, p_visibility text, p_blocks jsonb
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

  RETURN app_private.create_workout_template_internal(p_name, p_description, p_visibility, p_blocks);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.create_workout_template(text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_workout_template(text, text, text, jsonb) TO authenticated;
