-- =============================================================================
-- 006_strip_invite_token_on_update.sql
-- Sprint 1 · Bug fix found by the live walking-skeleton E2E (check 24)
--
-- app_private.handle_new_user() (003) removes the raw `invite_token` from
-- auth.users.raw_user_meta_data after claiming the invitation. On the real
-- Supabase stack, the Auth service saves the user row again later in the same
-- signup flow and writes its in-memory metadata back, which restores the token.
--
-- Fix: strip the key in a BEFORE UPDATE trigger, so every later write to
-- auth.users (Auth-service saves, updateUser() calls, and 003's own cleanup
-- UPDATE) is cleaned before it is stored. The token is single-use and already
-- claimed by then; this is data hygiene, not an authorization control.
-- =============================================================================

CREATE FUNCTION app_private.strip_invite_token()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NEW.raw_user_meta_data ? 'invite_token' THEN
    NEW.raw_user_meta_data := NEW.raw_user_meta_data - 'invite_token';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.strip_invite_token() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER on_auth_user_updated_strip_invite_token
-- Deliberately not `UPDATE OF raw_user_meta_data`: column-scoped triggers only
-- fire when the column is in the SET list, which depends on the Auth service's ORM.
BEFORE UPDATE ON auth.users
FOR EACH ROW EXECUTE FUNCTION app_private.strip_invite_token();
