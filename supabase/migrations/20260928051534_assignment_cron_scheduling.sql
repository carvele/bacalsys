-- =============================================================================
-- assignment_cron_scheduling
-- Roadmap v1.2 · Sprint 5 · Task 5.3 (Section 12, "Timezone-Aware Scheduling
-- Engine & pg_cron"; F-S5-P07, F-S5-P09, F-S5-P14)
--
--   app_private.generate_assignment_occurrences(assignment_id)
--       one assignment's rolling horizon [org_today, org_today + 13] (inclusive
--       14 local calendar days), idempotent (ON CONFLICT DO NOTHING). Shared by
--       the nightly generator below AND create_workout_assignment (Task 5.4) so
--       the horizon rule lives in exactly one place.
--   app_private.generate_recurring_occurrences()      nightly, every active recurring assignment
--   app_private.mark_overdue_assignments_as_missed()  hourly, upcoming -> missed only
--
-- The ORGANIZATION timezone is authoritative. recurring_schedules.timezone is
-- forced equal to it on write (trigger, Task 5.1); the generator reads
-- organizations.timezone directly so a later change of the organization's
-- timezone can never leave a stale schedule copy in charge.
--
-- Serialization (Section 12): the generator takes the assignment FOR SHARE and
-- cancellation takes it FOR UPDATE, so a cancelled assignment can never gain
-- future occurrences; the overdue job locks each occurrence FOR UPDATE SKIP
-- LOCKED, so it can never race a session start over the same row. Both jobs run
-- with NO auth context and audit as actor_type = 'cron' (never a user).
-- =============================================================================

-- 1. One assignment's rolling horizon ------------------------------------------------
CREATE FUNCTION app_private.generate_assignment_occurrences(p_assignment_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_rec record;
  v_org_today date;
  v_count integer;
BEGIN
  SELECT a.id AS assignment_id, a.workout_version_id, s.days_of_week, s.start_date, s.end_date, o.timezone AS tz
  INTO v_rec
  FROM public.workout_assignments a
  JOIN public.recurring_schedules s ON s.assignment_id = a.id
  JOIN public.organizations o ON o.id = a.organization_id
  WHERE a.id = p_assignment_id
    AND a.status = 'active'
    AND a.is_recurring = true
    AND s.is_active = true;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_org_today := (now() AT TIME ZONE v_rec.tz)::date;

  -- The frozen horizon [v_org_today, v_org_today + 13] as an integer offset
  -- series (no timestamptz round-trip through the session time zone).
  INSERT INTO public.assignment_occurrences
    (assignment_id, athlete_id, workout_version_id, scheduled_date, scheduled_at, due_datetime, status)
  SELECT
    v_rec.assignment_id,
    t.athlete_id,
    v_rec.workout_version_id,
    d.day,
    d.day::timestamp AT TIME ZONE v_rec.tz,
    (d.day + 1)::timestamp AT TIME ZONE v_rec.tz,
    'upcoming'
  FROM (SELECT (v_org_today + g)::date AS day FROM generate_series(0, 13) AS g) AS d
  CROSS JOIN public.assignment_targets t
  WHERE t.assignment_id = v_rec.assignment_id
    AND d.day >= v_rec.start_date
    AND (v_rec.end_date IS NULL OR d.day <= v_rec.end_date)
    AND EXTRACT(ISODOW FROM d.day)::smallint = ANY (v_rec.days_of_week)
  ON CONFLICT (assignment_id, athlete_id, scheduled_date) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.generate_assignment_occurrences(uuid) FROM PUBLIC, anon, authenticated;

-- 2. Nightly generator -----------------------------------------------------------------
CREATE FUNCTION app_private.generate_recurring_occurrences()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_assignment_id uuid;
BEGIN
  PERFORM set_config('bacalsys.actor_type', 'cron', true);

  -- FOR SHARE serializes cleanly against cancel_workout_assignment (FOR UPDATE):
  -- if a cancellation commits first the row no longer satisfies status = 'active'
  -- and is skipped; if the generator holds the share lock first, cancellation
  -- waits and then deletes what was generated.
  FOR v_assignment_id IN
    SELECT a.id
    FROM public.workout_assignments a
    JOIN public.recurring_schedules s ON s.assignment_id = a.id
    WHERE a.status = 'active'
      AND a.is_recurring = true
      AND s.is_active = true
    ORDER BY a.id
    FOR SHARE OF a
  LOOP
    v_count := v_count + app_private.generate_assignment_occurrences(v_assignment_id);
  END LOOP;

  RETURN v_count;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.generate_recurring_occurrences() FROM PUBLIC, anon, authenticated;

-- 3. Hourly overdue -> missed (cron actor, independent of any auth context) ----------------
CREATE FUNCTION app_private.mark_overdue_assignments_as_missed()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_row record;
BEGIN
  PERFORM set_config('bacalsys.actor_type', 'cron', true);

  -- Only `upcoming` rows are ever touched: an in_progress occurrence (a started
  -- session) is never marked missed. SKIP LOCKED leaves a row that a session
  -- start currently holds to that start, which will move it to in_progress.
  FOR v_row IN
    SELECT id, due_datetime
    FROM public.assignment_occurrences
    WHERE status = 'upcoming'
      AND due_datetime <= now()
    ORDER BY due_datetime, id
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.assignment_occurrences
    SET status = 'missed'
    WHERE id = v_row.id;

    -- Written directly (not via write_audit_event, which would attribute the row
    -- to auth.uid() when one is set): a cron transition is ALWAYS actor_type
    -- 'cron' with no user id.
    INSERT INTO public.audit_logs (actor_user_id, actor_type, action, entity_type, entity_id, old_values, new_values)
    VALUES (
      NULL, 'cron', 'updated', 'assignment_occurrence', v_row.id::text,
      jsonb_build_object('status', 'upcoming'),
      jsonb_build_object('status', 'missed', 'due_datetime', v_row.due_datetime)
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.mark_overdue_assignments_as_missed() FROM PUBLIC, anon, authenticated;

-- 4. pg_cron registration (F-S5-P07) ---------------------------------------------------------
-- Fails loudly (0A000) when the scheduler is genuinely unavailable — a hosted
-- project must never silently run without its rolling horizon or overdue job.
-- pg_cron is enabled here when the platform offers it but the project has not
-- installed it yet (Supabase lists it as an available extension); offline the
-- PGlite harness supplies a cron.schedule() shim instead (scripts/db).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'cron' AND p.proname = 'schedule'
  ) AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'cron' AND p.proname = 'schedule'
  ) THEN
    RAISE EXCEPTION 'pg_cron extension / cron.schedule is not available' USING ERRCODE = '0A000';
  END IF;

  PERFORM cron.schedule('generate-recurring-occurrences', '0 1 * * *', 'SELECT app_private.generate_recurring_occurrences();');
  PERFORM cron.schedule('mark-missed-workouts', '0 * * * *', 'SELECT app_private.mark_overdue_assignments_as_missed();');
END;
$$;
