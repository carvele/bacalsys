-- =============================================================================
-- training_history_and_statistics_rpcs
-- Roadmap v1.2 · Sprint 6 · Task 6.6 (Section 13, "Public RPC Wrappers & Private
-- Internals", F-S6-P02 / P08 / P11 / P12 / P15)
--
--   public.get_session_replay(uuid)                       → app_private.get_session_replay_internal
--   public.get_my_athlete_summary(date, date)             ┐
--   public.get_athlete_summary(uuid, date, date)          ┴→ app_private.get_athlete_summary_metrics
--
-- F-S6-P15: the public wrappers are SECURITY INVOKER (they run as the caller);
-- the private delegates are SECURITY DEFINER, revoked from PUBLIC/anon and
-- granted to `authenticated`. app_private is not exposed by PostgREST, so the
-- only client path to the delegates is the validated public wrapper.
--
-- F-S6-P02 (the prescription-loss problem): workout_versions / workout_item_sets
-- are governed by template visibility (Sprint 3 RLS), so a coach or leader
-- reviewing an athlete's past session may not be allowed to read the athlete's
-- private template. The replay is therefore a single authorization decision
-- (can_view_workout_session) followed by a definer-side read of the session's
-- own sealed version — without loosening any table policy.
--
-- Rule E: the session's private feedback and MEDICAL substitutions
-- (pain_discomfort / injury_limitation) are returned only when
-- can_view_session_private_feedback() allows it; otherwise the private block is
-- null and medical substitution rows are omitted.
--
-- Executor defense-in-depth (finding F-S6-E04): the summary delegate re-checks
-- can_view_athlete_training() itself, so a direct call to the delegate can never
-- read another athlete's aggregates even though it is granted to `authenticated`.
-- =============================================================================

-- 1. Session replay ----------------------------------------------------------------
CREATE FUNCTION app_private.get_session_replay_internal(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_session public.workout_sessions%ROWTYPE;
  v_can_view_private boolean;
  v_feedback jsonb := NULL;
  v_private_feedback jsonb := NULL;
  v_substitutions jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  IF p_session_id IS NULL OR NOT app_private.can_view_workout_session(p_session_id) THEN
    RAISE EXCEPTION 'Not authorized to view workout session %', p_session_id USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_session FROM public.workout_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workout session not found' USING ERRCODE = '22000';
  END IF;

  v_can_view_private := app_private.can_view_session_private_feedback(p_session_id);

  -- Ordinary feedback (difficulty + energy only; Rule E keeps prose out of it).
  SELECT jsonb_build_object(
    'difficulty_rating', sf.difficulty_rating,
    'energy_level', sf.energy_level
  ) INTO v_feedback
  FROM public.session_feedback sf
  WHERE sf.session_id = p_session_id;

  -- Private feedback: strictly when authorized.
  IF v_can_view_private THEN
    SELECT jsonb_build_object(
      'has_discomfort', pf.has_discomfort,
      'discomfort_area', pf.discomfort_area,
      'note_to_coach', pf.note_to_coach
    ) INTO v_private_feedback
    FROM public.session_private_feedback pf
    WHERE pf.session_id = p_session_id;
  END IF;

  -- Substitutions: medical reasons are omitted for viewers who may not see them.
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', sm.id,
        'original_workout_item_id', sm.original_workout_item_id,
        'replacement_exercise_id', sm.replacement_exercise_id,
        'replacement_exercise_name', re.name,
        'reason_code', sm.reason_code
      ) ORDER BY sm.created_at ASC, sm.id ASC
    ),
    '[]'::jsonb
  ) INTO v_substitutions
  FROM public.session_modifications sm
  JOIN public.exercises re ON re.id = sm.replacement_exercise_id
  WHERE sm.session_id = p_session_id
    AND (
      sm.reason_code NOT IN ('pain_discomfort', 'injury_limitation')
      OR v_can_view_private
    );

  -- Prescribed items (from the session's sealed version) paired set-by-set with
  -- what was actually performed. FULL OUTER JOIN keeps prescribed sets that were
  -- never logged (is_skipped) AND athlete-added sets with no prescription
  -- (is_extra, prescribed_item_set_id IS NULL).
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'workout_item_id', wi.id,
        'block_id', wb.id,
        'block_title', wb.title,
        'order_in_workout', wb.order_in_workout,
        'order_in_block', wi.order_in_block,
        'prescribed_exercise_id', pe.id,
        'prescribed_exercise_name', pe.name,
        'prescribed_category', pe.category,
        'prescribed_measurement_mode', wi.measurement_mode,
        'actual_session_exercise_id', se.id,
        'is_substituted', COALESCE(se.is_substituted, false),
        'performed_exercise_id', ae.id,
        'performed_exercise_name', ae.name,
        'performed_measurement_mode', se.performed_measurement_mode,
        'sets', (
          SELECT COALESCE(
            jsonb_agg(
              jsonb_build_object(
                'set_number', COALESCE(wis.set_number, ss.set_number),
                'prescribed_item_set_id', wis.id,
                'session_set_id', ss.id,
                'target_reps', wis.target_reps,
                'target_load_kg', wis.target_load_kg,
                'target_load_type', wis.load_type,
                'target_duration_seconds', wis.target_duration_seconds,
                'target_distance_meters', wis.target_distance_meters,
                'target_rest_seconds', wis.target_rest_seconds,
                'target_rpe', wis.target_rpe,
                'actual_reps', ss.actual_reps,
                'actual_load_kg', ss.actual_load_kg,
                'actual_load_type', ss.load_type,
                'actual_duration_seconds', ss.actual_duration_seconds,
                'actual_distance_meters', ss.actual_distance_meters,
                'actual_rest_seconds', ss.actual_rest_seconds,
                'rpe', ss.rpe,
                'is_completed', COALESCE(ss.is_completed, false),
                'is_skipped', (ss.id IS NULL OR ss.is_completed = false),
                'is_extra', (wis.id IS NULL)
              ) ORDER BY COALESCE(wis.set_number, ss.set_number) ASC, ss.set_number ASC NULLS LAST
            ),
            '[]'::jsonb
          )
          FROM (
            SELECT * FROM public.workout_item_sets s0 WHERE s0.workout_item_id = wi.id
          ) wis
          FULL OUTER JOIN (
            SELECT * FROM public.session_sets s1 WHERE s1.session_exercise_id = se.id
          ) ss ON ss.prescribed_item_set_id = wis.id
        )
      ) ORDER BY wb.order_in_workout ASC, wi.order_in_block ASC
    ),
    '[]'::jsonb
  ) INTO v_items
  FROM public.workout_blocks wb
  JOIN public.workout_items wi ON wi.block_id = wb.id
  JOIN public.exercises pe ON pe.id = wi.exercise_id
  LEFT JOIN public.session_exercises se ON se.session_id = p_session_id AND se.workout_item_id = wi.id
  LEFT JOIN public.exercises ae ON ae.id = se.exercise_id
  WHERE wb.workout_version_id = v_session.workout_version_id;

  RETURN jsonb_build_object(
    'session', jsonb_build_object(
      'id', v_session.id,
      'athlete_id', v_session.athlete_id,
      'workout_version_id', v_session.workout_version_id,
      'assignment_occurrence_id', v_session.assignment_occurrence_id,
      'status', v_session.status,
      'started_at', v_session.started_at,
      'completed_at', v_session.completed_at,
      'abandonment_reason_code', v_session.abandonment_reason_code
    ),
    'feedback', v_feedback,
    'private_feedback', v_private_feedback,
    'substitutions', v_substitutions,
    'items', v_items
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.get_session_replay_internal(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.get_session_replay_internal(uuid) TO authenticated;

CREATE FUNCTION public.get_session_replay(p_session_id uuid)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.get_session_replay_internal(p_session_id);
$$;
REVOKE EXECUTE ON FUNCTION public.get_session_replay(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_session_replay(uuid) TO authenticated;

-- 2. Athlete training summary (Feature 7.2, F-S6-P08) ------------------------------
CREATE FUNCTION app_private.get_athlete_summary_metrics(
  p_athlete_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_org_tz text;
  v_org_today date;
  v_start date;
  v_end date;

  v_completed_count integer := 0;
  v_partial_count integer := 0;
  v_abandoned_count integer := 0;
  v_missed_count integer := 0;
  v_total_due integer := 0;
  v_adherence_rate numeric(5, 1) := NULL;

  v_sessions_completed integer := 0;
  v_sessions_abandoned integer := 0;
  v_total_completed_sets integer := 0;
  v_total_reps bigint := 0;
  v_total_duration_seconds bigint := 0;
  v_volume_by_category jsonb := '[]'::jsonb;
BEGIN
  IF p_athlete_id IS NULL OR NOT app_private.can_view_athlete_training(p_athlete_id) THEN
    RAISE EXCEPTION 'Not authorized to view training summary for athlete %', p_athlete_id USING ERRCODE = '42501';
  END IF;

  -- The athlete's organization timezone (F-S6-P08); Asia/Manila if unassigned.
  SELECT o.timezone INTO v_org_tz
  FROM public.profiles p
  JOIN public.branches b ON b.id = p.home_branch_id
  JOIN public.organizations o ON o.id = b.organization_id
  WHERE p.id = p_athlete_id;

  v_org_tz := COALESCE(v_org_tz, 'Asia/Manila');
  v_org_today := (now() AT TIME ZONE v_org_tz)::date;

  -- Default window: the 30 calendar days ending on the requested end (today).
  v_end := COALESCE(p_end_date, v_org_today);
  v_start := COALESCE(p_start_date, v_end - 29);

  IF v_end < v_start THEN
    RAISE EXCEPTION 'End date must be greater than or equal to start date' USING ERRCODE = '22023';
  END IF;
  IF (v_end - v_start) > 366 THEN
    RAISE EXCEPTION 'Summary window cannot exceed 366 days' USING ERRCODE = '22023';
  END IF;

  -- Occurrences in the window (scheduled_date is already the local calendar date).
  SELECT
    COUNT(*) FILTER (WHERE ao.status = 'completed'),
    COUNT(*) FILTER (WHERE ao.status = 'partially_completed'),
    COUNT(*) FILTER (WHERE ao.status = 'abandoned'),
    COUNT(*) FILTER (WHERE ao.status = 'missed')
  INTO v_completed_count, v_partial_count, v_abandoned_count, v_missed_count
  FROM public.assignment_occurrences ao
  WHERE ao.athlete_id = p_athlete_id
    AND ao.scheduled_date >= v_start
    AND ao.scheduled_date <= v_end
    AND ao.status IN ('completed', 'partially_completed', 'abandoned', 'missed');

  v_total_due := v_completed_count + v_partial_count + v_abandoned_count + v_missed_count;
  IF v_total_due > 0 THEN
    v_adherence_rate := ROUND((v_completed_count::numeric / v_total_due::numeric) * 100.0, 1);
  END IF;

  -- Sessions started in the window, evaluated on the organization's calendar.
  SELECT
    COUNT(*) FILTER (WHERE ws.status = 'completed'),
    COUNT(*) FILTER (WHERE ws.status = 'abandoned')
  INTO v_sessions_completed, v_sessions_abandoned
  FROM public.workout_sessions ws
  WHERE ws.athlete_id = p_athlete_id
    AND (ws.started_at AT TIME ZONE v_org_tz)::date >= v_start
    AND (ws.started_at AT TIME ZONE v_org_tz)::date <= v_end;

  -- Volume: completed sets of completed sessions.
  SELECT
    COALESCE(COUNT(ss.id), 0),
    COALESCE(SUM(ss.actual_reps), 0),
    COALESCE(SUM(ss.actual_duration_seconds), 0)
  INTO v_total_completed_sets, v_total_reps, v_total_duration_seconds
  FROM public.workout_sessions ws
  JOIN public.session_exercises se ON se.session_id = ws.id
  JOIN public.session_sets ss ON ss.session_exercise_id = se.id
  WHERE ws.athlete_id = p_athlete_id
    AND ws.status = 'completed'
    AND ss.is_completed = true
    AND (ws.started_at AT TIME ZONE v_org_tz)::date >= v_start
    AND (ws.started_at AT TIME ZONE v_org_tz)::date <= v_end;

  -- ...and the same volume grouped by the PERFORMED exercise's category.
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'category', cat.category,
        'sets', cat.set_count,
        'reps', cat.rep_sum,
        'duration_seconds', cat.duration_sum
      ) ORDER BY cat.set_count DESC, cat.category ASC
    ),
    '[]'::jsonb
  ) INTO v_volume_by_category
  FROM (
    SELECT
      e.category,
      COUNT(ss.id) AS set_count,
      COALESCE(SUM(ss.actual_reps), 0) AS rep_sum,
      COALESCE(SUM(ss.actual_duration_seconds), 0) AS duration_sum
    FROM public.workout_sessions ws
    JOIN public.session_exercises se ON se.session_id = ws.id
    JOIN public.exercises e ON e.id = se.exercise_id
    JOIN public.session_sets ss ON ss.session_exercise_id = se.id
    WHERE ws.athlete_id = p_athlete_id
      AND ws.status = 'completed'
      AND ss.is_completed = true
      AND (ws.started_at AT TIME ZONE v_org_tz)::date >= v_start
      AND (ws.started_at AT TIME ZONE v_org_tz)::date <= v_end
    GROUP BY e.category
  ) cat;

  RETURN jsonb_build_object(
    'athlete_id', p_athlete_id,
    'timezone', v_org_tz,
    'window_start', v_start,
    'window_end', v_end,
    'scheduled_workouts', v_total_due,
    'completed_workouts', v_completed_count,
    'partially_completed_workouts', v_partial_count,
    'abandoned_workouts', v_abandoned_count,
    'missed_workouts', v_missed_count,
    'adherence_rate', v_adherence_rate,
    'total_sessions_completed', v_sessions_completed,
    'total_sessions_abandoned', v_sessions_abandoned,
    'total_completed_sets', v_total_completed_sets,
    'total_reps', v_total_reps,
    'total_duration_seconds', v_total_duration_seconds,
    'volume_by_category', v_volume_by_category
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.get_athlete_summary_metrics(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.get_athlete_summary_metrics(uuid, date, date) TO authenticated;

CREATE FUNCTION public.get_my_athlete_summary(
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.get_athlete_summary_metrics(v_uid, p_start_date, p_end_date);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_my_athlete_summary(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_athlete_summary(date, date) TO authenticated;

CREATE FUNCTION public.get_athlete_summary(
  p_athlete_id uuid,
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF NOT app_private.can_view_athlete_training(p_athlete_id) THEN
    RAISE EXCEPTION 'Not authorized to view training summary for athlete %', p_athlete_id USING ERRCODE = '42501';
  END IF;

  RETURN app_private.get_athlete_summary_metrics(p_athlete_id, p_start_date, p_end_date);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_athlete_summary(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_athlete_summary(uuid, date, date) TO authenticated;
