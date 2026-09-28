-- =============================================================================
-- workout_assignments_rls
-- Roadmap v1.2 · Sprint 5 · Task 5.2 (Section 12, "Row-Level Security Policies
-- & Helper Functions"; F-S5-P04, F-S5-P13)
--
-- Read model (RLS is part of the security boundary, never UI-only):
--   workout_assignments / recurring_schedules  can_view_assignment(id)
--       targeted athlete · CURRENT primary coach of ANY targeted athlete ·
--       leadership (training:view_org) whose current organization equals the
--       assignment's own organization_id. A FORMER coach gets 0 rows.
--   assignment_targets  can_view_assignment_target(assignment_id, athlete_id)
--       target-safe: a coach sees ONLY the target row of an athlete they
--       currently coach — never a sibling athlete's row on a shared assignment.
--   assignment_occurrences  can_view_assignment_occurrence(id)
--       athlete · current coach · FORMER coach inside the half-open coaching
--       window that covers the occurrence's scheduled_at · leadership.
--
-- Leadership scope resolves from workout_assignments.organization_id (the
-- authoritative assignment boundary). profiles has NO organization_id column —
-- organization derives from home_branch_id via current_organization_id() — so a
-- caller with no organization (NULL) or a different organization fails closed.
-- The assignment CREATOR (assigned_by) gets no permanent visibility shortcut:
-- access is always the dynamic result of positions and coaching relationships.
-- =============================================================================

-- 1. can_view_assignment -----------------------------------------------------------
CREATE FUNCTION app_private.can_view_assignment(p_assignment_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_assignment_org uuid;
  v_current_org uuid;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  SELECT organization_id INTO v_assignment_org FROM public.workout_assignments WHERE id = p_assignment_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- 1. A targeted athlete.
  IF EXISTS (
    SELECT 1 FROM public.assignment_targets
    WHERE assignment_id = p_assignment_id AND athlete_id = v_uid
  ) THEN
    RETURN true;
  END IF;

  -- 2. The CURRENT primary coach of any targeted athlete (dynamic; no creator shortcut).
  IF EXISTS (
    SELECT 1 FROM public.assignment_targets t
    WHERE t.assignment_id = p_assignment_id
      AND app_private.current_coach_can_view(t.athlete_id)
  ) THEN
    RETURN true;
  END IF;

  -- 3. Leadership: current organization = the assignment's organization (null-safe).
  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NOT NULL
     AND v_assignment_org IS NOT DISTINCT FROM v_current_org
     AND app_private.has_permission('training:view_org') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_assignment(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_assignment(uuid) TO authenticated;

-- 2. can_view_assignment_target (target-safe) ---------------------------------------
CREATE FUNCTION app_private.can_view_assignment_target(p_assignment_id uuid, p_athlete_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
  v_assignment_org uuid;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  -- 1. The target athlete themselves.
  IF p_athlete_id = v_uid THEN
    RETURN true;
  END IF;

  -- 2. The CURRENT primary coach of THIS target athlete only.
  IF app_private.current_coach_can_view(p_athlete_id) THEN
    RETURN true;
  END IF;

  -- 3. Leadership in the parent assignment's organization.
  v_current_org := app_private.current_organization_id();
  SELECT organization_id INTO v_assignment_org FROM public.workout_assignments WHERE id = p_assignment_id;
  IF v_current_org IS NOT NULL
     AND v_assignment_org IS NOT DISTINCT FROM v_current_org
     AND app_private.has_permission('training:view_org') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_assignment_target(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_assignment_target(uuid, uuid) TO authenticated;

-- 3. can_view_assignment_occurrence (temporal former-coach scope) --------------------
CREATE FUNCTION app_private.can_view_assignment_occurrence(p_occurrence_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_occ public.assignment_occurrences%ROWTYPE;
  v_current_org uuid;
  v_assignment_org uuid;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  SELECT * INTO v_occ FROM public.assignment_occurrences WHERE id = p_occurrence_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- 1. The athlete.
  IF v_occ.athlete_id = v_uid THEN
    RETURN true;
  END IF;

  -- 2. The current primary coach.
  IF app_private.current_coach_can_view(v_occ.athlete_id) THEN
    RETURN true;
  END IF;

  -- 3. A former coach, inside the half-open window [started_at, ended_at) that
  --    covers the occurrence's scheduled_at.
  IF app_private.former_coach_can_view(v_occ.athlete_id, v_occ.scheduled_at) THEN
    RETURN true;
  END IF;

  -- 4. Leadership in the parent assignment's organization.
  v_current_org := app_private.current_organization_id();
  SELECT organization_id INTO v_assignment_org FROM public.workout_assignments WHERE id = v_occ.assignment_id;
  IF v_current_org IS NOT NULL
     AND v_assignment_org IS NOT DISTINCT FROM v_current_org
     AND app_private.has_permission('training:view_org') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_assignment_occurrence(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_assignment_occurrence(uuid) TO authenticated;

-- 4. Policies (RLS itself was enabled with the tables) -------------------------------
CREATE POLICY workout_assignments_select ON public.workout_assignments
  FOR SELECT TO authenticated
  USING (app_private.can_view_assignment(id));

CREATE POLICY assignment_targets_select ON public.assignment_targets
  FOR SELECT TO authenticated
  USING (app_private.can_view_assignment_target(assignment_id, athlete_id));

CREATE POLICY recurring_schedules_select ON public.recurring_schedules
  FOR SELECT TO authenticated
  USING (app_private.can_view_assignment(assignment_id));

CREATE POLICY assignment_occurrences_select ON public.assignment_occurrences
  FOR SELECT TO authenticated
  USING (app_private.can_view_assignment_occurrence(id));
