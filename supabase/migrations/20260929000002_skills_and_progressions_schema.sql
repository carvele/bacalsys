-- =============================================================================
-- skills_and_progressions_schema
-- Roadmap v1.2 · Sprint 6 · Task 6.2 (Section 13, "Database Schemas, DDL & Invariants")
--
--   skills → skill_progressions (ordered rungs)
--   athlete_skill_status   Tier 1  trained    (which rung an athlete is working on)
--   skill_attempts         Tier 2  attempted  (objective evidence, awaiting review)
--   skill_achievements     Tier 3  verified   (coach/officer-verified milestones)
--
-- F-S6-P06  Structural lineage: athlete_skill_status pairs (skill_id,
--           current_progression_id) through a composite FK, so a skill can never
--           point at a rung that belongs to a different skill. Actor columns
--           (reviewed_by / verified_by / revoked_by) are ON DELETE RESTRICT,
--           never SET NULL, so audit attribution survives and the consistency
--           CHECKs below can never be silently broken by a profile delete.
-- F-S6-P09  No free-text channel for health/injury disclosure: there is NO notes
--           column on athlete_skill_status or skill_attempts. The only prose is
--           review_feedback (written by the reviewer, visible to athlete /
--           current coach / VP-President only) and revocation_reason.
-- ADR-002   Clients get SELECT only; every mutation goes through a public
--           SECURITY INVOKER wrapper → app_private SECURITY DEFINER internal
--           (migration 7). RLS is enabled here so no window exists in which the
--           tables are open; the policies arrive in migration 5.
-- =============================================================================

-- 1. Skills catalog (club-defined progression trees) --------------------------------
CREATE TABLE public.skills (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  name            text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  slug            text NOT NULL CHECK (length(slug) <= 120 AND slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  category        text NOT NULL CHECK (category IN ('push', 'pull', 'core', 'legs', 'hand_balancing', 'other')),
  description     text CHECK (description IS NULL OR length(description) <= 2000),
  icon_name       text CHECK (icon_name IS NULL OR length(icon_name) <= 50),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_skills_org_slug UNIQUE (organization_id, slug)
);

CREATE TRIGGER trg_skills_updated_at
BEFORE UPDATE ON public.skills
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

CREATE INDEX skills_org_idx ON public.skills (organization_id);
CREATE INDEX skills_category_idx ON public.skills (category);

-- 2. Skill progressions (ordered rungs per ladder) ----------------------------------
CREATE TABLE public.skill_progressions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_id            uuid NOT NULL REFERENCES public.skills (id) ON DELETE CASCADE,
  rank_order          integer NOT NULL CHECK (rank_order >= 1),
  name                text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description         text CHECK (description IS NULL OR length(description) <= 2000),
  target_hold_seconds integer CHECK (target_hold_seconds IS NULL OR target_hold_seconds > 0),
  target_reps         integer CHECK (target_reps IS NULL OR target_reps > 0),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_skill_progressions_rank UNIQUE (skill_id, rank_order),
  -- Referenced by the composite FK on athlete_skill_status (F-S6-P06).
  CONSTRAINT uq_skill_progressions_skill_id UNIQUE (skill_id, id),
  CONSTRAINT skill_progression_target_check CHECK (
    target_hold_seconds IS NOT NULL OR target_reps IS NOT NULL
  )
);

CREATE TRIGGER trg_skill_progressions_updated_at
BEFORE UPDATE ON public.skill_progressions
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

-- (skill_id, rank_order) is already indexed by uq_skill_progressions_rank.

-- 3. Athlete skill status (Tier 1: trained — no free text, F-S6-P09) ----------------
CREATE TABLE public.athlete_skill_status (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id             uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  skill_id               uuid NOT NULL REFERENCES public.skills (id) ON DELETE RESTRICT,
  current_progression_id uuid NOT NULL,
  started_training_at    timestamptz NOT NULL DEFAULT now(),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_athlete_skill_status UNIQUE (athlete_id, skill_id),
  CONSTRAINT fk_athlete_skill_status_progression
    FOREIGN KEY (skill_id, current_progression_id)
    REFERENCES public.skill_progressions (skill_id, id)
    ON DELETE RESTRICT
);

CREATE TRIGGER trg_athlete_skill_status_updated_at
BEFORE UPDATE ON public.athlete_skill_status
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

-- (athlete_id, skill_id) is already indexed by uq_athlete_skill_status; the two
-- below cover the FK columns it does not lead with.
CREATE INDEX athlete_skill_status_skill_idx ON public.athlete_skill_status (skill_id);
CREATE INDEX athlete_skill_status_progression_idx ON public.athlete_skill_status (current_progression_id);

-- 4. Skill attempts (Tier 2: attempted — objective only, F-S6-P06 / F-S6-P09) -------
CREATE TABLE public.skill_attempts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id          uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  progression_id      uuid NOT NULL REFERENCES public.skill_progressions (id) ON DELETE RESTRICT,
  attempt_date        date NOT NULL DEFAULT CURRENT_DATE,
  actual_hold_seconds integer CHECK (actual_hold_seconds IS NULL OR actual_hold_seconds > 0),
  actual_reps         integer CHECK (actual_reps IS NULL OR actual_reps > 0),
  video_url           text CHECK (video_url IS NULL OR (length(video_url) <= 2048 AND video_url ~ '^https?://')),
  status              text NOT NULL DEFAULT 'pending_review' CHECK (status IN ('pending_review', 'approved', 'rejected')),
  reviewed_by         uuid REFERENCES public.profiles (id) ON DELETE RESTRICT,
  reviewed_at         timestamptz,
  review_feedback     text CHECK (review_feedback IS NULL OR length(review_feedback) <= 1000),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_attempt_measurement_check CHECK (
    actual_hold_seconds IS NOT NULL OR actual_reps IS NOT NULL
  ),
  CONSTRAINT skill_attempt_review_consistency CHECK (
    (status = 'pending_review' AND reviewed_at IS NULL AND reviewed_by IS NULL) OR
    (status IN ('approved', 'rejected') AND reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL)
  )
);

CREATE TRIGGER trg_skill_attempts_updated_at
BEFORE UPDATE ON public.skill_attempts
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

CREATE INDEX skill_attempts_athlete_idx ON public.skill_attempts (athlete_id, attempt_date DESC);
CREATE INDEX skill_attempts_pending_idx ON public.skill_attempts (created_at ASC) WHERE status = 'pending_review';
CREATE INDEX skill_attempts_progression_idx ON public.skill_attempts (progression_id);
CREATE INDEX skill_attempts_reviewed_by_idx ON public.skill_attempts (reviewed_by) WHERE reviewed_by IS NOT NULL;

-- 5. Skill achievements (Tier 3: verified milestones, F-S6-P06) ---------------------
CREATE TABLE public.skill_achievements (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id        uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  progression_id    uuid NOT NULL REFERENCES public.skill_progressions (id) ON DELETE RESTRICT,
  verified_by       uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  verified_at       timestamptz NOT NULL DEFAULT now(),
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'revoked')),
  revoked_by        uuid REFERENCES public.profiles (id) ON DELETE RESTRICT,
  revoked_at        timestamptz,
  revocation_reason text,
  skill_attempt_id  uuid REFERENCES public.skill_attempts (id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_athlete_skill_achievement UNIQUE (athlete_id, progression_id),
  -- Revocation is all-or-nothing: a revoked row always carries who, when and a
  -- non-blank reason; a non-revoked row carries none of them.
  CONSTRAINT skill_achievement_revocation_consistency CHECK (
    (status = 'revoked'
       AND revoked_by IS NOT NULL AND revoked_at IS NOT NULL
       AND revocation_reason IS NOT NULL
       AND length(btrim(revocation_reason)) > 0 AND length(revocation_reason) <= 1000)
    OR
    (status <> 'revoked'
       AND revoked_by IS NULL AND revoked_at IS NULL AND revocation_reason IS NULL)
  )
);

CREATE TRIGGER trg_skill_achievements_updated_at
BEFORE UPDATE ON public.skill_achievements
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

CREATE INDEX skill_achievements_athlete_idx ON public.skill_achievements (athlete_id);
CREATE INDEX skill_achievements_progression_idx ON public.skill_achievements (progression_id);
CREATE INDEX skill_achievements_status_idx ON public.skill_achievements (status);
CREATE INDEX skill_achievements_verified_by_idx ON public.skill_achievements (verified_by);
CREATE INDEX skill_achievements_revoked_by_idx ON public.skill_achievements (revoked_by) WHERE revoked_by IS NOT NULL;
CREATE INDEX skill_achievements_attempt_idx ON public.skill_achievements (skill_attempt_id) WHERE skill_attempt_id IS NOT NULL;

-- 6. RLS on (policies in migration 5: with none, every row is denied) + grants (ADR-002)
ALTER TABLE public.skills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skill_progressions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.athlete_skill_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skill_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skill_achievements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.skills FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.skills TO authenticated;

REVOKE ALL ON TABLE public.skill_progressions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.skill_progressions TO authenticated;

REVOKE ALL ON TABLE public.athlete_skill_status FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.athlete_skill_status TO authenticated;

REVOKE ALL ON TABLE public.skill_attempts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.skill_attempts TO authenticated;

REVOKE ALL ON TABLE public.skill_achievements FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.skill_achievements TO authenticated;
