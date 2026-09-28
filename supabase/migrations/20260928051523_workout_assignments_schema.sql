-- =============================================================================
-- workout_assignments_schema
-- Roadmap v1.2 · Sprint 5 · Task 5.1 (Section 12, "Database Schemas, DDL & Invariants")
--
--   workout_assignments  → assignment_targets
--                        → recurring_schedules (1:1, recurring assignments only)
--                        → assignment_occurrences (per-athlete, per-day events)
--   workout_sessions.assignment_occurrence_id gains its FK (ON DELETE RESTRICT,
--   F-S5-P08) plus a partial unique index: at most one session per occurrence.
--
-- The occurrence lifecycle trigger is the database-level state machine
-- (F-S5-P02): terminal history is immutable, lineage/temporal anchors never
-- change, the workout version may change only while `upcoming` (Rule C), and a
-- `missed` occurrence can only come back to `in_progress` when a structurally
-- valid linked in-progress session already exists (F-S5-P15 — pure database
-- state, no GUC / session-variable bypass of any kind).
--
-- Grants are explicit (ADR-002): clients get SELECT only, filtered by the RLS
-- policies of the next migration; every mutation is a public SECURITY INVOKER
-- wrapper → app_private SECURITY DEFINER internal (later migrations). RLS is
-- enabled here so no window exists in which the tables are open.
-- =============================================================================

-- 0. Idempotency mutation types (F-S5-P11) — adds ONLY the three scoped types and
--    preserves the five accepted Sprint 4 types.
ALTER TABLE app_private.idempotency_keys
  DROP CONSTRAINT IF EXISTS idempotency_keys_mutation_type_check;

ALTER TABLE app_private.idempotency_keys
  ADD CONSTRAINT idempotency_keys_mutation_type_check CHECK (
    mutation_type IN (
      'START_SESSION', 'RECORD_SET', 'SUBSTITUTE_EXERCISE', 'COMPLETE_SESSION', 'SYNC_BUNDLE',
      'CREATE_ASSIGNMENT', 'CANCEL_ASSIGNMENT', 'MIGRATE_ASSIGNMENT_VERSION'
    )
  );

-- 1. Workout Assignments (the programming event) -----------------------------------
CREATE TABLE public.workout_assignments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  workout_template_id uuid NOT NULL REFERENCES public.workout_templates (id) ON DELETE RESTRICT,
  workout_version_id  uuid NOT NULL REFERENCES public.workout_versions (id) ON DELETE RESTRICT,
  assigned_by         uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  target_date         date NULL,
  is_recurring        boolean NOT NULL DEFAULT false,
  notes               text NULL CHECK (notes IS NULL OR (length(btrim(notes)) > 0 AND length(notes) <= 2000)),
  status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled', 'completed')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT assignment_schedule_kind_check CHECK (
    (NOT is_recurring AND target_date IS NOT NULL) OR
    (is_recurring AND target_date IS NULL)
  )
);

CREATE TRIGGER trg_workout_assignments_updated_at
BEFORE UPDATE ON public.workout_assignments
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

CREATE INDEX workout_assignments_org_idx ON public.workout_assignments (organization_id);
CREATE INDEX workout_assignments_assigned_by_idx ON public.workout_assignments (assigned_by);
CREATE INDEX workout_assignments_template_idx ON public.workout_assignments (workout_template_id);
CREATE INDEX workout_assignments_version_idx ON public.workout_assignments (workout_version_id);
CREATE INDEX workout_assignments_status_idx ON public.workout_assignments (status);

-- 2. Assignment Targets (normalized multi-athlete mapping) -------------------------
CREATE TABLE public.assignment_targets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id  uuid NOT NULL REFERENCES public.workout_assignments (id) ON DELETE CASCADE,
  athlete_id     uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_assignment_target UNIQUE (assignment_id, athlete_id)
);

CREATE INDEX assignment_targets_athlete_idx ON public.assignment_targets (athlete_id);
CREATE INDEX assignment_targets_assignment_idx ON public.assignment_targets (assignment_id);

-- 3. Recurring Schedules (attached 1:1 to recurring assignments) -------------------
CREATE TABLE public.recurring_schedules (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id  uuid NOT NULL UNIQUE REFERENCES public.workout_assignments (id) ON DELETE CASCADE,
  days_of_week   smallint[] NOT NULL CHECK (
    cardinality(days_of_week) BETWEEN 1 AND 7 AND
    days_of_week <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]
  ),
  start_date     date NOT NULL,
  end_date       date NULL CHECK (end_date IS NULL OR end_date >= start_date),
  timezone       text NOT NULL DEFAULT 'Asia/Manila',
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

-- F-S5-P14: the schedule's timezone is always the organization's (22023).
CREATE FUNCTION app_private.validate_recurring_schedule_timezone()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_org_tz text;
BEGIN
  SELECT o.timezone INTO v_org_tz
  FROM public.workout_assignments a
  JOIN public.organizations o ON o.id = a.organization_id
  WHERE a.id = NEW.assignment_id;

  IF NEW.timezone IS DISTINCT FROM v_org_tz THEN
    RAISE EXCEPTION 'Recurring schedule timezone (%) must match organization timezone (%)',
      NEW.timezone, v_org_tz USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.validate_recurring_schedule_timezone() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_recurring_schedules_timezone
BEFORE INSERT OR UPDATE OF timezone ON public.recurring_schedules
FOR EACH ROW EXECUTE FUNCTION app_private.validate_recurring_schedule_timezone();

CREATE TRIGGER trg_recurring_schedules_updated_at
BEFORE UPDATE ON public.recurring_schedules
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

CREATE INDEX recurring_schedules_active_lookup_idx
ON public.recurring_schedules (is_active, start_date) WHERE is_active = true;

-- 4. Assignment Occurrences (per-athlete discrete scheduled events) ----------------
CREATE TABLE public.assignment_occurrences (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id       uuid NOT NULL REFERENCES public.workout_assignments (id) ON DELETE CASCADE,
  athlete_id          uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  workout_version_id  uuid NOT NULL REFERENCES public.workout_versions (id) ON DELETE RESTRICT,
  scheduled_date      date NOT NULL,
  scheduled_at        timestamptz NOT NULL, -- local calendar start instant (temporal former-coach scope)
  due_datetime        timestamptz NOT NULL, -- local midnight entering the next calendar day
  status              text NOT NULL DEFAULT 'upcoming' CHECK (
    status IN ('upcoming', 'in_progress', 'completed', 'partially_completed', 'abandoned', 'missed')
  ),
  completed_at        timestamptz NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_athlete_assignment_scheduled UNIQUE (assignment_id, athlete_id, scheduled_date),
  CONSTRAINT occurrence_status_completed_consistency CHECK (
    (status IN ('completed', 'partially_completed', 'abandoned') AND completed_at IS NOT NULL) OR
    (status NOT IN ('completed', 'partially_completed', 'abandoned') AND completed_at IS NULL)
  )
);

CREATE TRIGGER trg_assignment_occurrences_updated_at
BEFORE UPDATE ON public.assignment_occurrences
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

CREATE INDEX assignment_occurrences_athlete_scheduled_idx ON public.assignment_occurrences (athlete_id, scheduled_date ASC);
CREATE INDEX assignment_occurrences_athlete_status_idx ON public.assignment_occurrences (athlete_id, status);
CREATE INDEX assignment_occurrences_due_status_idx ON public.assignment_occurrences (status, due_datetime) WHERE status = 'upcoming';
CREATE INDEX assignment_occurrences_assignment_idx ON public.assignment_occurrences (assignment_id);
-- Covers the workout_version_id foreign key (Rule C migration updates it; the
-- FK check on a version delete would otherwise seq-scan).
CREATE INDEX assignment_occurrences_version_idx ON public.assignment_occurrences (workout_version_id);

-- 5. Foreign key & unique link on workout_sessions (ON DELETE RESTRICT — F-S5-P08) --
ALTER TABLE public.workout_sessions
  ADD CONSTRAINT fk_workout_sessions_assignment_occurrence
  FOREIGN KEY (assignment_occurrence_id) REFERENCES public.assignment_occurrences (id)
  ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_workout_sessions_assignment_occurrence
ON public.workout_sessions (assignment_occurrence_id)
WHERE assignment_occurrence_id IS NOT NULL;

-- 6. State machine, lineage immutability & structural late-sync reconciliation -------
--    (F-S5-P02, F-S5-P12, F-S5-P15)
CREATE FUNCTION app_private.enforce_occurrence_lifecycle()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_assignment_status text;
  v_org_tz text;
  v_org_today date;
  v_valid_session_exists boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'upcoming' THEN
      RAISE EXCEPTION 'Cannot delete historical occurrence with status %', OLD.status USING ERRCODE = '22000';
    END IF;

    -- Only a cancelled assignment may lose occurrences.
    SELECT a.status, o.timezone INTO v_assignment_status, v_org_tz
    FROM public.workout_assignments a
    JOIN public.organizations o ON o.id = a.organization_id
    WHERE a.id = OLD.assignment_id;

    IF v_assignment_status IS DISTINCT FROM 'cancelled' THEN
      RAISE EXCEPTION 'Cannot delete occurrence of non-cancelled assignment' USING ERRCODE = '22000';
    END IF;

    -- Past occurrences are preserved for overdue -> missed processing (F-S5-P12).
    v_org_today := (now() AT TIME ZONE COALESCE(v_org_tz, 'Asia/Manila'))::date;
    IF OLD.scheduled_date < v_org_today THEN
      RAISE EXCEPTION 'Cannot delete past overdue occurrence; must be transitioned to missed' USING ERRCODE = '22000';
    END IF;

    RETURN OLD;
  END IF;

  -- TG_OP = 'UPDATE'
  -- completed / partially_completed / abandoned are final.
  IF OLD.status IN ('completed', 'partially_completed', 'abandoned') THEN
    RAISE EXCEPTION 'Historical occurrence in terminal status % is immutable', OLD.status USING ERRCODE = '22000';
  END IF;

  -- `missed` is terminal too; its one and only exit is the structural
  -- reconciliation below (missed -> in_progress), so an update that leaves it
  -- `missed` is rejected as well.
  IF OLD.status = 'missed' AND NEW.status = 'missed' THEN
    RAISE EXCEPTION 'Historical occurrence in terminal status missed is immutable' USING ERRCODE = '22000';
  END IF;

  -- Lineage and temporal anchors never change.
  IF NEW.id <> OLD.id OR NEW.assignment_id <> OLD.assignment_id OR
     NEW.athlete_id <> OLD.athlete_id OR NEW.scheduled_date <> OLD.scheduled_date OR
     NEW.scheduled_at <> OLD.scheduled_at OR NEW.due_datetime <> OLD.due_datetime THEN
    RAISE EXCEPTION 'Core occurrence lineage fields are immutable' USING ERRCODE = '22000';
  END IF;

  -- Version migration is allowed only while upcoming (Rule C).
  IF NEW.workout_version_id <> OLD.workout_version_id AND OLD.status <> 'upcoming' THEN
    RAISE EXCEPTION 'Cannot migrate workout version of occurrence with status %', OLD.status USING ERRCODE = '22000';
  END IF;

  -- State machine.
  IF NEW.status <> OLD.status THEN
    IF OLD.status = 'upcoming' AND NEW.status NOT IN ('in_progress', 'missed') THEN
      RAISE EXCEPTION 'Invalid transition from upcoming to %', NEW.status USING ERRCODE = '22000';
    ELSIF OLD.status = 'in_progress' AND NEW.status NOT IN ('completed', 'partially_completed', 'abandoned') THEN
      RAISE EXCEPTION 'Invalid transition from in_progress to %', NEW.status USING ERRCODE = '22000';
    ELSIF OLD.status = 'missed' THEN
      -- Structural late-sync reconciliation (F-S5-P15): ONLY missed -> in_progress,
      -- and ONLY when a valid linked in-progress session already exists in
      -- database state. A direct missed -> terminal is impossible.
      IF NEW.status <> 'in_progress' THEN
        RAISE EXCEPTION 'Invalid direct transition from missed to %; direct missed to terminal is prohibited', NEW.status
          USING ERRCODE = '22000';
      END IF;

      SELECT EXISTS (
        SELECT 1 FROM public.workout_sessions s
        WHERE s.assignment_occurrence_id = NEW.id
          AND s.athlete_id = NEW.athlete_id
          AND s.workout_version_id = NEW.workout_version_id
          AND s.status = 'in_progress'
          AND s.started_at >= NEW.scheduled_at
          AND s.started_at < NEW.due_datetime
      ) INTO v_valid_session_exists;

      IF NOT v_valid_session_exists THEN
        RAISE EXCEPTION 'Reconciliation from missed to in_progress requires a valid pre-deadline in-progress workout session'
          USING ERRCODE = '22000';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.enforce_occurrence_lifecycle() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_assignment_occurrences_lifecycle
BEFORE UPDATE OR DELETE ON public.assignment_occurrences
FOR EACH ROW EXECUTE FUNCTION app_private.enforce_occurrence_lifecycle();

-- 7. Explicit table grants & DML revocations (ADR-002) ------------------------------
ALTER TABLE public.workout_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assignment_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recurring_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assignment_occurrences ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.workout_assignments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.workout_assignments TO authenticated;

REVOKE ALL ON TABLE public.assignment_targets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.assignment_targets TO authenticated;

REVOKE ALL ON TABLE public.recurring_schedules FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.recurring_schedules TO authenticated;

REVOKE ALL ON TABLE public.assignment_occurrences FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.assignment_occurrences TO authenticated;
