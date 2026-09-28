-- =============================================================================
-- seed.sql — Roadmap v1.2 · Sprint 1 · Task 1.9
--
-- Reference data (organization, positions, permissions, system roles) plus a
-- LOCAL-DEVELOPMENT-ONLY President account. `supabase db reset` applies this
-- after the migrations. It is never run against hosted projects by
-- `supabase db push`; production bootstrapping of the first President is a
-- separate, audited operational step.
--
-- Local President login:  president@bacalsys.local / BaCalSys-Local-President-1
-- =============================================================================

-- Audit rows written while seeding are attributed to the 'migration' actor.
SELECT set_config('bacalsys.actor_type', 'migration', false);

-- -----------------------------------------------------------------------------
-- Organization & default branch
-- -----------------------------------------------------------------------------
INSERT INTO public.organizations (id, name, slug, timezone)
VALUES ('00000000-0000-4000-8000-000000000001', 'Bataan Calisthenics', 'bataan-calisthenics', 'Asia/Manila');

INSERT INTO public.branches (id, organization_id, name, is_default)
VALUES ('00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001', 'Main Branch', true);

-- Sprint 6: the six default calisthenics skill ladders (28 rungs) for the default
-- organization. Hosted projects get them from migration 20260929000003 (the
-- organization already exists there); a fresh database only has its organization
-- from this point, so the same idempotent function runs here.
SELECT app_private.seed_default_skill_ladders('00000000-0000-4000-8000-000000000001');

-- -----------------------------------------------------------------------------
-- Organizational positions (Rule A)
-- -----------------------------------------------------------------------------
INSERT INTO public.positions (id, name, rank, description) VALUES
  ('00000000-0000-4000-8000-000000000201', 'Athlete',        10, 'Club member who trains.'),
  ('00000000-0000-4000-8000-000000000202', 'Leader',         20, 'Community leader with organization-wide training visibility.'),
  ('00000000-0000-4000-8000-000000000203', 'Coach',          30, 'Programs workouts and coaches assigned athletes.'),
  ('00000000-0000-4000-8000-000000000204', 'Vice President', 40, 'Executive officer.'),
  ('00000000-0000-4000-8000-000000000205', 'President',      50, 'Executive officer and head of the club.');

-- -----------------------------------------------------------------------------
-- Permissions catalog
-- Sprint 2 permissions (exercises:approve, coaches:assign, workout:assign,
-- members:assign_president, permissions:manage) are reference data created by
-- migration 20260926051843_sprint2_permission_matrix, the Sprint 3 D5
-- permissions (workouts:publish_org, workouts:manage_org) by
-- 20260926120420_workout_permissions, and the Sprint 4 permission
-- (training:view_private_feedback) by
-- 20260927130227_training_view_private_feedback_permission, and the Sprint 6
-- permissions (skills:verify, skills:manage) by 20260929000001_skills_permissions,
-- so they also reach hosted projects; only their position mappings are repeated below.
-- -----------------------------------------------------------------------------
INSERT INTO public.permissions (name, description) VALUES
  ('members:view_all',            'View member profiles and positions across the organization.'),
  ('members:approve',             'Review and approve pending member registrations.'),
  ('members:invite',              'Create single-use member invitations.'),
  ('members:preassign_position',  'Pre-assign a position other than Athlete on an invitation.'),
  ('positions:assign',            'Assign and end organizational positions.'),
  ('training:view_org',           'View training records across the organization.'),
  ('audit:view',                  'Read the audit log.'),
  ('system_roles:view',           'View system role assignments.'),
  ('system_roles:assign',         'Assign and end system roles.'),
  ('system:configure',            'Manage system configuration.');

-- Position → permission matrix. Athlete has no special permissions: access to
-- their own records comes from ownership predicates, not permissions.
INSERT INTO public.position_permissions (position_id, permission_id)
SELECT pos.id, perm.id
FROM (VALUES
  ('Leader',         'members:view_all'),
  ('Leader',         'training:view_org'),
  ('Leader',         'workout:assign'),

  ('Coach',          'members:view_all'),
  ('Coach',          'skills:verify'),
  ('Coach',          'skills:manage'),
  ('Coach',          'workout:assign'),
  ('Coach',          'exercises:approve'),
  ('Coach',          'workouts:publish_org'),

  ('Vice President', 'members:view_all'),
  ('Vice President', 'members:approve'),
  ('Vice President', 'members:invite'),
  ('Vice President', 'members:preassign_position'),
  ('Vice President', 'positions:assign'),
  ('Vice President', 'training:view_org'),
  ('Vice President', 'exercises:approve'),
  ('Vice President', 'coaches:assign'),
  ('Vice President', 'workout:assign'),
  ('Vice President', 'skills:verify'),
  ('Vice President', 'skills:manage'),
  ('Vice President', 'audit:view'),
  ('Vice President', 'workouts:publish_org'),
  ('Vice President', 'workouts:manage_org'),
  ('Vice President', 'training:view_private_feedback'),

  ('President',      'members:view_all'),
  ('President',      'members:approve'),
  ('President',      'members:invite'),
  ('President',      'members:preassign_position'),
  ('President',      'positions:assign'),
  ('President',      'training:view_org'),
  ('President',      'exercises:approve'),
  ('President',      'coaches:assign'),
  ('President',      'workout:assign'),
  ('President',      'members:assign_president'),
  ('President',      'permissions:manage'),
  ('President',      'skills:verify'),
  ('President',      'skills:manage'),
  ('President',      'audit:view'),
  ('President',      'workouts:publish_org'),
  ('President',      'workouts:manage_org'),
  ('President',      'training:view_private_feedback')
) AS m(position_name, permission_name)
JOIN public.positions pos ON pos.name = m.position_name
JOIN public.permissions perm ON perm.name = m.permission_name
ON CONFLICT (position_id, permission_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- System roles (decoupled from club hierarchy)
-- -----------------------------------------------------------------------------
INSERT INTO public.system_roles (id, name, description)
VALUES ('00000000-0000-4000-8000-000000000301', 'System Administrator', 'Technical administrator of the BaCalSys platform.');

INSERT INTO public.system_role_permissions (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000000301', perm.id
FROM public.permissions perm
WHERE perm.name IN ('system_roles:view', 'system_roles:assign', 'system:configure', 'audit:view');

-- -----------------------------------------------------------------------------
-- Local President account (development only)
-- Inserting into auth.users fires app_private.handle_new_user(), which creates
-- the pending profile; the seed then activates it and assigns President.
-- -----------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-4000-8000-00000000a001',
  'authenticated',
  'authenticated',
  'president@bacalsys.local',
  extensions.crypt('BaCalSys-Local-President-1', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Seed President"}',
  now(),
  now(),
  '', '', '', ''
);

INSERT INTO auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  '00000000-0000-4000-8000-00000000a001',
  '00000000-0000-4000-8000-00000000a001',
  jsonb_build_object('sub', '00000000-0000-4000-8000-00000000a001', 'email', 'president@bacalsys.local', 'email_verified', true),
  'email',
  now(), now(), now()
);

UPDATE public.profiles
SET status = 'active'
WHERE id = '00000000-0000-4000-8000-00000000a001';

INSERT INTO public.member_positions (profile_id, position_id, assigned_by)
VALUES ('00000000-0000-4000-8000-00000000a001', '00000000-0000-4000-8000-000000000205', NULL);

SELECT set_config('bacalsys.actor_type', '', false);
