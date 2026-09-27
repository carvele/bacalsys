-- =============================================================================
-- workout_hierarchy_schema
-- Roadmap v1.2 · Sprint 3 · Task 3.2 (Section 10, Feature 4.1)
--
--   workout_templates → workout_versions → workout_blocks → workout_items
--                                                          → workout_item_sets
--
-- Prescription only: no session, feedback or assignment tables exist yet
-- (Sprint 4 / Sprint 5). Sessions and assignments will reference
-- workout_versions(id).
--
-- History is permanent: template / version / exercise / creator FKs are
-- ON DELETE RESTRICT. Only the descendant chain cascades, and it can only ever
-- cascade from an UNSEALED version (immutability triggers, next migration).
-- RLS is enabled here so no window exists in which the tables are open; the
-- select policies follow in workout_read_predicates_rls, and clients never get
-- any DML grant at all.
-- =============================================================================

-- 1. Workout Templates -----------------------------------------------------------
CREATE TABLE public.workout_templates (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  name             text NOT NULL CHECK (length(btrim(name)) > 0 AND length(name) <= 100),
  description      text CHECK (description IS NULL OR length(description) <= 1000),
  visibility       text NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'organization')),
  created_by       uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  is_archived      boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX workout_templates_org_idx ON public.workout_templates (organization_id);
CREATE INDEX workout_templates_creator_idx ON public.workout_templates (created_by);
CREATE INDEX workout_templates_visibility_idx ON public.workout_templates (organization_id, visibility) WHERE is_archived = false;

CREATE TRIGGER workout_templates_set_updated_at
BEFORE UPDATE ON public.workout_templates
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

-- 2. Workout Versions ------------------------------------------------------------
CREATE TABLE public.workout_versions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id      uuid NOT NULL REFERENCES public.workout_templates (id) ON DELETE RESTRICT,
  version_number   integer NOT NULL CHECK (version_number >= 1),
  notes            text CHECK (notes IS NULL OR length(notes) <= 1000),
  created_by       uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  is_sealed        boolean NOT NULL DEFAULT false,
  sealed_at        timestamptz NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_workout_version UNIQUE (template_id, version_number),
  CONSTRAINT version_sealed_consistency CHECK (
    (is_sealed = true AND sealed_at IS NOT NULL) OR
    (is_sealed = false AND sealed_at IS NULL)
  )
);

CREATE INDEX workout_versions_template_idx ON public.workout_versions (template_id, version_number DESC);
CREATE INDEX workout_versions_creator_idx ON public.workout_versions (created_by);

-- 3. Workout Blocks --------------------------------------------------------------
CREATE TABLE public.workout_blocks (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workout_version_id     uuid NOT NULL REFERENCES public.workout_versions (id) ON DELETE CASCADE,
  order_in_workout       integer NOT NULL CHECK (order_in_workout >= 1),
  title                  text NOT NULL CHECK (length(btrim(title)) > 0 AND length(title) <= 100),
  block_type             text NOT NULL CHECK (block_type IN ('standard_set', 'superset', 'circuit', 'amrap')),
  circuit_rounds         integer CHECK (circuit_rounds IS NULL OR circuit_rounds >= 1),
  amrap_duration_seconds integer CHECK (amrap_duration_seconds IS NULL OR amrap_duration_seconds >= 30),
  notes                  text CHECK (notes IS NULL OR length(notes) <= 500),
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_block_order UNIQUE (workout_version_id, order_in_workout),
  CONSTRAINT block_amrap_duration_consistency CHECK (
    (block_type = 'amrap' AND amrap_duration_seconds IS NOT NULL) OR
    (block_type <> 'amrap' AND amrap_duration_seconds IS NULL)
  ),
  CONSTRAINT block_circuit_rounds_consistency CHECK (
    (block_type = 'circuit' AND circuit_rounds IS NOT NULL) OR
    (block_type <> 'circuit' AND circuit_rounds IS NULL)
  )
);

CREATE INDEX workout_blocks_version_order_idx ON public.workout_blocks (workout_version_id, order_in_workout);

-- 4. Workout Items ---------------------------------------------------------------
CREATE TABLE public.workout_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  block_id          uuid NOT NULL REFERENCES public.workout_blocks (id) ON DELETE CASCADE,
  exercise_id       uuid NOT NULL REFERENCES public.exercises (id) ON DELETE RESTRICT,
  order_in_block    integer NOT NULL CHECK (order_in_block >= 1),
  -- Immutable prescription snapshot: later edits to exercises.measurement_types
  -- never touch published versions. AMRAP is a block structure, not a mode.
  measurement_mode  text NOT NULL CHECK (
    measurement_mode IN (
      'reps', 'duration', 'holds', 'distance',
      'until_failure', 'added_weight', 'assisted_weight', 'technique_practice'
    )
  ),
  notes             text CHECK (notes IS NULL OR length(notes) <= 500),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_item_order UNIQUE (block_id, order_in_block)
);

CREATE INDEX workout_items_block_order_idx ON public.workout_items (block_id, order_in_block);
CREATE INDEX workout_items_exercise_idx ON public.workout_items (exercise_id);

-- 5. Workout Item Sets -----------------------------------------------------------
CREATE TABLE public.workout_item_sets (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workout_item_id         uuid NOT NULL REFERENCES public.workout_items (id) ON DELETE CASCADE,
  set_number              integer NOT NULL CHECK (set_number >= 1),
  target_reps             integer CHECK (target_reps IS NULL OR (target_reps >= 1 AND target_reps <= 1000)),
  target_duration_seconds integer CHECK (target_duration_seconds IS NULL OR (target_duration_seconds >= 1 AND target_duration_seconds <= 7200)),
  target_distance_meters  numeric(8, 2) CHECK (target_distance_meters IS NULL OR (target_distance_meters > 0.0 AND target_distance_meters <= 100000.0)),
  target_load_kg          numeric(6, 2) CHECK (target_load_kg IS NULL OR (target_load_kg >= 0.00 AND target_load_kg <= 500.00)),
  load_type               text CHECK (load_type IS NULL OR load_type IN ('bodyweight', 'added', 'assisted')),
  target_rest_seconds     integer CHECK (target_rest_seconds IS NULL OR (target_rest_seconds >= 0 AND target_rest_seconds <= 1800)),
  target_rpe              numeric(3, 1) CHECK (target_rpe IS NULL OR (target_rpe >= 1.0 AND target_rpe <= 10.0)),
  notes                   text CHECK (notes IS NULL OR length(notes) <= 500),
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_set_number UNIQUE (workout_item_id, set_number),
  -- Hardened vs the Section 10 listing (finding F-S3-02): a NULL load_type made the
  -- first branch NULL (unknown), which a CHECK treats as satisfied, so a load with no
  -- type slipped through. The explicit IS NOT NULL closes that three-valued-logic hole.
  CONSTRAINT set_load_consistency CHECK (
    (target_load_kg IS NOT NULL AND target_load_kg > 0 AND load_type IS NOT NULL AND load_type IN ('added', 'assisted')) OR
    (target_load_kg IS NULL AND (load_type IS NULL OR load_type = 'bodyweight'))
  )
);

CREATE INDEX workout_item_sets_item_set_idx ON public.workout_item_sets (workout_item_id, set_number);

-- 6. Explicit privileges (ADR-002) ------------------------------------------------
-- SELECT only (filtered by RLS). All mutation is via public RPC wrappers →
-- app_private internals; direct client DML fails with 42501.
ALTER TABLE public.workout_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_item_sets ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.workout_templates FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.workout_versions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.workout_blocks FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.workout_items FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.workout_item_sets FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.workout_templates TO authenticated;
GRANT SELECT ON TABLE public.workout_versions TO authenticated;
GRANT SELECT ON TABLE public.workout_blocks TO authenticated;
GRANT SELECT ON TABLE public.workout_items TO authenticated;
GRANT SELECT ON TABLE public.workout_item_sets TO authenticated;
