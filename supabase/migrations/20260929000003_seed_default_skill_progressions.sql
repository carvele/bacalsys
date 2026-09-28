-- =============================================================================
-- seed_default_skill_progressions
-- Roadmap v1.2 · Sprint 6 · Task 6.3 (Section 13, "Frozen Initial Criteria for
-- Seeded Calisthenics Ladders", F-S6-P07)
--
-- Six foundational ladders / 28 rungs for the default organization:
--   Planche (4) · Front Lever (5) · Strict Muscle-Up (5) · Handstand Balance (5)
--   Pistol Squat (4) · L-Sit to V-Sit (5)
--
-- Reference data. It must reach BOTH kinds of environment:
--   * hosted projects, where the default organization already exists when this
--     migration runs → the migration seeds it directly;
--   * a fresh `db reset` / the offline harness, where seed.sql creates the
--     organization AFTER the migrations → seed.sql calls the same function.
-- app_private.seed_default_skill_ladders(org) is therefore the single, idempotent
-- implementation. Re-running it never overwrites an edit: skills and rungs are
-- inserted ON CONFLICT DO NOTHING, so criteria a coach later changed through
-- public.update_skill_progression survive any re-seed.
-- =============================================================================

CREATE FUNCTION app_private.seed_default_skill_ladders(p_organization_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.skills (organization_id, name, slug, category, description)
  SELECT p_organization_id, s.name, s.slug, s.category, s.description
  FROM (VALUES
    ('Planche',           'planche',       'push',           'Straight-arm horizontal push, from a tuck hold to the full planche.'),
    ('Front Lever',       'front-lever',   'pull',           'Straight-arm horizontal pull, from a tuck hold to the full front lever.'),
    ('Strict Muscle-Up',  'muscle-up',     'pull',           'The pull-to-dip transition over the bar or rings without kipping.'),
    ('Handstand Balance', 'handstand',     'hand_balancing', 'Inverted balance from the wall to a freestanding handstand push-up.'),
    ('Pistol Squat',      'pistol-squat',  'legs',           'Single-leg squat strength and mobility, from box step-downs to weighted pistols.'),
    ('L-Sit to V-Sit',    'l-sit',         'core',           'Compression strength, from a tucked L-sit to the V-sit.')
  ) AS s(name, slug, category, description)
  ON CONFLICT (organization_id, slug) DO NOTHING;

  INSERT INTO public.skill_progressions (skill_id, rank_order, name, description, target_hold_seconds, target_reps)
  SELECT sk.id, r.rank_order, r.name, r.description, r.hold, r.reps
  FROM (VALUES
    -- 1. Planche
    ('planche', 1, 'Tuck Planche',              15,   NULL::integer, 'Hips level with shoulders, knees tucked tight to chest, arms straight, protract scapulae.'),
    ('planche', 2, 'Advanced Tuck Planche',     12,   NULL,          'Hips extended to 90 degrees between torso and thighs, flat back, straight arms.'),
    ('planche', 3, 'Straddle Planche',          10,   NULL,          'Legs fully extended and straddled wide, body parallel to ground, straight arms.'),
    ('planche', 4, 'Full Planche',              5,    NULL,          'Legs together and fully extended, body straight and horizontal, complete scapular protraction.'),
    -- 2. Front Lever
    ('front-lever', 1, 'Tuck Front Lever',           15, NULL, 'Knees tucked to chest, arms straight, body held horizontal from shoulders to hips.'),
    ('front-lever', 2, 'Advanced Tuck Front Lever',  12, NULL, 'Thighs at 90 degrees to torso, flat horizontal back, locked elbows.'),
    ('front-lever', 3, 'One-Leg Front Lever',        10, NULL, 'One leg fully extended in line with torso, other leg tucked to chest, straight arms.'),
    ('front-lever', 4, 'Straddle Front Lever',       10, NULL, 'Legs straight and straddled wide, body rigid and completely horizontal.'),
    ('front-lever', 5, 'Full Front Lever',           5,  NULL, 'Legs together and straight, horizontal bodyline from head to toe, depressed and retracted scapulae.'),
    -- 3. Strict Muscle-Up
    ('muscle-up', 1, 'High Pull-Up',            NULL, 8,  'Explosive pull-up bringing lower chest or sternum to the bar without kipping.'),
    ('muscle-up', 2, 'Straight Bar Dip',        NULL, 10, 'Full depth dip on a single straight bar, chest touches bar at bottom, full lockout.'),
    ('muscle-up', 3, 'Banded Muscle-Up',        NULL, 5,  'Strict muscle-up transition performed with light resistance band assistance.'),
    ('muscle-up', 4, 'Strict Bar Muscle-Up',    NULL, 3,  'Simultaneous two-arm transition over the bar without swinging, kipping, or knee drive.'),
    ('muscle-up', 5, 'Strict Ring Muscle-Up',   NULL, 3,  'Dead-hang false grip ring muscle-up, smooth transition, full ring dip lockout with turnout.'),
    -- 4. Handstand Balance
    ('handstand', 1, 'Chest-to-Wall Handstand Hold',     45,   NULL, 'Nose and toes touching wall, fully open shoulders, active elevation, posterior pelvic tilt.'),
    ('handstand', 2, 'Back-to-Wall Handstand Balance',   30,   NULL, 'Heels lightly tapping wall, finding fingertip balance line with stacked shoulders.'),
    ('handstand', 3, 'Freestanding Handstand Kick-Up',   15,   NULL, 'Controlled kick-up to solid straight freestanding handstand held for at least 15 seconds.'),
    ('handstand', 4, 'Freestanding Handstand Hold',      45,   NULL, 'Clean straight bodyline freestanding handstand with active finger control held 45 seconds.'),
    ('handstand', 5, 'Handstand Push-Up',                NULL, 3,    'Freestanding handstand push-up to head/hands tripod, pressing back to complete vertical lockout.'),
    -- 5. Pistol Squat
    ('pistol-squat', 1, 'Box Step-Down',                  NULL, 12, 'Slow controlled eccentric step-down from bench/box with free leg trailing, per leg.'),
    ('pistol-squat', 2, 'Assisted Pistol Squat',          NULL, 8,  'Full depth single-leg squat using light band or ring assistance, heel stays planted.'),
    ('pistol-squat', 3, 'Full Pistol Squat',              NULL, 5,  'Unassisted full depth single-leg squat, non-working leg straight out front, per leg.'),
    ('pistol-squat', 4, 'Weighted Pistol Squat (+10kg)',  NULL, 5,  'Full depth pistol squat holding 10kg kettlebell or dumbbell at chest, per leg.'),
    -- 6. L-Sit / V-Sit
    ('l-sit', 1, 'Tuck L-Sit',      20, NULL, 'On floor or parallettes, depressed scapulae, knees tucked to chest, feet off ground.'),
    ('l-sit', 2, 'One-Leg L-Sit',   15, NULL, 'One leg extended straight, other leg tucked, alternating legs, held 15 seconds.'),
    ('l-sit', 3, 'Full L-Sit',      15, NULL, 'Both legs locked straight parallel to ground, pointed toes, locked elbows, depressed shoulders.'),
    ('l-sit', 4, 'Straddle L-Sit',  10, NULL, 'Legs straddled wide and parallel to ground on parallettes or floor, active compression.'),
    ('l-sit', 5, 'V-Sit',           5,  NULL, 'Legs raised to 45-60 degrees above horizontal in acute V-angle, straight arms and knees.')
  ) AS r(slug, rank_order, name, hold, reps, description)
  JOIN public.skills sk ON sk.organization_id = p_organization_id AND sk.slug = r.slug
  ON CONFLICT (skill_id, rank_order) DO NOTHING;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.seed_default_skill_ladders(uuid) FROM PUBLIC, anon, authenticated;

-- Hosted / already-provisioned environments: seed the default organization now.
-- (A fresh database has no organization yet; seed.sql calls the function instead.)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.organizations WHERE id = '00000000-0000-4000-8000-000000000001') THEN
    PERFORM app_private.seed_default_skill_ladders('00000000-0000-4000-8000-000000000001');
  END IF;
END;
$$;
