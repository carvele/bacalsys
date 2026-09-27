-- =============================================================================
-- workout_payload_limits_and_compound_block_cardinality
-- Roadmap v1.2 · Sprint 3 · Reviewer gate rework (F-S3-03, F-S3-04)
--
-- F-S3-03: app_private.build_workout_version had drifted from the frozen
-- payload limits. Corrected to:
--   * max 20 blocks/workout               (unchanged)
--   * max 15 items/block                  (was 30)
--   * max 30 sets/item                    (was 50)
--   * max 150 total sets/workout          (was 500)
--
-- F-S3-04: compound blocks (superset, circuit) require at least 2 items —
-- a "superset" or "circuit" of one exercise is not a compound structure.
-- standard_set and amrap keep their existing 1-item minimum. circuit_rounds
-- and AMRAP duration validation are unchanged.
--
-- Sprint 3's migrations are already applied to bacalsys-dev; this is a
-- forward migration that CREATE OR REPLACEs the one function that enforces
-- these limits (app_private.build_workout_version), used by both
-- create_workout_template and publish_new_workout_version. Grants, RLS,
-- sealed-version immutability, two-tier private-version visibility and D5
-- authority are untouched.
-- =============================================================================

CREATE OR REPLACE FUNCTION app_private.build_workout_version(
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
      RAISE EXCEPTION 'Block % needs between 1 and 15 exercises', v_block_idx USING ERRCODE = '22023';
    END IF;
    -- F-S3-03: 15 items/block (was 30).
    IF jsonb_array_length(v_block -> 'items') NOT BETWEEN 1 AND 15 THEN
      RAISE EXCEPTION 'Block % needs between 1 and 15 exercises', v_block_idx USING ERRCODE = '22023';
    END IF;
    -- F-S3-04: a compound block (superset/circuit) needs at least 2 exercises.
    IF v_block_type IN ('superset', 'circuit') AND jsonb_array_length(v_block -> 'items') < 2 THEN
      RAISE EXCEPTION 'A % block needs at least 2 exercises (block %)', v_block_type, v_block_idx USING ERRCODE = '22023';
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
        RAISE EXCEPTION '% needs between 1 and 30 sets', v_ex.name USING ERRCODE = '22023';
      END IF;
      -- F-S3-03: 30 sets/item (was 50).
      IF jsonb_array_length(v_item -> 'sets') NOT BETWEEN 1 AND 30 THEN
        RAISE EXCEPTION '% needs between 1 and 30 sets', v_ex.name USING ERRCODE = '22023';
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
        -- F-S3-03: 150 total sets/workout (was 500).
        IF v_n_sets > 150 THEN
          RAISE EXCEPTION 'A workout can have at most 150 sets' USING ERRCODE = '22023';
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
-- Grants are unchanged (already scoped to authenticated-only on the internal
-- callers of this function); CREATE OR REPLACE preserves them, but the
-- REVOKE is repeated defensively in case a future Postgres version ever
-- resets function privileges on REPLACE.
REVOKE EXECUTE ON FUNCTION app_private.build_workout_version(uuid, jsonb, uuid, boolean) FROM PUBLIC, anon, authenticated;
