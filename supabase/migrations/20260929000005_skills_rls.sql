-- =============================================================================
-- skills_rls
-- Roadmap v1.2 · Sprint 6 · Task 6.5 (Section 13, "Row-Level Security Policies")
--
-- SELECT-only policies for the five skill tables (every mutation is an RPC).
-- RLS was enabled with the tables in migration 2; it is restated here so this
-- migration is self-describing and idempotent to re-apply on its own.
--
--   skills / skill_progressions   any active position holder of the same organization
--   athlete_skill_status          Tier 1  can_view_athlete_skill_status
--   skill_attempts                Tier 2  can_view_athlete_skill_attempts
--   skill_achievements            Tier 3  can_view_athlete_skill_achievements
--
-- F-S6-P14: every predicate is guarded by holds_active_position(), so a pure
-- System Administrator (no club position) reads 0 rows in all five tables.
-- =============================================================================

ALTER TABLE public.skills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skill_progressions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.athlete_skill_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skill_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skill_achievements ENABLE ROW LEVEL SECURITY;

CREATE POLICY skills_select ON public.skills
  FOR SELECT TO authenticated
  USING (
    app_private.is_active_member()
    AND app_private.holds_active_position()
    AND app_private.current_organization_id() = organization_id
  );

CREATE POLICY skill_progressions_select ON public.skill_progressions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.skills s
      WHERE s.id = skill_id
        AND app_private.is_active_member()
        AND app_private.holds_active_position()
        AND app_private.current_organization_id() = s.organization_id
    )
  );

CREATE POLICY athlete_skill_status_select ON public.athlete_skill_status
  FOR SELECT TO authenticated
  USING (app_private.can_view_athlete_skill_status(athlete_id));

CREATE POLICY skill_attempts_select ON public.skill_attempts
  FOR SELECT TO authenticated
  USING (app_private.can_view_athlete_skill_attempts(athlete_id));

CREATE POLICY skill_achievements_select ON public.skill_achievements
  FOR SELECT TO authenticated
  USING (app_private.can_view_athlete_skill_achievements(athlete_id));
