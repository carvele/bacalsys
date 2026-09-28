-- =============================================================================
-- skills_workflow_rpcs
-- Roadmap v1.2 · Sprint 6 · Task 6.7 (Section 13, "Public RPC Wrappers & Private
-- Internals", F-S6-P04 / P05 / P06 / P07 / P13 / P15)
--
--   public.set_athlete_skill_status(athlete, skill, progression, key)
--   public.log_skill_attempt(progression, date, hold, reps, video_url, key)
--   public.review_skill_attempt(attempt, approved, feedback, key)
--   public.verify_skill_achievement(athlete, progression, key, attempt DEFAULT NULL)
--   public.revoke_skill_achievement(achievement, reason, key)
--   public.update_skill_progression(progression, name, description, hold, reps, key)
--
-- Each is a SECURITY INVOKER wrapper over a SECURITY DEFINER internal (F-S6-P15;
-- internals revoked from PUBLIC/anon, granted to authenticated).
--
-- Idempotency (F-S6-P05 / P13): p_idempotency_key is REQUIRED with no default on
-- every mutation. acquire_idempotency() runs BEFORE any domain row lock, so a
-- concurrent duplicate blocks on the reservation and then returns the cached
-- response, never deadlocking against the row lock. The payload hash covers every
-- argument (canonical jsonb, so free text can never collide across fields); a
-- reused key with a different payload fails closed (42501).
--
-- Lock order is always  idempotency reservation → skill_attempts row →
-- skill_achievements row, so review / verify / revoke can never deadlock.
--
-- Error codes: 42501 not authorized / key reused with a different payload ·
-- 22023 invalid argument · 22000 illegal state (already reviewed / revoked,
-- blank reason, lineage mismatch) · P0002 not found.
--
-- Executor changes vs the Section 13 listing (findings F-S6-E02, F-S6-E03):
--   * verify_skill_achievement locks the linked attempt FOR UPDATE. The listing
--     read it unlocked, so a concurrent review_skill_attempt that REJECTED the
--     attempt could be silently overwritten back to `approved`.
--   * log_skill_attempt also requires an active club position (Rule A: a
--     position-less System Administrator cannot read the tables, so it must not
--     write them either), validates the date against the organization's calendar,
--     and normalizes an omitted date before hashing (a NULL date made the listing's
--     payload hash NULL).
--   * explicit 22023 for over-long text instead of a bare CHECK violation.
-- =============================================================================

-- 1. set_athlete_skill_status (Tier 1: trained) ------------------------------------
CREATE FUNCTION app_private.set_athlete_skill_status_internal(
  p_athlete_id uuid,
  p_skill_id uuid,
  p_progression_id uuid,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.athlete_skill_status%ROWTYPE;
  v_hash text;
  v_cached jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required' USING ERRCODE = '22000';
  END IF;
  IF v_uid IS NULL OR p_athlete_id IS NULL OR NOT app_private.can_set_athlete_skill_status(p_athlete_id) THEN
    RAISE EXCEPTION 'Not authorized to set skill status for athlete %', p_athlete_id USING ERRCODE = '42501';
  END IF;
  IF p_skill_id IS NULL OR p_progression_id IS NULL THEN
    RAISE EXCEPTION 'skill and progression are required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'athlete_id', p_athlete_id, 'skill_id', p_skill_id, 'progression_id', p_progression_id)::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'SET_SKILL_STATUS', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  -- The rung must belong to the skill, and the skill to the athlete's organization
  -- (the composite FK re-asserts the skill/rung pairing structurally, F-S6-P06).
  IF NOT EXISTS (
    SELECT 1
    FROM public.skill_progressions sp
    JOIN public.skills s ON s.id = sp.skill_id
    WHERE sp.id = p_progression_id
      AND s.id = p_skill_id
      AND s.organization_id = app_private.organization_of(p_athlete_id)
  ) THEN
    RAISE EXCEPTION 'Progression rung % does not belong to skill % in the athlete''s organization',
      p_progression_id, p_skill_id USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.athlete_skill_status (athlete_id, skill_id, current_progression_id, started_training_at)
  VALUES (p_athlete_id, p_skill_id, p_progression_id, now())
  ON CONFLICT (athlete_id, skill_id) DO UPDATE
    SET current_progression_id = EXCLUDED.current_progression_id,
        started_training_at = now(),
        updated_at = now()
  RETURNING * INTO v_row;

  v_cached := jsonb_build_object(
    'id', v_row.id,
    'athlete_id', v_row.athlete_id,
    'skill_id', v_row.skill_id,
    'current_progression_id', v_row.current_progression_id,
    'started_training_at', v_row.started_training_at
  );

  PERFORM app_private.complete_idempotency(v_uid, 'SET_SKILL_STATUS', p_idempotency_key, v_cached);
  RETURN v_cached;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.set_athlete_skill_status_internal(uuid, uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.set_athlete_skill_status_internal(uuid, uuid, uuid, uuid) TO authenticated;

CREATE FUNCTION public.set_athlete_skill_status(
  p_athlete_id uuid,
  p_skill_id uuid,
  p_progression_id uuid,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.set_athlete_skill_status_internal(p_athlete_id, p_skill_id, p_progression_id, p_idempotency_key);
$$;
REVOKE EXECUTE ON FUNCTION public.set_athlete_skill_status(uuid, uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_athlete_skill_status(uuid, uuid, uuid, uuid) TO authenticated;

-- 2. log_skill_attempt (Tier 2: attempted — objective metrics only, F-S6-P09) ------
CREATE FUNCTION app_private.log_skill_attempt_internal(
  p_progression_id uuid,
  p_attempt_date date,
  p_actual_hold_seconds integer,
  p_actual_reps integer,
  p_video_url text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_org uuid;
  v_org_today date;
  v_date date;
  v_video text := NULLIF(btrim(p_video_url), '');
  v_attempt public.skill_attempts%ROWTYPE;
  v_hash text;
  v_cached jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required' USING ERRCODE = '22000';
  END IF;
  IF v_uid IS NULL OR NOT app_private.is_active_member() OR NOT app_private.holds_active_position() THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_progression_id IS NULL THEN
    RAISE EXCEPTION 'progression is required' USING ERRCODE = '22023';
  END IF;
  IF p_actual_hold_seconds IS NULL AND p_actual_reps IS NULL THEN
    RAISE EXCEPTION 'Skill attempt must record either hold seconds or repetitions' USING ERRCODE = '22023';
  END IF;
  IF p_actual_hold_seconds IS NOT NULL AND (p_actual_hold_seconds < 1 OR p_actual_hold_seconds > 7200) THEN
    RAISE EXCEPTION 'actual_hold_seconds must be between 1 and 7200' USING ERRCODE = '22023';
  END IF;
  IF p_actual_reps IS NOT NULL AND (p_actual_reps < 1 OR p_actual_reps > 1000) THEN
    RAISE EXCEPTION 'actual_reps must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;
  IF v_video IS NOT NULL AND (length(v_video) > 2048 OR v_video !~ '^https?://') THEN
    RAISE EXCEPTION 'video_url must be an http(s) link of at most 2048 characters' USING ERRCODE = '22023';
  END IF;

  v_org := app_private.current_organization_id();
  v_org_today := (now() AT TIME ZONE COALESCE(
    (SELECT o.timezone FROM public.organizations o WHERE o.id = v_org), 'Asia/Manila'))::date;
  v_date := COALESCE(p_attempt_date, v_org_today);
  IF v_date > v_org_today THEN
    RAISE EXCEPTION 'attempt_date cannot be in the future' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'progression_id', p_progression_id, 'attempt_date', v_date,
    'hold_seconds', p_actual_hold_seconds, 'reps', p_actual_reps, 'video_url', v_video)::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'LOG_SKILL_ATTEMPT', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.skill_progressions sp
    JOIN public.skills s ON s.id = sp.skill_id
    WHERE sp.id = p_progression_id AND s.organization_id = v_org
  ) THEN
    RAISE EXCEPTION 'Progression rung does not exist in your organization' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.skill_attempts (
    athlete_id, progression_id, attempt_date, actual_hold_seconds, actual_reps, video_url, status
  ) VALUES (
    v_uid, p_progression_id, v_date, p_actual_hold_seconds, p_actual_reps, v_video, 'pending_review'
  ) RETURNING * INTO v_attempt;

  v_cached := jsonb_build_object(
    'id', v_attempt.id,
    'athlete_id', v_attempt.athlete_id,
    'progression_id', v_attempt.progression_id,
    'attempt_date', v_attempt.attempt_date,
    'actual_hold_seconds', v_attempt.actual_hold_seconds,
    'actual_reps', v_attempt.actual_reps,
    'status', v_attempt.status,
    'created_at', v_attempt.created_at
  );

  PERFORM app_private.complete_idempotency(v_uid, 'LOG_SKILL_ATTEMPT', p_idempotency_key, v_cached);
  RETURN v_cached;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.log_skill_attempt_internal(uuid, date, integer, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.log_skill_attempt_internal(uuid, date, integer, integer, text, uuid) TO authenticated;

CREATE FUNCTION public.log_skill_attempt(
  p_progression_id uuid,
  p_attempt_date date,
  p_actual_hold_seconds integer,
  p_actual_reps integer,
  p_video_url text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.log_skill_attempt_internal(
    p_progression_id, p_attempt_date, p_actual_hold_seconds, p_actual_reps, p_video_url, p_idempotency_key);
$$;
REVOKE EXECUTE ON FUNCTION public.log_skill_attempt(uuid, date, integer, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_skill_attempt(uuid, date, integer, integer, text, uuid) TO authenticated;

-- 3. review_skill_attempt (approve → achievement upsert, or reject) ------------------
CREATE FUNCTION app_private.review_skill_attempt_internal(
  p_attempt_id uuid,
  p_approved boolean,
  p_feedback text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_feedback text := NULLIF(btrim(p_feedback), '');
  v_attempt public.skill_attempts%ROWTYPE;
  v_achievement public.skill_achievements%ROWTYPE;
  v_hash text;
  v_cached jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required' USING ERRCODE = '22000';
  END IF;
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_attempt_id IS NULL OR p_approved IS NULL THEN
    RAISE EXCEPTION 'attempt and decision are required' USING ERRCODE = '22023';
  END IF;
  IF v_feedback IS NOT NULL AND length(v_feedback) > 1000 THEN
    RAISE EXCEPTION 'Review feedback cannot exceed 1000 characters' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'attempt_id', p_attempt_id, 'approved', p_approved, 'feedback', v_feedback)::text);
  -- Reservation BEFORE the domain row lock (F-S6-P05).
  v_cached := app_private.acquire_idempotency(v_uid, 'REVIEW_SKILL_ATTEMPT', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_attempt FROM public.skill_attempts WHERE id = p_attempt_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Skill attempt not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT app_private.can_verify_skill(v_attempt.athlete_id) THEN
    RAISE EXCEPTION 'Not authorized to review skill attempts for athlete %', v_attempt.athlete_id USING ERRCODE = '42501';
  END IF;

  IF v_attempt.status <> 'pending_review' THEN
    RAISE EXCEPTION 'Skill attempt has already been reviewed (status %)', v_attempt.status USING ERRCODE = '22000';
  END IF;

  IF p_approved THEN
    UPDATE public.skill_attempts
    SET status = 'approved', reviewed_by = v_uid, reviewed_at = now(), review_feedback = v_feedback
    WHERE id = p_attempt_id;

    INSERT INTO public.skill_achievements (athlete_id, progression_id, verified_by, verified_at, status, skill_attempt_id)
    VALUES (v_attempt.athlete_id, v_attempt.progression_id, v_uid, now(), 'active', v_attempt.id)
    ON CONFLICT (athlete_id, progression_id) DO UPDATE
      SET status = 'active', verified_by = v_uid, verified_at = now(),
          revoked_by = NULL, revoked_at = NULL, revocation_reason = NULL,
          skill_attempt_id = v_attempt.id
    RETURNING * INTO v_achievement;

    PERFORM app_private.write_audit_event(
      'verified', 'skill_achievement', v_achievement.id::text, NULL,
      jsonb_build_object(
        'athlete_id', v_attempt.athlete_id,
        'progression_id', v_attempt.progression_id,
        'skill_attempt_id', v_attempt.id,
        'verified_by', v_uid
      )
    );

    v_cached := jsonb_build_object(
      'attempt_id', v_attempt.id,
      'status', 'approved',
      'achievement_id', v_achievement.id,
      'reviewed_at', now()
    );
  ELSE
    UPDATE public.skill_attempts
    SET status = 'rejected', reviewed_by = v_uid, reviewed_at = now(), review_feedback = v_feedback
    WHERE id = p_attempt_id;

    v_cached := jsonb_build_object(
      'attempt_id', v_attempt.id,
      'status', 'rejected',
      'reviewed_at', now()
    );
  END IF;

  PERFORM app_private.complete_idempotency(v_uid, 'REVIEW_SKILL_ATTEMPT', p_idempotency_key, v_cached);
  RETURN v_cached;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.review_skill_attempt_internal(uuid, boolean, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.review_skill_attempt_internal(uuid, boolean, text, uuid) TO authenticated;

CREATE FUNCTION public.review_skill_attempt(
  p_attempt_id uuid,
  p_approved boolean,
  p_feedback text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.review_skill_attempt_internal(p_attempt_id, p_approved, p_feedback, p_idempotency_key);
$$;
REVOKE EXECUTE ON FUNCTION public.review_skill_attempt(uuid, boolean, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_skill_attempt(uuid, boolean, text, uuid) TO authenticated;

-- 4. verify_skill_achievement (F-S6-P06 lineage, F-S6-P13 mandatory key) -------------
CREATE FUNCTION app_private.verify_skill_achievement_internal(
  p_athlete_id uuid,
  p_progression_id uuid,
  p_idempotency_key uuid,
  p_skill_attempt_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_achievement public.skill_achievements%ROWTYPE;
  v_attempt public.skill_attempts%ROWTYPE;
  v_hash text;
  v_cached jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required' USING ERRCODE = '22000';
  END IF;
  IF v_uid IS NULL OR p_athlete_id IS NULL OR NOT app_private.can_verify_skill(p_athlete_id) THEN
    RAISE EXCEPTION 'Not authorized to verify skill achievements for athlete %', p_athlete_id USING ERRCODE = '42501';
  END IF;
  IF p_progression_id IS NULL THEN
    RAISE EXCEPTION 'progression is required' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'athlete_id', p_athlete_id, 'progression_id', p_progression_id, 'skill_attempt_id', p_skill_attempt_id)::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'VERIFY_SKILL', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.skill_progressions sp
    JOIN public.skills s ON s.id = sp.skill_id
    WHERE sp.id = p_progression_id
      AND s.organization_id = app_private.organization_of(p_athlete_id)
  ) THEN
    RAISE EXCEPTION 'Progression rung does not exist in the athlete''s organization' USING ERRCODE = 'P0002';
  END IF;

  -- Lineage (F-S6-P06): a supplied attempt must belong to this athlete and rung and
  -- must not have been rejected. Locked FOR UPDATE so a concurrent review of the
  -- same attempt serializes with this call instead of being overwritten.
  IF p_skill_attempt_id IS NOT NULL THEN
    SELECT * INTO v_attempt FROM public.skill_attempts WHERE id = p_skill_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Skill attempt % not found', p_skill_attempt_id USING ERRCODE = 'P0002';
    END IF;
    IF v_attempt.athlete_id <> p_athlete_id THEN
      RAISE EXCEPTION 'Skill attempt athlete mismatch' USING ERRCODE = '22000';
    END IF;
    IF v_attempt.progression_id <> p_progression_id THEN
      RAISE EXCEPTION 'Skill attempt progression mismatch' USING ERRCODE = '22000';
    END IF;
    IF v_attempt.status = 'rejected' THEN
      RAISE EXCEPTION 'Cannot verify an achievement from a rejected attempt' USING ERRCODE = '22000';
    END IF;
    IF v_attempt.status = 'pending_review' THEN
      UPDATE public.skill_attempts
      SET status = 'approved', reviewed_by = v_uid, reviewed_at = now()
      WHERE id = p_skill_attempt_id;
    END IF;
  END IF;

  INSERT INTO public.skill_achievements (athlete_id, progression_id, verified_by, verified_at, status, skill_attempt_id)
  VALUES (p_athlete_id, p_progression_id, v_uid, now(), 'active', p_skill_attempt_id)
  ON CONFLICT (athlete_id, progression_id) DO UPDATE
    SET status = 'active', verified_by = v_uid, verified_at = now(),
        revoked_by = NULL, revoked_at = NULL, revocation_reason = NULL,
        skill_attempt_id = COALESCE(EXCLUDED.skill_attempt_id, public.skill_achievements.skill_attempt_id)
  RETURNING * INTO v_achievement;

  PERFORM app_private.write_audit_event(
    'verified', 'skill_achievement', v_achievement.id::text, NULL,
    jsonb_build_object(
      'athlete_id', p_athlete_id,
      'progression_id', p_progression_id,
      'skill_attempt_id', p_skill_attempt_id,
      'verified_by', v_uid
    )
  );

  v_cached := jsonb_build_object(
    'id', v_achievement.id,
    'athlete_id', v_achievement.athlete_id,
    'progression_id', v_achievement.progression_id,
    'status', v_achievement.status,
    'verified_at', v_achievement.verified_at
  );

  PERFORM app_private.complete_idempotency(v_uid, 'VERIFY_SKILL', p_idempotency_key, v_cached);
  RETURN v_cached;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.verify_skill_achievement_internal(uuid, uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.verify_skill_achievement_internal(uuid, uuid, uuid, uuid) TO authenticated;

-- p_idempotency_key precedes the optional attempt id, so it can never be defaulted.
CREATE FUNCTION public.verify_skill_achievement(
  p_athlete_id uuid,
  p_progression_id uuid,
  p_idempotency_key uuid,
  p_skill_attempt_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.verify_skill_achievement_internal(p_athlete_id, p_progression_id, p_idempotency_key, p_skill_attempt_id);
$$;
REVOKE EXECUTE ON FUNCTION public.verify_skill_achievement(uuid, uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.verify_skill_achievement(uuid, uuid, uuid, uuid) TO authenticated;

-- 5. revoke_skill_achievement (mandatory non-blank reason) ---------------------------
CREATE FUNCTION app_private.revoke_skill_achievement_internal(
  p_achievement_id uuid,
  p_reason text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_reason text := btrim(p_reason);
  v_achievement public.skill_achievements%ROWTYPE;
  v_hash text;
  v_cached jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required' USING ERRCODE = '22000';
  END IF;
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_achievement_id IS NULL THEN
    RAISE EXCEPTION 'achievement is required' USING ERRCODE = '22023';
  END IF;
  IF v_reason IS NULL OR length(v_reason) = 0 THEN
    RAISE EXCEPTION 'Revocation reason is mandatory and cannot be blank' USING ERRCODE = '22000';
  END IF;
  IF length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'Revocation reason cannot exceed 1000 characters' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'achievement_id', p_achievement_id, 'reason', v_reason)::text);
  -- Reservation BEFORE the domain row lock (F-S6-P05).
  v_cached := app_private.acquire_idempotency(v_uid, 'REVOKE_SKILL', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_achievement FROM public.skill_achievements WHERE id = p_achievement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Skill achievement not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT app_private.can_verify_skill(v_achievement.athlete_id) THEN
    RAISE EXCEPTION 'Not authorized to revoke skill achievements for athlete %', v_achievement.athlete_id USING ERRCODE = '42501';
  END IF;

  IF v_achievement.status = 'revoked' THEN
    RAISE EXCEPTION 'Skill achievement is already revoked' USING ERRCODE = '22000';
  END IF;

  UPDATE public.skill_achievements
  SET status = 'revoked', revoked_by = v_uid, revoked_at = now(), revocation_reason = v_reason
  WHERE id = p_achievement_id;

  PERFORM app_private.write_audit_event(
    'revoked', 'skill_achievement', p_achievement_id::text,
    jsonb_build_object('status', v_achievement.status, 'verified_by', v_achievement.verified_by),
    jsonb_build_object(
      'status', 'revoked',
      'revocation_reason', v_reason,
      'revoked_by', v_uid,
      'revoked_at', now()
    )
  );

  v_cached := jsonb_build_object(
    'id', p_achievement_id,
    'status', 'revoked',
    'revoked_at', now(),
    'revocation_reason', v_reason
  );

  PERFORM app_private.complete_idempotency(v_uid, 'REVOKE_SKILL', p_idempotency_key, v_cached);
  RETURN v_cached;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.revoke_skill_achievement_internal(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.revoke_skill_achievement_internal(uuid, text, uuid) TO authenticated;

CREATE FUNCTION public.revoke_skill_achievement(
  p_achievement_id uuid,
  p_reason text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.revoke_skill_achievement_internal(p_achievement_id, p_reason, p_idempotency_key);
$$;
REVOKE EXECUTE ON FUNCTION public.revoke_skill_achievement(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_skill_achievement(uuid, text, uuid) TO authenticated;

-- 6. update_skill_progression (Feature 8.1 criteria editing, F-S6-P07) ----------------
CREATE FUNCTION app_private.update_skill_progression_internal(
  p_progression_id uuid,
  p_name text,
  p_description text,
  p_target_hold_seconds integer,
  p_target_reps integer,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_name text := btrim(p_name);
  v_description text := NULLIF(btrim(p_description), '');
  v_prog public.skill_progressions%ROWTYPE;
  v_skill_org uuid;
  v_hash text;
  v_cached jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required' USING ERRCODE = '22000';
  END IF;
  IF v_uid IS NULL OR NOT app_private.is_active_member() THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
  IF NOT app_private.has_permission('skills:manage') THEN
    RAISE EXCEPTION 'Not authorized: requires skills:manage permission' USING ERRCODE = '42501';
  END IF;
  IF p_progression_id IS NULL THEN
    RAISE EXCEPTION 'progression is required' USING ERRCODE = '22023';
  END IF;
  IF v_name IS NULL OR length(v_name) = 0 OR length(v_name) > 120 THEN
    RAISE EXCEPTION 'Progression name must be 1 to 120 characters' USING ERRCODE = '22023';
  END IF;
  IF v_description IS NOT NULL AND length(v_description) > 2000 THEN
    RAISE EXCEPTION 'Progression description cannot exceed 2000 characters' USING ERRCODE = '22023';
  END IF;
  IF p_target_hold_seconds IS NULL AND p_target_reps IS NULL THEN
    RAISE EXCEPTION 'Progression must specify either target hold seconds or target repetitions' USING ERRCODE = '22023';
  END IF;
  IF (p_target_hold_seconds IS NOT NULL AND p_target_hold_seconds < 1)
     OR (p_target_reps IS NOT NULL AND p_target_reps < 1) THEN
    RAISE EXCEPTION 'Progression targets must be positive' USING ERRCODE = '22023';
  END IF;

  v_hash := app_private.hash_payload(jsonb_build_object(
    'progression_id', p_progression_id, 'name', v_name, 'description', v_description,
    'target_hold_seconds', p_target_hold_seconds, 'target_reps', p_target_reps)::text);
  v_cached := app_private.acquire_idempotency(v_uid, 'UPDATE_PROGRESSION', p_idempotency_key, v_hash);
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_prog FROM public.skill_progressions WHERE id = p_progression_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Skill progression not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT s.organization_id INTO v_skill_org FROM public.skills s WHERE s.id = v_prog.skill_id;
  IF v_skill_org IS DISTINCT FROM app_private.current_organization_id() THEN
    RAISE EXCEPTION 'Not authorized: progression belongs to another organization' USING ERRCODE = '42501';
  END IF;

  UPDATE public.skill_progressions
  SET name = v_name,
      description = v_description,
      target_hold_seconds = p_target_hold_seconds,
      target_reps = p_target_reps
  WHERE id = p_progression_id;

  PERFORM app_private.write_audit_event(
    'updated', 'skill_progression', p_progression_id::text,
    jsonb_build_object(
      'name', v_prog.name,
      'description', v_prog.description,
      'target_hold_seconds', v_prog.target_hold_seconds,
      'target_reps', v_prog.target_reps
    ),
    jsonb_build_object(
      'name', v_name,
      'description', v_description,
      'target_hold_seconds', p_target_hold_seconds,
      'target_reps', p_target_reps,
      'updated_by', v_uid
    )
  );

  v_cached := jsonb_build_object(
    'id', p_progression_id,
    'name', v_name,
    'description', v_description,
    'target_hold_seconds', p_target_hold_seconds,
    'target_reps', p_target_reps,
    'updated_at', now()
  );

  PERFORM app_private.complete_idempotency(v_uid, 'UPDATE_PROGRESSION', p_idempotency_key, v_cached);
  RETURN v_cached;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.update_skill_progression_internal(uuid, text, text, integer, integer, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.update_skill_progression_internal(uuid, text, text, integer, integer, uuid) TO authenticated;

CREATE FUNCTION public.update_skill_progression(
  p_progression_id uuid,
  p_name text,
  p_description text,
  p_target_hold_seconds integer,
  p_target_reps integer,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT app_private.update_skill_progression_internal(
    p_progression_id, p_name, p_description, p_target_hold_seconds, p_target_reps, p_idempotency_key);
$$;
REVOKE EXECUTE ON FUNCTION public.update_skill_progression(uuid, text, text, integer, integer, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_skill_progression(uuid, text, text, integer, integer, uuid) TO authenticated;
