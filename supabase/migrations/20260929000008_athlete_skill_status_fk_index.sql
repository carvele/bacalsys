-- =============================================================================
-- athlete_skill_status_fk_index
-- Roadmap v1.2 · Sprint 6 · Reviewer round-1 non-blocking finding
--
-- The composite FK fk_athlete_skill_status_progression (skill_id,
-- current_progression_id) -> skill_progressions (skill_id, id), added in
-- 20260929000002, had no composite index covering it: the two separate
-- single-column indexes (on skill_id, and on current_progression_id alone) do
-- not satisfy Supabase's unindexed-foreign-key advisor, which flags this as an
-- INFO-level performance finding (FK checks and ON DELETE RESTRICT scans on
-- this column pair would otherwise need two index probes instead of one).
--
-- athlete_skill_status_skill_idx is superseded by the new composite index's
-- leading column (skill_id) under the leftmost-prefix rule and is dropped;
-- athlete_skill_status_progression_idx is kept — it serves the reverse lookup
-- ("every athlete currently on this rung", used by future coach-facing
-- reporting) that the composite index's column order does not cover.
-- =============================================================================

DROP INDEX IF EXISTS public.athlete_skill_status_skill_idx;

CREATE INDEX athlete_skill_status_skill_progression_idx
ON public.athlete_skill_status (skill_id, current_progression_id);
