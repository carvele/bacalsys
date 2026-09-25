-- =============================================================================
-- 002_identity_rbac_schema.sql
-- Roadmap v1.2 · Sprint 1 · Task 1.5
--
-- Identity, organization and RBAC tables.
--   Rule A: organizational positions (positions/member_positions) are decoupled
--           from technical system roles (system_roles/user_system_roles).
--           Both carry temporal validity; "active" means ended_at IS NULL.
--   Rule F: branch affiliation lives on profiles.home_branch_id only.
--
-- Grants and RLS policies are applied in 005_rls_policies.sql. Until then no
-- API role can read or write these tables (see 001 default privileges).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Shared trigger helpers
-- -----------------------------------------------------------------------------
CREATE FUNCTION app_private.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE FUNCTION app_private.validate_timezone()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = NEW.timezone) THEN
    RAISE EXCEPTION 'Unknown IANA timezone: %', NEW.timezone USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- Organizations & branches
-- -----------------------------------------------------------------------------
CREATE TABLE public.organizations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  slug        text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  -- Governs recurrence and overdue→missed scheduling (pg_cron, Sprint 5).
  timezone    text NOT NULL DEFAULT 'Asia/Manila',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER organizations_validate_timezone
BEFORE INSERT OR UPDATE OF timezone ON public.organizations
FOR EACH ROW EXECUTE FUNCTION app_private.validate_timezone();

CREATE TABLE public.branches (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  name             text NOT NULL CHECK (length(btrim(name)) > 0),
  -- New self-registrations are placed in the organization's default branch.
  is_default       boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE UNIQUE INDEX branches_one_default_per_org
  ON public.branches (organization_id) WHERE is_default;

-- -----------------------------------------------------------------------------
-- Profiles (1:1 with auth.users)
-- -----------------------------------------------------------------------------
CREATE TYPE public.member_status AS ENUM (
  'pending_approval',
  'active',
  'suspended',
  'rejected'
);

CREATE TABLE public.profiles (
  id              uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  full_name       text NOT NULL DEFAULT '' CHECK (length(full_name) <= 120),
  avatar_url      text CHECK (avatar_url IS NULL OR length(avatar_url) <= 2048),
  status          public.member_status NOT NULL DEFAULT 'pending_approval',
  home_branch_id  uuid REFERENCES public.branches (id) ON DELETE RESTRICT,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX profiles_home_branch_id_idx ON public.profiles (home_branch_id);
CREATE INDEX profiles_pending_idx ON public.profiles (created_at) WHERE status = 'pending_approval';

CREATE TRIGGER profiles_set_updated_at
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Permissions catalog (shared by positions and system roles)
-- -----------------------------------------------------------------------------
CREATE TABLE public.permissions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Namespaced "<domain>:<action>", e.g. members:approve.
  name         text NOT NULL UNIQUE CHECK (name ~ '^[a-z_]+:[a-z_]+$'),
  description  text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Organizational positions (club standing) — Rule A
-- -----------------------------------------------------------------------------
CREATE TABLE public.positions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL UNIQUE CHECK (length(btrim(name)) > 0),
  -- Higher rank = more senior. Used for display ordering only; authorization
  -- is always evaluated through permissions, never through rank comparisons.
  rank         smallint NOT NULL UNIQUE CHECK (rank > 0),
  description  text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.position_permissions (
  position_id    uuid NOT NULL REFERENCES public.positions (id) ON DELETE CASCADE,
  permission_id  uuid NOT NULL REFERENCES public.permissions (id) ON DELETE CASCADE,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (position_id, permission_id)
);

CREATE INDEX position_permissions_permission_id_idx ON public.position_permissions (permission_id);

CREATE TABLE public.member_positions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id   uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  position_id  uuid NOT NULL REFERENCES public.positions (id) ON DELETE RESTRICT,
  assigned_at  timestamptz NOT NULL DEFAULT now(),
  assigned_by  uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  ended_at     timestamptz,
  ended_by     uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  end_reason   text CHECK (end_reason IS NULL OR length(end_reason) <= 500),
  CONSTRAINT member_positions_end_after_start CHECK (ended_at IS NULL OR ended_at >= assigned_at),
  CONSTRAINT member_positions_end_fields_consistent CHECK (
    ended_at IS NOT NULL OR (ended_by IS NULL AND end_reason IS NULL)
  )
);

-- A member cannot hold the same position twice concurrently.
CREATE UNIQUE INDEX member_positions_one_active_per_position
  ON public.member_positions (profile_id, position_id) WHERE ended_at IS NULL;
CREATE INDEX member_positions_active_profile_idx
  ON public.member_positions (profile_id) WHERE ended_at IS NULL;

-- -----------------------------------------------------------------------------
-- System roles (technical authority, decoupled from club hierarchy) — Rule A
-- -----------------------------------------------------------------------------
CREATE TABLE public.system_roles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL UNIQUE CHECK (length(btrim(name)) > 0),
  description  text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.system_role_permissions (
  role_id        uuid NOT NULL REFERENCES public.system_roles (id) ON DELETE CASCADE,
  permission_id  uuid NOT NULL REFERENCES public.permissions (id) ON DELETE CASCADE,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_id)
);

CREATE INDEX system_role_permissions_permission_id_idx ON public.system_role_permissions (permission_id);

CREATE TABLE public.user_system_roles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role_id      uuid NOT NULL REFERENCES public.system_roles (id) ON DELETE RESTRICT,
  assigned_at  timestamptz NOT NULL DEFAULT now(),
  assigned_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  ended_at     timestamptz,
  ended_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  end_reason   text CHECK (end_reason IS NULL OR length(end_reason) <= 500),
  CONSTRAINT user_system_roles_end_after_start CHECK (ended_at IS NULL OR ended_at >= assigned_at),
  CONSTRAINT user_system_roles_end_fields_consistent CHECK (
    ended_at IS NOT NULL OR (ended_by IS NULL AND end_reason IS NULL)
  )
);

CREATE UNIQUE INDEX user_system_roles_one_active_per_role
  ON public.user_system_roles (user_id, role_id) WHERE ended_at IS NULL;
CREATE INDEX user_system_roles_active_user_idx
  ON public.user_system_roles (user_id) WHERE ended_at IS NULL;

-- -----------------------------------------------------------------------------
-- Invitations — SHA-256 hashed, single-use, expiring
-- The raw token is returned exactly once by public.create_invitation() and is
-- never stored. Only its lowercase hex SHA-256 digest is persisted.
-- -----------------------------------------------------------------------------
CREATE TABLE public.invitations (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash               text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  email                    text NOT NULL CHECK (email = lower(btrim(email)) AND email LIKE '%_@_%'),
  preassigned_position_id  uuid REFERENCES public.positions (id) ON DELETE RESTRICT,
  created_by               uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  created_at               timestamptz NOT NULL DEFAULT now(),
  expires_at               timestamptz NOT NULL,
  claimed_at               timestamptz,
  claimed_by               uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  CONSTRAINT invitations_expiry_after_creation CHECK (expires_at > created_at),
  -- claimed_by may later become NULL (claimer deleted) but a claim is never un-claimed.
  CONSTRAINT invitations_claim_fields_consistent CHECK (claimed_by IS NULL OR claimed_at IS NOT NULL)
);

CREATE INDEX invitations_open_email_idx ON public.invitations (email) WHERE claimed_at IS NULL;
CREATE INDEX invitations_created_by_idx ON public.invitations (created_by);
