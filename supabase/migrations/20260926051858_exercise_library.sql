-- =============================================================================
-- exercise_library
-- Roadmap v1.2 · Sprint 2 · Task 2.7 (Section 9 §3, Features 3.1 / 3.2)
--
-- Official catalog + member custom exercises in one table, with the
-- private → pending_approval → approved | rejected state machine enforced by
-- constraints here and by the workflow RPCs in the next migration.
-- RLS is enabled immediately; grants and policies follow in exercise_workflow.
-- =============================================================================

CREATE TABLE public.exercises (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  slug               text NOT NULL CHECK (length(slug) <= 140 AND slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  category           text NOT NULL CHECK (category IN ('push', 'pull', 'legs', 'core', 'skill', 'mobility')),
  description        text CHECK (description IS NULL OR length(description) <= 2000),
  measurement_types  text[] NOT NULL CHECK (
    cardinality(measurement_types) >= 1
    AND measurement_types <@ ARRAY[
      'reps', 'duration', 'holds', 'distance', 'amrap', 'until_failure',
      'added_weight', 'assisted_weight', 'technique_practice'
    ]::text[]
  ),
  -- 'none' = bodyweight only, and it cannot be combined with equipment.
  equipment_needed   text[] NOT NULL CHECK (
    cardinality(equipment_needed) >= 1
    AND equipment_needed <@ ARRAY['none', 'bar', 'rings', 'parallettes', 'resistance_bands', 'weight_vest']::text[]
    AND NOT ('none' = ANY (equipment_needed) AND cardinality(equipment_needed) > 1)
  ),
  is_official        boolean NOT NULL DEFAULT false,
  created_by         uuid REFERENCES public.profiles (id) ON DELETE RESTRICT,
  status             text NOT NULL DEFAULT 'private'
                     CHECK (status IN ('private', 'pending_approval', 'approved', 'rejected')),
  rejection_reason   text CHECK (rejection_reason IS NULL OR length(rejection_reason) <= 500),
  reviewed_by        uuid REFERENCES public.profiles (id) ON DELETE RESTRICT,
  reviewed_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- Seeded official exercises may have NULL created_by; user custom exercises require created_by
  CONSTRAINT exercise_creator_check CHECK (
    created_by IS NOT NULL OR (status = 'approved' AND is_official = true)
  ),
  -- State machine consistency
  CONSTRAINT exercise_status_consistency CHECK (
    (status = 'approved' AND is_official = true) OR
    (status IN ('private', 'pending_approval', 'rejected') AND is_official = false)
  ),
  -- A rejection always carries a non-blank reason; nothing else carries one.
  CONSTRAINT exercise_rejection_reason_consistency CHECK (
    (status = 'rejected') = (rejection_reason IS NOT NULL AND length(btrim(rejection_reason)) > 0)
  ),
  CONSTRAINT exercise_review_fields_consistent CHECK (reviewed_by IS NULL OR reviewed_at IS NOT NULL)
);

-- Slug Uniqueness Strategy (verbatim, Section 9 §3)
-- Approved official exercises must have globally unique slugs
CREATE UNIQUE INDEX approved_exercise_slug_idx
ON public.exercises (slug)
WHERE status = 'approved';

-- Custom/private exercises must be unique per creator
CREATE UNIQUE INDEX creator_exercise_slug_idx
ON public.exercises (created_by, slug)
WHERE created_by IS NOT NULL;

CREATE INDEX exercises_review_queue_idx ON public.exercises (created_at) WHERE status = 'pending_approval';
CREATE INDEX exercises_reviewed_by_idx ON public.exercises (reviewed_by);
CREATE INDEX exercises_catalog_idx ON public.exercises (category, name) WHERE status = 'approved';

ALTER TABLE public.exercises ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exercises FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Slug default: derived from the name when the client does not send one.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.exercise_default_slug()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.slug IS NULL OR btrim(NEW.slug) = '' THEN
    NEW.slug := left(
      btrim(regexp_replace(lower(NEW.name), '[^a-z0-9]+', '-', 'g'), '-'),
      140
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.exercise_default_slug() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER exercises_default_slug
BEFORE INSERT ON public.exercises
FOR EACH ROW EXECUTE FUNCTION app_private.exercise_default_slug();

-- Submissions and review decisions are governance events.
CREATE TRIGGER audit_exercises
AFTER INSERT OR UPDATE OR DELETE ON public.exercises
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();

-- -----------------------------------------------------------------------------
-- Official seed catalog (reference data, every environment).
-- Feature 3.1 categories / measurement types / equipment.
-- -----------------------------------------------------------------------------
SELECT set_config('bacalsys.actor_type', 'migration', true);

INSERT INTO public.exercises
  (name, slug, category, description, measurement_types, equipment_needed, is_official, status)
SELECT s.name, s.slug, s.category, s.description, s.measurement_types, s.equipment_needed, true, 'approved'
FROM (VALUES
  -- Push
  ('Push-up',             'push-up',             'push', 'Hands under shoulders, body in one straight line.',        ARRAY['reps', 'amrap', 'until_failure', 'added_weight'], ARRAY['none']),
  ('Diamond Push-up',     'diamond-push-up',     'push', 'Hands together under the chest; triceps emphasis.',        ARRAY['reps', 'amrap'],                                 ARRAY['none']),
  ('Pike Push-up',        'pike-push-up',        'push', 'Hips high; vertical pressing toward handstand push-ups.',   ARRAY['reps'],                                          ARRAY['none']),
  ('Pseudo Planche Push-up', 'pseudo-planche-push-up', 'push', 'Hands turned out by the hips, shoulders leaning forward.', ARRAY['reps'],                                   ARRAY['none']),
  ('Parallel Bar Dip',    'parallel-bar-dip',    'push', 'Shoulders down, lower until the upper arm is parallel.',    ARRAY['reps', 'added_weight', 'assisted_weight'],       ARRAY['bar']),
  ('Ring Dip',            'ring-dip',            'push', 'Dip on rings with the rings turned out at the top.',        ARRAY['reps', 'assisted_weight'],                       ARRAY['rings']),
  ('Handstand Push-up',   'handstand-push-up',   'push', 'Wall-supported or freestanding vertical press.',            ARRAY['reps', 'technique_practice'],                    ARRAY['none']),
  -- Pull
  ('Pull-up',             'pull-up',             'pull', 'Overhand grip, from dead hang until the chin clears the bar.', ARRAY['reps', 'amrap', 'added_weight', 'assisted_weight'], ARRAY['bar']),
  ('Chin-up',             'chin-up',             'pull', 'Underhand grip pull-up.',                                   ARRAY['reps', 'added_weight', 'assisted_weight'],       ARRAY['bar']),
  ('Australian Row',      'australian-row',      'pull', 'Horizontal row under a low bar, body straight.',            ARRAY['reps'],                                          ARRAY['bar']),
  ('Ring Row',            'ring-row',            'pull', 'Horizontal row on rings; adjust the angle for difficulty.', ARRAY['reps'],                                          ARRAY['rings']),
  ('Scapular Pull-up',    'scapular-pull-up',    'pull', 'Straight arms; depress and retract the shoulder blades.',  ARRAY['reps'],                                          ARRAY['bar']),
  ('Muscle-up',           'muscle-up',           'pull', 'Explosive pull transitioning over the bar into a dip.',     ARRAY['reps', 'technique_practice'],                    ARRAY['bar']),
  ('Band-assisted Pull-up', 'band-assisted-pull-up', 'pull', 'Pull-up with a resistance band under the knee or foot.', ARRAY['reps'],                                     ARRAY['bar', 'resistance_bands']),
  -- Legs
  ('Bodyweight Squat',    'bodyweight-squat',    'legs', 'Full-depth squat with heels down.',                         ARRAY['reps', 'added_weight'],                          ARRAY['none']),
  ('Bulgarian Split Squat', 'bulgarian-split-squat', 'legs', 'Rear foot elevated single-leg squat.',                 ARRAY['reps', 'added_weight'],                          ARRAY['none']),
  ('Pistol Squat',        'pistol-squat',        'legs', 'Single-leg squat with the free leg extended.',              ARRAY['reps', 'technique_practice'],                    ARRAY['none']),
  ('Nordic Hamstring Curl', 'nordic-hamstring-curl', 'legs', 'Kneeling eccentric hamstring lowering.',               ARRAY['reps'],                                          ARRAY['none']),
  ('Walking Lunge',       'walking-lunge',       'legs', 'Alternating forward lunges over a distance.',               ARRAY['reps', 'distance', 'added_weight'],              ARRAY['none']),
  -- Core
  ('Hollow Body Hold',    'hollow-body-hold',    'core', 'Lower back pressed down, arms and legs extended.',          ARRAY['duration', 'holds'],                             ARRAY['none']),
  ('Plank',               'plank',               'core', 'Forearm plank with a neutral spine.',                       ARRAY['duration'],                                      ARRAY['none']),
  ('L-sit',               'l-sit',               'core', 'Straight-arm support with legs held horizontal.',           ARRAY['duration', 'holds'],                             ARRAY['parallettes']),
  ('Hanging Leg Raise',   'hanging-leg-raise',   'core', 'From dead hang, raise straight legs to the bar.',           ARRAY['reps'],                                          ARRAY['bar']),
  ('Dragon Flag',         'dragon-flag',         'core', 'Lower a rigid body from the shoulders on a bench.',         ARRAY['reps', 'technique_practice'],                    ARRAY['none']),
  -- Skill
  ('Handstand Hold',      'handstand-hold',      'skill', 'Wall-supported or freestanding handstand.',                ARRAY['duration', 'holds', 'technique_practice'],       ARRAY['none']),
  ('Tuck Front Lever',    'tuck-front-lever',    'skill', 'Horizontal body hold under the bar with knees tucked.',    ARRAY['duration', 'holds'],                             ARRAY['bar']),
  ('Tuck Planche',        'tuck-planche',        'skill', 'Straight-arm support with knees tucked, hips at shoulder height.', ARRAY['duration', 'holds'],                     ARRAY['parallettes']),
  ('Tuck Back Lever',     'tuck-back-lever',     'skill', 'Inverted horizontal hold facing down with knees tucked.',  ARRAY['duration', 'holds'],                             ARRAY['rings']),
  -- Mobility
  ('German Hang',         'german-hang',         'mobility', 'Passive shoulder-extension hang, eased in slowly.',     ARRAY['duration'],                                      ARRAY['bar']),
  ('Shoulder Dislocate',  'shoulder-dislocate',  'mobility', 'Band pass-through overhead and behind the back.',       ARRAY['reps'],                                          ARRAY['resistance_bands']),
  ('Pancake Stretch',     'pancake-stretch',     'mobility', 'Seated straddle fold with a flat back.',                ARRAY['duration'],                                      ARRAY['none']),
  ('Deep Squat Hold',     'deep-squat-hold',     'mobility', 'Relaxed bottom-of-squat hold.',                         ARRAY['duration'],                                      ARRAY['none'])
) AS s(name, slug, category, description, measurement_types, equipment_needed)
ON CONFLICT (slug) WHERE status = 'approved' DO NOTHING;
