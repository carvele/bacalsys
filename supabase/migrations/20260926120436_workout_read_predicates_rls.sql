-- =============================================================================
-- workout_read_predicates_rls
-- Roadmap v1.2 · Sprint 3 · Tasks 3.4 + 3.5 (Section 10, Decision D5)
--
-- Two-tier read model:
--   can_view_workout_template(id)  catalog visibility. For a private routine seen
--                                  by a non-creator it is governed by the LATEST
--                                  SEALED version being free of unapproved exercises.
--   can_view_workout_version(id)   the exact version (and its blocks, items, sets)
--                                  must itself be sealed and free of unapproved
--                                  exercises for a non-creator, on top of template
--                                  eligibility. An unsafe historical version stays
--                                  hidden even when a later version is safe.
--
-- Organization scope is null-safe and fails closed: a caller whose
-- current_organization_id() is NULL (home_branch_id IS NULL) matches nothing.
-- The private-template creator keeps unconditional read access across
-- organization changes. Every policy is fail-closed for inactive callers because
-- both predicates begin with is_active_member().
-- =============================================================================

-- 1. Template-level predicate -----------------------------------------------------
CREATE FUNCTION app_private.can_view_workout_template(p_template_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
  v_template public.workout_templates%ROWTYPE;
  v_latest_version public.workout_versions%ROWTYPE;
  v_has_unapproved_exercise boolean;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  SELECT * INTO v_template FROM public.workout_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Private template
  IF v_template.visibility = 'private' THEN
    -- Creator: unconditional, even after moving organizations.
    IF v_template.created_by = v_uid THEN
      RETURN true;
    END IF;

    -- Non-creator: must belong to an organization, and it must be the template's.
    v_current_org := app_private.current_organization_id();
    IF v_current_org IS NULL OR v_template.organization_id IS DISTINCT FROM v_current_org THEN
      RETURN false;
    END IF;

    -- ...and be the creator's current primary coach, or hold workouts:manage_org.
    IF NOT (
      app_private.current_coach_can_view(v_template.created_by)
      OR app_private.has_permission('workouts:manage_org')
    ) THEN
      RETURN false;
    END IF;

    -- Resolve the latest sealed version.
    SELECT * INTO v_latest_version
    FROM public.workout_versions
    WHERE template_id = p_template_id AND is_sealed = true
    ORDER BY version_number DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    -- Visible only if that latest sealed version holds strictly approved/official exercises.
    SELECT EXISTS (
      SELECT 1
      FROM public.workout_blocks b
      JOIN public.workout_items i ON i.block_id = b.id
      JOIN public.exercises e ON e.id = i.exercise_id
      WHERE b.workout_version_id = v_latest_version.id
        AND NOT (e.status = 'approved' AND e.is_official = true)
    ) INTO v_has_unapproved_exercise;

    RETURN NOT v_has_unapproved_exercise;
  END IF;

  -- Organization template: the caller's current organization must match, null-safely.
  v_current_org := app_private.current_organization_id();
  IF v_current_org IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_template.organization_id IS NOT DISTINCT FROM v_current_org;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_workout_template(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_workout_template(uuid) TO authenticated;

-- 2. Version-level predicate ------------------------------------------------------
CREATE FUNCTION app_private.can_view_workout_version(p_version_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current_org uuid;
  v_version public.workout_versions%ROWTYPE;
  v_template public.workout_templates%ROWTYPE;
  v_has_unapproved_exercise boolean;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  SELECT * INTO v_version FROM public.workout_versions WHERE id = p_version_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT * INTO v_template FROM public.workout_templates WHERE id = v_version.template_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Organization template: current organization must match, null-safely.
  IF v_template.visibility = 'organization' THEN
    v_current_org := app_private.current_organization_id();
    IF v_current_org IS NULL OR v_template.organization_id IS DISTINCT FROM v_current_org THEN
      RETURN false;
    END IF;
    RETURN v_version.is_sealed = true OR v_version.created_by = v_uid;
  END IF;

  -- Private template: the creator always sees every version.
  IF v_template.created_by = v_uid THEN
    RETURN true;
  END IF;

  -- Non-creator (Coach, VP, President) needs (a) template eligibility ...
  IF NOT app_private.can_view_workout_template(v_template.id) THEN
    RETURN false;
  END IF;

  -- (b) this exact version sealed ...
  IF NOT v_version.is_sealed THEN
    RETURN false;
  END IF;

  -- (c) ... and free of unapproved exercises itself.
  SELECT EXISTS (
    SELECT 1
    FROM public.workout_blocks b
    JOIN public.workout_items i ON i.block_id = b.id
    JOIN public.exercises e ON e.id = i.exercise_id
    WHERE b.workout_version_id = p_version_id
      AND NOT (e.status = 'approved' AND e.is_official = true)
  ) INTO v_has_unapproved_exercise;

  RETURN NOT v_has_unapproved_exercise;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_workout_version(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_workout_version(uuid) TO authenticated;

-- 3. RLS policies (RLS itself was enabled with the tables) -------------------------
CREATE POLICY workout_templates_select ON public.workout_templates
  FOR SELECT TO authenticated
  USING (app_private.can_view_workout_template(id));

CREATE POLICY workout_versions_select ON public.workout_versions
  FOR SELECT TO authenticated
  USING (app_private.can_view_workout_version(id));

CREATE POLICY workout_blocks_select ON public.workout_blocks
  FOR SELECT TO authenticated
  USING (app_private.can_view_workout_version(workout_version_id));

CREATE POLICY workout_items_select ON public.workout_items
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.workout_blocks b
    WHERE b.id = block_id AND app_private.can_view_workout_version(b.workout_version_id)
  ));

CREATE POLICY workout_item_sets_select ON public.workout_item_sets
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.workout_items i
    JOIN public.workout_blocks b ON b.id = i.block_id
    WHERE i.id = workout_item_id AND app_private.can_view_workout_version(b.workout_version_id)
  ));
