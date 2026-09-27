-- =============================================================================
-- workout_execution_rls
-- Roadmap v1.2 · Sprint 4 · Task 4.3 (Section 11, "RLS & Scope Helpers" +
-- "Audit Logging Redaction for Sensitive Health Data")
--
-- Two privacy tiers, mirroring the Sprint 3 two-tier read model:
--   can_view_workout_session(id)          General session/exercises/sets/ordinary
--                                          feedback/operational modifications.
--                                          Athlete, Current Coach, Former Coach
--                                          (in tenure), Leadership (training:view_org).
--   can_view_session_private_feedback(id) Sensitive discomfort feedback and
--                                          pain/injury substitution reasons.
--                                          STRICTLY Athlete, Current Coach, and
--                                          VP/President (training:view_private_feedback).
--                                          Former coaches, Leaders and System
--                                          Administrator (by system role alone)
--                                          are excluded (Rule A clarification:
--                                          an organizational position held
--                                          alongside System Administrator still
--                                          grants access via that position).
--
-- session_modifications RLS is conditional on reason_code: pain_discomfort and
-- injury_limitation route through the strict predicate; every other reason
-- routes through the general one. reason_code is NOT NULL, so the CASE always
-- resolves definitively (no three-valued-logic gap).
--
-- Audit redaction (F-S4-P13): both triggers route through the existing
-- app_private.write_audit_event() helper (Sprint 3) so every session_private_feedback
-- / session_modifications audit row is written exactly once, uniformly redacted
-- — a System Administrator with audit:view can see THAT sensitive data was
-- recorded/substituted, never its content, and cannot distinguish a medical
-- substitution from an operational one by differential redaction.
-- =============================================================================

-- 1. Helper: general session visibility -------------------------------------------
CREATE FUNCTION app_private.can_view_workout_session(p_session_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_session public.workout_sessions%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  SELECT * INTO v_session FROM public.workout_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- 1. The athlete themself.
  IF v_session.athlete_id = v_uid THEN
    RETURN true;
  END IF;

  -- 2. Current primary coach.
  IF app_private.current_coach_can_view(v_session.athlete_id) THEN
    RETURN true;
  END IF;

  -- 3. Former coach during the tenure that covered this session.
  IF app_private.former_coach_can_view(v_session.athlete_id, v_session.started_at) THEN
    RETURN true;
  END IF;

  -- 4. Organization leadership (Leader, VP, President) with training:view_org, same org.
  IF app_private.has_permission('training:view_org') AND app_private.same_organization(v_session.athlete_id) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_workout_session(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_workout_session(uuid) TO authenticated;

-- 2. Helper: sensitive discomfort feedback & medical substitutions (STRICT) --------
CREATE FUNCTION app_private.can_view_session_private_feedback(p_session_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_session public.workout_sessions%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RETURN false;
  END IF;

  SELECT * INTO v_session FROM public.workout_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- 1. The athlete themself.
  IF v_session.athlete_id = v_uid THEN
    RETURN true;
  END IF;

  -- 2. Current primary coach ONLY (former coaches are strictly excluded here).
  IF app_private.current_coach_can_view(v_session.athlete_id) THEN
    RETURN true;
  END IF;

  -- 3. Executive leadership holding training:view_private_feedback in the same
  --    organization (VP, President). Leaders, former coaches, non-assigned
  --    coaches, and System Administrator (by system role alone) are excluded.
  IF app_private.has_permission('training:view_private_feedback')
     AND app_private.same_organization(v_session.athlete_id) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.can_view_session_private_feedback(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_view_session_private_feedback(uuid) TO authenticated;

-- 3. RLS policies --------------------------------------------------------------------
ALTER TABLE public.workout_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_exercises ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_modifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_private_feedback ENABLE ROW LEVEL SECURITY;

CREATE POLICY workout_sessions_select ON public.workout_sessions
  FOR SELECT TO authenticated
  USING (app_private.can_view_workout_session(id));

CREATE POLICY session_exercises_select ON public.session_exercises
  FOR SELECT TO authenticated
  USING (app_private.can_view_workout_session(session_id));

CREATE POLICY session_sets_select ON public.session_sets
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.session_exercises se
    WHERE se.id = session_exercise_id AND app_private.can_view_workout_session(se.session_id)
  ));

-- Conditional RLS: pain_discomfort / injury_limitation route through the strict
-- predicate; every other reason_code (NOT NULL, so the CASE always resolves)
-- uses the general session predicate.
CREATE POLICY session_modifications_select ON public.session_modifications
  FOR SELECT TO authenticated
  USING (
    CASE
      WHEN reason_code IN ('pain_discomfort', 'injury_limitation')
        THEN app_private.can_view_session_private_feedback(session_id)
      ELSE app_private.can_view_workout_session(session_id)
    END
  );

CREATE POLICY session_feedback_select ON public.session_feedback
  FOR SELECT TO authenticated
  USING (app_private.can_view_workout_session(session_id));

CREATE POLICY session_private_feedback_select ON public.session_private_feedback
  FOR SELECT TO authenticated
  USING (app_private.can_view_session_private_feedback(session_id));

-- 4. Audit redaction triggers (F-S4-P13) ----------------------------------------------
-- Both route through app_private.write_audit_event() (Sprint 3) for the single-audit-path
-- guarantee: exactly one row per event, with actor resolution handled uniformly.
CREATE FUNCTION app_private.audit_session_private_feedback()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app_private.write_audit_event(
    'created', 'session_private_feedback', NEW.session_id::text, NULL,
    jsonb_build_object(
      'session_id', NEW.session_id,
      'event', 'session_private_feedback_recorded',
      'has_discomfort', '[REDACTED]',
      'discomfort_area', '[REDACTED]',
      'note_to_coach', '[REDACTED]',
      'created_at', NEW.created_at
    )
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_session_private_feedback
AFTER INSERT ON public.session_private_feedback
FOR EACH ROW EXECUTE FUNCTION app_private.audit_session_private_feedback();

-- Uniformly redacts reason_code for EVERY substitution (not only sensitive
-- ones), so a System Administrator with audit:view cannot infer a medical vs.
-- operational substitution from differential redaction (F-S4-P13).
CREATE FUNCTION app_private.audit_session_modifications()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app_private.write_audit_event(
    'created', 'session_modification', NEW.id::text, NULL,
    jsonb_build_object(
      'session_id', NEW.session_id,
      'original_workout_item_id', NEW.original_workout_item_id,
      'replacement_exercise_id', NEW.replacement_exercise_id,
      'reason_code', '[REDACTED]',
      'created_at', NEW.created_at
    )
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_session_modifications
AFTER INSERT ON public.session_modifications
FOR EACH ROW EXECUTE FUNCTION app_private.audit_session_modifications();
