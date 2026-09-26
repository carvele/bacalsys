-- =============================================================================
-- assign_primary_coach
-- Roadmap v1.2 · Sprint 2 · Task 2.2 (Section 9 §2)
--
-- Public authenticated wrapper → unexposed SECURITY DEFINER implementation.
-- The wrapper is SECURITY INVOKER as specified, so the internal function is
-- granted to `authenticated`; it stays unreachable from clients because
-- app_private is not an exposed Data API schema, and it re-derives the caller
-- from auth.uid() and re-checks every authorization rule itself.
--
-- Error codes:
--   42501  caller not an active member / lacks coaches:assign / cross-organization
--   P0002  athlete or coach not found
--   55000  athlete or coach not active; athlete already assigned to this coach (no-op)
--   22023  invalid arguments (missing ids, self-coaching, coach lacks the Coach position)
-- =============================================================================

CREATE FUNCTION app_private.assign_primary_coach_internal(
  p_athlete_id uuid,
  p_coach_id uuid,
  p_notes text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := auth.uid();
  v_athlete_status public.member_status;
  v_coach_status   public.member_status;
  v_org            uuid;
  v_assignment_id  uuid;
BEGIN
  -- 1–2. Caller: authenticated, active, holds coaches:assign.
  IF v_uid IS NULL
     OR NOT app_private.is_active_member()
     OR NOT app_private.has_permission('coaches:assign') THEN
    RAISE EXCEPTION 'Not authorized to assign primary coaches' USING ERRCODE = '42501';
  END IF;

  IF p_athlete_id IS NULL OR p_coach_id IS NULL THEN
    RAISE EXCEPTION 'Athlete and coach are required' USING ERRCODE = '22023';
  END IF;

  -- 5. Self-coaching prevention.
  IF p_athlete_id = p_coach_id THEN
    RAISE EXCEPTION 'An athlete cannot be their own primary coach' USING ERRCODE = '22023';
  END IF;

  -- 7. Concurrency control: serialize every assignment of this athlete.
  SELECT p.status INTO v_athlete_status
  FROM public.profiles p
  WHERE p.id = p_athlete_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Athlete not found' USING ERRCODE = 'P0002';
  END IF;

  -- 3. Target athlete is an active member.
  IF v_athlete_status <> 'active' THEN
    RAISE EXCEPTION 'Athlete must be an active member (current status: %)', v_athlete_status
      USING ERRCODE = '55000';
  END IF;

  -- 4. Target coach is an active member holding an active Coach position.
  SELECT p.status INTO v_coach_status
  FROM public.profiles p
  WHERE p.id = p_coach_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Coach not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_coach_status <> 'active' THEN
    RAISE EXCEPTION 'Coach must be an active member (current status: %)', v_coach_status
      USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.member_positions mp
    JOIN public.positions pos ON pos.id = mp.position_id
    WHERE mp.profile_id = p_coach_id
      AND mp.ended_at IS NULL
      AND pos.name = 'Coach'
  ) THEN
    RAISE EXCEPTION 'Selected member does not hold an active Coach position' USING ERRCODE = '22023';
  END IF;

  -- 6. Athlete, coach (and the caller) belong to the same, known organization.
  v_org := app_private.organization_of(p_athlete_id);
  IF v_org IS NULL
     OR v_org IS DISTINCT FROM app_private.organization_of(p_coach_id)
     OR v_org IS DISTINCT FROM app_private.organization_of(v_uid) THEN
    RAISE EXCEPTION 'Athlete and coach must belong to your organization' USING ERRCODE = '42501';
  END IF;

  -- 8. No-op guard.
  IF EXISTS (
    SELECT 1
    FROM public.coach_assignments ca
    WHERE ca.athlete_id = p_athlete_id
      AND ca.coach_id = p_coach_id
      AND ca.ended_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Athlete is already actively assigned to this coach' USING ERRCODE = '55000';
  END IF;

  -- 9. Atomic handover: close the current assignment, then open the new one.
  UPDATE public.coach_assignments
  SET ended_at = CURRENT_TIMESTAMP, ended_by = v_uid
  WHERE athlete_id = p_athlete_id AND ended_at IS NULL;

  INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, notes)
  VALUES (p_athlete_id, p_coach_id, v_uid, CURRENT_TIMESTAMP, NULLIF(btrim(p_notes), ''))
  RETURNING id INTO v_assignment_id;

  -- 10. audit_coach_assignments records both the close (update) and the insert.
  RETURN v_assignment_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.assign_primary_coach_internal(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.assign_primary_coach_internal(uuid, uuid, text) TO authenticated;

-- Public Authenticated Wrapper (Section 9 §2; search_path pinned as hardening)
CREATE FUNCTION public.assign_primary_coach(
  p_athlete_id uuid,
  p_coach_id uuid,
  p_notes text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- Strict Fail-Closed Active Membership & Auth Check
  IF auth.uid() IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Unauthorized: Caller must be an active member' USING ERRCODE = '42501';
  END IF;

  RETURN app_private.assign_primary_coach_internal(p_athlete_id, p_coach_id, p_notes);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.assign_primary_coach(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assign_primary_coach(uuid, uuid, text) TO authenticated;
