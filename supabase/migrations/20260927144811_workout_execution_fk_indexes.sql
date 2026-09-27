-- =============================================================================
-- workout_execution_fk_indexes
-- Roadmap v1.2 · Sprint 4 · Task 4.15 (Supabase performance advisor)
--
-- The hosted performance advisor flagged 4 foreign keys on the Sprint 4
-- execution tables with no covering index (join/lookup cost only — no
-- correctness or security impact). Added as a forward migration rather than
-- editing the already-applied 20260927130335_workout_execution_schema.
-- =============================================================================

CREATE INDEX IF NOT EXISTS session_exercises_workout_item_idx ON public.session_exercises (workout_item_id);
CREATE INDEX IF NOT EXISTS session_modifications_original_item_idx ON public.session_modifications (original_workout_item_id);
CREATE INDEX IF NOT EXISTS session_modifications_replacement_exercise_idx ON public.session_modifications (replacement_exercise_id);
CREATE INDEX IF NOT EXISTS session_sets_prescribed_item_set_idx ON public.session_sets (prescribed_item_set_id);
