-- =============================================================================
-- workout_execution_schema
-- Roadmap v1.2 · Sprint 4 · Task 4.2 (Section 11, "Database Schemas, DDL & Invariants")
--
-- Execution data model: workout_sessions → session_exercises → session_sets,
-- plus session_modifications (substitution lineage), the Rule E feedback split
-- (session_feedback / session_private_feedback) and the idempotency ledger.
--
-- Rule E: general execution tables carry NO free-text notes column at all
-- (workout_sessions, session_sets, session_modifications) — sensitive prose can
-- only ever land in session_private_feedback.note_to_coach, which is governed
-- by app_private.can_view_session_private_feedback (Task 4.3), never the
-- general can_view_workout_session predicate.
--
-- Finding F-S4-01 (fixed here, before any hosted apply): the frozen spec text's
-- session_set_load_consistency repeats the exact three-valued-logic gap closed
-- in Sprint 3 by F-S3-02 (set_load_consistency on workout_item_sets) —
-- `load_type IN ('added','assisted')` evaluates to NULL, not FALSE, when
-- load_type IS NULL, and a CHECK constraint passes on NULL. Without an explicit
-- `load_type IS NOT NULL AND` guard, an actual_load_kg > 0 with load_type NULL
-- would silently pass the constraint. Fixed identically to F-S3-02; see
-- docs/sprints/sprint-04-workout-player/findings/F-S4-01-session-set-load-consistency-null-load-type-loophole.md
-- =============================================================================

-- 1. Workout Sessions (structured abandonment code, no free-text notes, no global idempotency_key)
CREATE TABLE public.workout_sessions (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id                uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  workout_version_id        uuid NOT NULL REFERENCES public.workout_versions (id) ON DELETE RESTRICT,
  assignment_occurrence_id  uuid NULL, -- Unconstrained in Sprint 4; FK'd when Sprint 5 introduces occurrences.
  status                    text NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress', 'completed', 'abandoned')),
  started_at                timestamptz NOT NULL DEFAULT now(),
  completed_at              timestamptz NULL,
  abandonment_reason_code   text CHECK (
    abandonment_reason_code IS NULL OR
    abandonment_reason_code IN (
      'time_constraint', 'equipment_issue', 'general_fatigue',
      'personal_emergency', 'facility_closed', 'other'
    )
  ),
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT valid_session_time_interval CHECK (completed_at IS NULL OR completed_at >= started_at),
  CONSTRAINT session_status_completed_check CHECK (
    (status = 'in_progress' AND completed_at IS NULL) OR
    (status IN ('completed', 'abandoned') AND completed_at IS NOT NULL)
  ),
  CONSTRAINT session_abandoned_reason_consistency CHECK (
    (status = 'abandoned' AND abandonment_reason_code IS NOT NULL) OR
    (status IN ('in_progress', 'completed') AND abandonment_reason_code IS NULL)
  )
);

-- At most one active in-progress session per athlete.
CREATE UNIQUE INDEX one_in_progress_session_per_athlete
ON public.workout_sessions (athlete_id)
WHERE status = 'in_progress';

CREATE INDEX workout_sessions_athlete_started_idx ON public.workout_sessions (athlete_id, started_at DESC);
CREATE INDEX workout_sessions_version_idx ON public.workout_sessions (workout_version_id);

CREATE TRIGGER workout_sessions_set_updated_at
BEFORE UPDATE ON public.workout_sessions
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

-- 2. Session Exercises
CREATE TABLE public.session_exercises (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id                uuid NOT NULL REFERENCES public.workout_sessions (id) ON DELETE CASCADE,
  workout_item_id           uuid NOT NULL REFERENCES public.workout_items (id) ON DELETE RESTRICT,
  exercise_id               uuid NOT NULL REFERENCES public.exercises (id) ON DELETE RESTRICT,
  order_in_session          integer NOT NULL CHECK (order_in_session >= 1),
  is_substituted            boolean NOT NULL DEFAULT false,
  performed_measurement_mode text NOT NULL CHECK (
    performed_measurement_mode IN (
      'reps', 'duration', 'holds', 'distance',
      'until_failure', 'added_weight', 'assisted_weight', 'technique_practice'
    )
  ),
  created_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_session_exercise_order UNIQUE (session_id, order_in_session)
);

CREATE INDEX session_exercises_session_idx ON public.session_exercises (session_id, order_in_session);
CREATE INDEX session_exercises_exercise_idx ON public.session_exercises (exercise_id);

-- 3. Session Sets (no free-text notes column)
CREATE TABLE public.session_sets (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_exercise_id     uuid NOT NULL REFERENCES public.session_exercises (id) ON DELETE CASCADE,
  prescribed_item_set_id  uuid NULL REFERENCES public.workout_item_sets (id) ON DELETE RESTRICT,
  set_number              integer NOT NULL CHECK (set_number >= 1),
  actual_reps             integer CHECK (actual_reps IS NULL OR (actual_reps >= 0 AND actual_reps <= 1000)),
  actual_load_kg          numeric(6, 2) CHECK (actual_load_kg IS NULL OR (actual_load_kg >= 0.00 AND actual_load_kg <= 500.00)),
  load_type               text CHECK (load_type IS NULL OR load_type IN ('bodyweight', 'added', 'assisted')),
  actual_duration_seconds integer CHECK (actual_duration_seconds IS NULL OR (actual_duration_seconds >= 0 AND actual_duration_seconds <= 7200)),
  actual_distance_meters  numeric(8, 2) CHECK (actual_distance_meters IS NULL OR (actual_distance_meters >= 0.0 AND actual_distance_meters <= 100000.0)),
  actual_rest_seconds     integer CHECK (actual_rest_seconds IS NULL OR (actual_rest_seconds >= 0 AND actual_rest_seconds <= 1800)),
  rpe                     numeric(3, 1) CHECK (rpe IS NULL OR (rpe >= 1.0 AND rpe <= 10.0)),
  is_completed            boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_session_set_number UNIQUE (session_exercise_id, set_number),
  -- F-S4-01 fix: explicit `load_type IS NOT NULL AND` closes the NULL-vs-CHECK
  -- gap (see header). Otherwise a nonzero actual_load_kg with load_type NULL
  -- makes the first branch evaluate to NULL (not FALSE), and NULL OR FALSE = NULL,
  -- which a CHECK constraint treats as satisfied.
  CONSTRAINT session_set_load_consistency CHECK (
    (actual_load_kg IS NOT NULL AND actual_load_kg > 0 AND load_type IS NOT NULL AND load_type IN ('added', 'assisted')) OR
    (actual_load_kg IS NULL AND (load_type IS NULL OR load_type = 'bodyweight'))
  )
);

CREATE INDEX session_sets_exercise_set_idx ON public.session_sets (session_exercise_id, set_number);

-- 4. Session Modifications (lineage tracking: Option A MVP single substitution rule per prescribed item)
CREATE TABLE public.session_modifications (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id                uuid NOT NULL REFERENCES public.workout_sessions (id) ON DELETE CASCADE,
  original_workout_item_id  uuid NOT NULL REFERENCES public.workout_items (id) ON DELETE RESTRICT,
  replacement_exercise_id   uuid NOT NULL REFERENCES public.exercises (id) ON DELETE RESTRICT,
  reason_code               text NOT NULL CHECK (
    reason_code IN (
      'equipment_unavailable', 'pain_discomfort', 'too_difficult',
      'too_easy', 'injury_limitation', 'personal_adjustment', 'other'
    )
  ),
  created_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_session_modification_item UNIQUE (session_id, original_workout_item_id)
);

CREATE INDEX session_modifications_session_idx ON public.session_modifications (session_id);

-- 5. Session Feedback (Rule E ordinary feedback: difficulty + energy only, no notes)
CREATE TABLE public.session_feedback (
  session_id        uuid PRIMARY KEY REFERENCES public.workout_sessions (id) ON DELETE CASCADE,
  difficulty_rating integer NOT NULL CHECK (difficulty_rating >= 1 AND difficulty_rating <= 10),
  energy_level      integer NOT NULL CHECK (energy_level >= 1 AND energy_level <= 5),
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- 6. Session Private Feedback (sensitive discomfort & coach notes: Rule E split)
CREATE TABLE public.session_private_feedback (
  session_id        uuid PRIMARY KEY REFERENCES public.workout_sessions (id) ON DELETE CASCADE,
  has_discomfort    boolean NOT NULL DEFAULT false,
  discomfort_area   text CHECK (
    discomfort_area IS NULL OR
    (length(btrim(discomfort_area)) > 0 AND length(discomfort_area) <= 100)
  ),
  note_to_coach     text CHECK (note_to_coach IS NULL OR length(note_to_coach) <= 1000),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT discomfort_fields_consistency CHECK (
    (has_discomfort = true AND discomfort_area IS NOT NULL AND length(btrim(discomfort_area)) > 0) OR
    (has_discomfort = false AND discomfort_area IS NULL)
  )
);

-- 7. Idempotency tracking table (caller/mutation-scoped composite primary key with atomic reservation)
CREATE TABLE app_private.idempotency_keys (
  caller_id         uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  mutation_type     text NOT NULL CHECK (
    mutation_type IN ('START_SESSION', 'RECORD_SET', 'SUBSTITUTE_EXERCISE', 'COMPLETE_SESSION', 'SYNC_BUNDLE')
  ),
  key               uuid NOT NULL,
  status            text NOT NULL DEFAULT 'started' CHECK (status IN ('started', 'completed')),
  payload_hash      text NOT NULL,
  response_payload  jsonb NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (caller_id, mutation_type, key)
);

CREATE INDEX idx_idempotency_keys_caller ON app_private.idempotency_keys (caller_id, created_at DESC);

-- 8. Explicit privilege revocation & grant (ADR-002: mutations route through RPCs only)
REVOKE ALL ON TABLE public.workout_sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.session_exercises FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.session_sets FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.session_modifications FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.session_feedback FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.session_private_feedback FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.workout_sessions TO authenticated;
GRANT SELECT ON TABLE public.session_exercises TO authenticated;
GRANT SELECT ON TABLE public.session_sets TO authenticated;
GRANT SELECT ON TABLE public.session_modifications TO authenticated;
GRANT SELECT ON TABLE public.session_feedback TO authenticated;
GRANT SELECT ON TABLE public.session_private_feedback TO authenticated;

-- app_private.idempotency_keys is never exposed through PostgREST at all (no
-- REVOKE/GRANT to anon/authenticated needed beyond the schema already being
-- unexposed); only SECURITY DEFINER RPC internals (Task 4.4) touch it.
