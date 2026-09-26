-- =============================================================================
-- coach_assignments
-- Roadmap v1.2 · Sprint 2 · Task 2.1 (Section 9 §1, Rule D)
--
-- Primary coach ↔ athlete relationship with a half-open validity window
-- [started_at, ended_at). History is permanent:
--   * every FK to profiles is ON DELETE RESTRICT, so deleting a member never
--     cascades away coaching history;
--   * clients get no INSERT / UPDATE / DELETE grant at all. Assignment and
--     reassignment happen only through public.assign_primary_coach()
--     (next migrations), which closes the old row instead of deleting it;
--   * every change is written to the append-only audit log.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Active-membership guard used by every Sprint 2 policy and RPC (fail closed:
-- pending, suspended and rejected members are all "not active").
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.is_active_member()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.status = 'active'
  );
$$;
REVOKE EXECUTE ON FUNCTION app_private.is_active_member() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.is_active_member() TO authenticated;

-- -----------------------------------------------------------------------------
-- Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.coach_assignments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id   uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  coach_id     uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  assigned_by  uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  started_at   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ended_at     timestamptz,
  ended_by     uuid REFERENCES public.profiles (id) ON DELETE RESTRICT,
  notes        text CHECK (notes IS NULL OR length(notes) <= 1000),
  created_at   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- Self-coaching prevention
  CONSTRAINT coach_not_self CHECK (athlete_id <> coach_id),
  -- Valid temporal interval
  CONSTRAINT valid_assignment_window CHECK (ended_at IS NULL OR ended_at >= started_at),
  -- ended_by only exists on a closed row (it may stay NULL for system closures).
  CONSTRAINT coach_assignments_end_fields_consistent CHECK (ended_at IS NOT NULL OR ended_by IS NULL)
);

-- Single active coach invariant (verbatim, Section 9 §1)
CREATE UNIQUE INDEX one_active_primary_coach_per_athlete
ON public.coach_assignments (athlete_id)
WHERE ended_at IS NULL;

-- "My Athletes" and current/former coach lookups.
CREATE INDEX coach_assignments_coach_active_idx
  ON public.coach_assignments (coach_id) WHERE ended_at IS NULL;
CREATE INDEX coach_assignments_coach_athlete_idx
  ON public.coach_assignments (coach_id, athlete_id, started_at);
-- Athlete history, plus covering indexes for the RESTRICT foreign keys.
CREATE INDEX coach_assignments_athlete_history_idx
  ON public.coach_assignments (athlete_id, started_at DESC);
CREATE INDEX coach_assignments_assigned_by_idx ON public.coach_assignments (assigned_by);
CREATE INDEX coach_assignments_ended_by_idx ON public.coach_assignments (ended_by);

-- -----------------------------------------------------------------------------
-- Grants & RLS: read-only to clients.
--   read: active members only, and only rows they are party to (coach or
--         athlete) or, with coaches:assign, rows in their own organization.
-- -----------------------------------------------------------------------------
ALTER TABLE public.coach_assignments ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.coach_assignments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.coach_assignments TO authenticated;

CREATE POLICY coach_assignments_select ON public.coach_assignments
FOR SELECT TO authenticated
USING (
  (SELECT app_private.is_active_member())
  AND (
    coach_id = (SELECT auth.uid())
    OR athlete_id = (SELECT auth.uid())
    OR (
      (SELECT app_private.has_permission('coaches:assign'))
      AND app_private.same_organization(athlete_id)
    )
  )
);

-- -----------------------------------------------------------------------------
-- Audit: assignment (insert) and handover (update of ended_at/ended_by).
-- -----------------------------------------------------------------------------
CREATE TRIGGER audit_coach_assignments
AFTER INSERT OR UPDATE OR DELETE ON public.coach_assignments
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();
