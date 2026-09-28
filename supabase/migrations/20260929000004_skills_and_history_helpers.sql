-- =============================================================================
-- skills_and_history_helpers
-- Roadmap v1.2 · Sprint 6 · Task 6.4 (Section 13, "Row-Level Security Policies &
-- Helper Functions", F-S6-P03 / P04 / P09 / P14)
--
--   holds_active_position(uuid)            Rule A guard (F-S6-P14)
--   can_view_athlete_training(uuid)        lifetime summary scope (Feature 7.2)
--   can_verify_skill(uuid)                 verify / revoke authority (Feature 8.3)
--   can_set_athlete_skill_status(uuid)     Tier-1 mutation authority (F-S6-P04)
--   can_view_athlete_skill_status(uuid)    Tier 1 read scope
--   can_view_athlete_skill_attempts(uuid)  Tier 2 read scope (no Leaders, F-S6-P09)
--   can_view_athlete_skill_achievements(uuid) Tier 3 read scope (club-visible)
--
-- Every helper is SECURITY DEFINER with SET search_path = '' and fully-qualified
-- references; default execution is revoked and re-granted to `authenticated`
-- only (F-S6-P15: the SECURITY INVOKER wrappers and RLS run as the caller).
--
-- F-S6-P14 (Rule A): a System Administrator who holds NO club position has an
-- active profile but no member_positions row. Every skill read predicate below
-- is guarded by holds_active_position(), so such an account sees 0 rows in all
-- five skill tables — system-administration authority is not club training
-- visibility.
--
-- Executor hardening (finding F-S6-E02): can_verify_skill also refuses
-- p_athlete_id = auth.uid(). An officer who is also an athlete (a Vice President
-- or President trains too) would otherwise satisfy `skills:verify` +
-- `training:view_org` + same-organization for their OWN profile and could verify
-- or revoke their own milestones. Verification is a third-party attestation.
-- =============================================================================

-- Rule A guard: the profile is an active member holding a CURRENT club position.
CREATE FUNCTION app_private.holds_active_position(p_profile_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.member_positions mp
    JOIN public.profiles pr ON pr.id = mp.profile_id
    WHERE mp.profile_id = p_profile_id
      AND mp.ended_at IS NULL
      AND pr.status = 'active'
  );
$$;
REVOKE EXECUTE ON FUNCTION app_private.holds_active_position(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.holds_active_position(uuid) TO authenticated;

-- Feature 7.2: who may read an athlete's LIFETIME summary metrics. A former coach
-- is intentionally absent (their window-bounded row access does not extend to
-- aggregate adherence/volume outside their tenure — D2).
CREATE FUNCTION app_private.can_view_athlete_training(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND (
       p_athlete_id = auth.uid()
       OR app_private.current_coach_can_view(p_athlete_id)
       OR (app_private.has_permission('training:view_org') AND app_private.same_organization(p_athlete_id))
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_athlete_training(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_athlete_training(uuid) TO authenticated;

-- Feature 8.3: who may verify / revoke / review an athlete's skill milestones.
CREATE FUNCTION app_private.can_verify_skill(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND app_private.has_permission('skills:verify')
     AND p_athlete_id IS DISTINCT FROM auth.uid()
     AND EXISTS (
       SELECT 1 FROM public.profiles p
       WHERE p.id = p_athlete_id AND p.status = 'active'
     )
     AND (
       (app_private.has_permission('training:view_org') AND app_private.same_organization(p_athlete_id))
       OR app_private.current_coach_can_view(p_athlete_id)
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_verify_skill(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_verify_skill(uuid) TO authenticated;

-- F-S6-P04: Tier-1 (trained) mutation authority — the athlete, their current
-- primary coach, or an executive officer (VP / President). Leaders, unassigned
-- coaches, former coaches and peers are refused.
CREATE FUNCTION app_private.can_set_athlete_skill_status(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND app_private.holds_active_position()
     AND EXISTS (
       SELECT 1 FROM public.profiles p WHERE p.id = p_athlete_id AND p.status = 'active'
     )
     AND (
       p_athlete_id = auth.uid()
       OR app_private.current_coach_can_view(p_athlete_id)
       OR (
         app_private.same_organization(p_athlete_id)
         AND app_private.has_permission('training:view_org')
         AND (app_private.has_permission('positions:assign') OR app_private.has_permission('coaches:assign'))
       )
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_set_athlete_skill_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_set_athlete_skill_status(uuid) TO authenticated;

-- Tier 1 (trained): athlete, current primary coach, or same-organization leadership.
CREATE FUNCTION app_private.can_view_athlete_skill_status(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND app_private.holds_active_position()
     AND (
       p_athlete_id = auth.uid()
       OR app_private.current_coach_can_view(p_athlete_id)
       OR (app_private.has_permission('training:view_org') AND app_private.same_organization(p_athlete_id))
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_athlete_skill_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_athlete_skill_status(uuid) TO authenticated;

-- Tier 2 (attempted): athlete, current primary coach, or an officer holding
-- training:view_private_feedback (VP / President). Leaders get 0 rows so the
-- reviewer's free-text review_feedback is never a leak channel (F-S6-P09).
CREATE FUNCTION app_private.can_view_athlete_skill_attempts(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND app_private.holds_active_position()
     AND (
       p_athlete_id = auth.uid()
       OR app_private.current_coach_can_view(p_athlete_id)
       OR (
         app_private.same_organization(p_athlete_id)
         AND app_private.has_permission('training:view_private_feedback')
       )
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_athlete_skill_attempts(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_athlete_skill_attempts(uuid) TO authenticated;

-- Tier 3 (verified milestones): club-visible across the organization to any
-- active position holder. A pure SysAdmin, a member with no organization, and any
-- other organization all see 0 rows (F-S6-P14; same_organization is NULL-safe).
CREATE FUNCTION app_private.can_view_athlete_skill_achievements(p_athlete_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT app_private.is_active_member()
     AND app_private.holds_active_position()
     AND (
       p_athlete_id = auth.uid()
       OR app_private.same_organization(p_athlete_id)
     );
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_athlete_skill_achievements(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_athlete_skill_achievements(uuid) TO authenticated;
