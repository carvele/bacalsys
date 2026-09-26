-- =============================================================================
-- coaching_scope_helpers
-- Roadmap v1.2 · Sprint 2 · Task 2.3 (D1, D2)
--
-- Row-scope helpers for the coaching relationship. They evaluate the CALLER
-- (auth.uid()) and fail closed for anyone who is not an active member. Sprint 4
-- plugs them into workout_sessions / feedback RLS; Sprint 5 uses
-- can_assign_training_to() for workout assignment. Sprint 2 creates no session
-- or assignment tables.
-- =============================================================================

-- D2: the caller is the athlete's CURRENT primary coach.
CREATE FUNCTION app_private.current_coach_can_view(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND EXISTS (
       SELECT 1
       FROM public.coach_assignments ca
       WHERE ca.athlete_id = p_athlete_id
         AND ca.coach_id = auth.uid()
         AND ca.ended_at IS NULL
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.current_coach_can_view(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.current_coach_can_view(uuid) TO authenticated;

-- D2: the caller was the athlete's coach at p_session_time, inside a CLOSED
-- assignment's half-open window: started_at <= t < ended_at.
CREATE FUNCTION app_private.former_coach_can_view(p_athlete_id uuid, p_session_time timestamptz)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND EXISTS (
       SELECT 1
       FROM public.coach_assignments ca
       WHERE ca.athlete_id = p_athlete_id
         AND ca.coach_id = auth.uid()
         AND ca.ended_at IS NOT NULL
         AND p_session_time >= ca.started_at
         AND p_session_time < ca.ended_at
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.former_coach_can_view(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.former_coach_can_view(uuid, timestamptz) TO authenticated;

-- D1: the caller may assign training to p_athlete_id.
--   workout:assign AND an active target athlete AND either
--     training:view_org within the caller's organization (Leader, VP, President), or
--     the caller is the athlete's current primary coach.
CREATE FUNCTION app_private.can_assign_training_to(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND app_private.has_permission('workout:assign')
     AND EXISTS (
       SELECT 1 FROM public.profiles p
       WHERE p.id = p_athlete_id AND p.status = 'active'
     )
     AND (
       (app_private.has_permission('training:view_org') AND app_private.same_organization(p_athlete_id))
       OR app_private.current_coach_can_view(p_athlete_id)
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_assign_training_to(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_assign_training_to(uuid) TO authenticated;
