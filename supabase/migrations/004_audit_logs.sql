-- =============================================================================
-- 004_audit_logs.sql
-- Roadmap v1.2 · Sprint 1 · Task 1.7 (Feature 11.1)
--
-- Append-only audit log. Audit records are immutable through all BaCalSys
-- application/runtime roles:
--   * INSERT / UPDATE / DELETE / TRUNCATE are revoked from PUBLIC, anon,
--     authenticated and service_role.
--   * A BEFORE UPDATE OR DELETE row trigger (and a BEFORE TRUNCATE statement
--     trigger) raises a hard exception for every role, including the owner.
--   * Rows are written only by app_private.log_audit_event(), a SECURITY
--     DEFINER trigger function attached to sensitive tables.
-- =============================================================================

CREATE TYPE public.audit_actor_type AS ENUM ('user', 'system', 'cron', 'migration');

CREATE TABLE public.audit_logs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- No FK: audit history must outlive the actor's account.
  actor_user_id  uuid,
  actor_type     public.audit_actor_type NOT NULL,
  action         text NOT NULL CHECK (length(action) BETWEEN 1 AND 120),
  entity_type    text NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 120),
  -- text, because some audited entities have composite keys.
  entity_id      text,
  old_values     jsonb,
  new_values     jsonb,
  created_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT audit_logs_user_actor_has_id CHECK (actor_type <> 'user' OR actor_user_id IS NOT NULL)
);

CREATE INDEX audit_logs_entity_idx ON public.audit_logs (entity_type, entity_id, created_at DESC);
CREATE INDEX audit_logs_actor_idx ON public.audit_logs (actor_user_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- Grants: no runtime role may mutate audit rows.
-- -----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.audit_logs FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.audit_logs TO authenticated, service_role;  -- filtered by RLS (005)

-- -----------------------------------------------------------------------------
-- Immutability trigger (verbatim from Roadmap v1.2 Feature 11.1)
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.prevent_audit_log_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Audit logs are immutable. Updates and deletions are strictly prohibited.';
END;
$$;

CREATE TRIGGER audit_logs_immutable
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION app_private.prevent_audit_log_mutation();

-- Hardening: TRUNCATE bypasses row triggers, so block it at statement level too.
CREATE TRIGGER audit_logs_no_truncate
BEFORE TRUNCATE ON public.audit_logs
FOR EACH STATEMENT EXECUTE FUNCTION app_private.prevent_audit_log_mutation();

-- -----------------------------------------------------------------------------
-- Generic audit trigger
-- Actor resolution:
--   * a JWT subject is present            → actor_type 'user'
--   * otherwise, session setting
--     bacalsys.actor_type in (system, cron, migration) → that type
--   * otherwise                            → 'system'
-- Columns named in TG_ARGV are redacted from the stored diff.
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.log_audit_event()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_setting    text := current_setting('bacalsys.actor_type', true);
  v_actor_type public.audit_actor_type;
  v_old        jsonb;
  v_new        jsonb;
  v_redact     text[] := COALESCE(TG_ARGV::text[], '{}');
  v_entity_id  text;
BEGIN
  IF v_uid IS NOT NULL THEN
    v_actor_type := 'user';
  ELSIF v_setting IN ('system', 'cron', 'migration') THEN
    v_actor_type := v_setting::public.audit_actor_type;
  ELSE
    v_actor_type := 'system';
  END IF;

  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    v_old := to_jsonb(OLD) - v_redact;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    v_new := to_jsonb(NEW) - v_redact;
  END IF;

  -- Skip no-op updates so the log only records real changes.
  IF TG_OP = 'UPDATE' AND v_old = v_new THEN
    RETURN NULL;
  END IF;

  v_entity_id := COALESCE(v_new, v_old) ->> 'id';

  INSERT INTO public.audit_logs (actor_user_id, actor_type, action, entity_type, entity_id, old_values, new_values)
  VALUES (
    v_uid,
    v_actor_type,
    TG_TABLE_NAME || '.' || lower(TG_OP),
    TG_TABLE_NAME,
    v_entity_id,
    v_old,
    v_new
  );

  RETURN NULL;  -- AFTER trigger
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.log_audit_event() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Sensitive identity / governance tables audited from Sprint 1.
-- (Later sprints attach this same function to training and skill tables.)
-- -----------------------------------------------------------------------------
CREATE TRIGGER audit_profiles
AFTER INSERT OR UPDATE OR DELETE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();

CREATE TRIGGER audit_member_positions
AFTER INSERT OR UPDATE OR DELETE ON public.member_positions
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();

CREATE TRIGGER audit_user_system_roles
AFTER INSERT OR UPDATE OR DELETE ON public.user_system_roles
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();

CREATE TRIGGER audit_position_permissions
AFTER INSERT OR UPDATE OR DELETE ON public.position_permissions
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();

CREATE TRIGGER audit_system_role_permissions
AFTER INSERT OR UPDATE OR DELETE ON public.system_role_permissions
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event();

-- token_hash is redacted: even a digest of a live invitation token stays out of the log.
CREATE TRIGGER audit_invitations
AFTER INSERT OR UPDATE OR DELETE ON public.invitations
FOR EACH ROW EXECUTE FUNCTION app_private.log_audit_event('token_hash');
