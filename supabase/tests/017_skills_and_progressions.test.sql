-- Sprint 6 · Task 6.9 — calisthenics skill trees: permissions, structure, RLS, the
-- Tier-1/2/3 workflows, idempotency, lineage, audit and privilege delegation.
--
--   * Permission matrix: skills:verify / skills:manage are Coach + VP + President only.
--   * Structure: composite FK (F-S6-P06), consistency CHECKs, no free-text notes
--     column (F-S6-P09), RLS on, clients hold SELECT only, 28 seeded rungs.
--   * 11-identity RLS matrix (F-S6-P03 / F-S6-P14): athlete self, peer, cross-org
--     athlete, current coach, former coach, unassigned coach, leader, VP, President,
--     inactive member, and a System Administrator with NO club position.
--   * Tier-1 status authority (F-S6-P04), attempt review, verification lineage,
--     revocation (mandatory reason), criteria editing with audit (F-S6-P07).
--   * Idempotency (F-S6-P05 / P13): replay, payload-hash conflict (42501), mandatory
--     key, reservation acquired BEFORE any domain row lock.
--   * F-S6-P15: every public mutation is SECURITY INVOKER, executes for
--     `authenticated`, is refused (42501) for `anon`.
-- Real concurrency (two overlapping transactions) is proven on the hosted project by
-- scripts/e2e/sprint6-probes.mjs; here the serialization statements are asserted
-- structurally, the same convention as Sprints 3-5.
-- Every fixture lives in this transaction and is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(75);

-- Helpers (rolled back with the test) ------------------------------------------------
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE FUNCTION pg_temp.remember(p_k text, p_v uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  INSERT INTO pg_temp.ids VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = excluded.v;
  RETURN p_v;
END;
$fn$;
CREATE FUNCTION pg_temp.recall(p_k text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $fn$
  SELECT v FROM pg_temp.ids WHERE k = p_k;
$fn$;
CREATE FUNCTION pg_temp.u(p_n integer) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT 'd7000000-0000-4000-8000-0000000000' || lpad(p_n::text, 2, '0');
$fn$;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;
CREATE FUNCTION pg_temp.as_jsonb(p_uid text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(p_uid);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO r;
  EXECUTE 'RESET ROLE';
  RETURN r;
END;
$fn$;
CREATE FUNCTION pg_temp.as_bigint(p_uid text, p_sql text) RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE r bigint;
BEGIN
  PERFORM pg_temp.act(p_uid);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO r;
  EXECUTE 'RESET ROLE';
  RETURN r;
END;
$fn$;
-- SQLSTATE of p_sql run as `authenticated` (p_uid) or `anon` (p_uid IS NULL).
CREATE FUNCTION pg_temp.as_sqlstate(p_uid text, p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE 'SET LOCAL ROLE anon';
  ELSE
    PERFORM pg_temp.act(p_uid);
    EXECUTE 'SET LOCAL ROLE authenticated';
  END IF;
  EXECUTE p_sql;
  EXECUTE 'RESET ROLE';
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END;
$fn$;
-- Plain (superuser) SQLSTATE, for structural constraint checks.
CREATE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END;
$fn$;
-- Row counts of p_sql for identities 1..11, in order.
CREATE FUNCTION pg_temp.matrix(p_sql text) RETURNS bigint[] LANGUAGE plpgsql AS $fn$
DECLARE r bigint[] := '{}'; n integer;
BEGIN
  FOR n IN 1..11 LOOP r := r || pg_temp.as_bigint(pg_temp.u(n), p_sql); END LOOP;
  RETURN r;
END;
$fn$;
CREATE FUNCTION pg_temp.skill(p_slug text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT id FROM public.skills WHERE organization_id = '00000000-0000-4000-8000-000000000001' AND slug = p_slug;
$fn$;
CREATE FUNCTION pg_temp.rung(p_slug text, p_rank integer) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT sp.id FROM public.skill_progressions sp JOIN public.skills s ON s.id = sp.skill_id
  WHERE s.organization_id = '00000000-0000-4000-8000-000000000001' AND s.slug = p_slug AND sp.rank_order = p_rank;
$fn$;
CREATE FUNCTION pg_temp.audits(p_entity text, p_id uuid, p_action text) RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT count(*) FROM public.audit_logs WHERE entity_type = p_entity AND entity_id = p_id::text AND action = p_action;
$fn$;
GRANT EXECUTE ON FUNCTION pg_temp.remember(text, uuid), pg_temp.recall(text), pg_temp.u(integer), pg_temp.act(text),
  pg_temp.skill(text), pg_temp.rung(text, integer), pg_temp.audits(text, uuid, text) TO authenticated;

-- Fixtures -------------------------------------------------------------------------------
--   01 Juan (athlete)            02 Coach A (Juan's current coach)     03 Peer athlete
--   04 Cross-org athlete (LA)    05 Former coach of Juan               06 Unassigned coach
--   07 Leader                    08 Vice President                     09 President
--   10 Inactive (suspended)      11 System Administrator with NO club position
INSERT INTO auth.users (id, email, raw_user_meta_data) SELECT pg_temp.u(n)::uuid, 'u' || n || '@s6k.test', '{"full_name":"S6 Skills"}'::jsonb
  FROM generate_series(1, 11) n;
UPDATE public.profiles SET status = 'active' WHERE id::text LIKE 'd7000000-0000-4000-8000-0000000000%';
INSERT INTO public.member_positions (profile_id, position_id)
SELECT pg_temp.u(f.n)::uuid, pos.id FROM (VALUES
  (1, 'Athlete'), (2, 'Coach'), (3, 'Athlete'), (4, 'Athlete'), (5, 'Coach'), (6, 'Coach'),
  (7, 'Leader'), (8, 'Vice President'), (9, 'President'), (10, 'Athlete')
) AS f(n, position_name) JOIN public.positions pos ON pos.name = f.position_name;
UPDATE public.profiles SET status = 'suspended' WHERE id = pg_temp.u(10)::uuid;
INSERT INTO public.user_system_roles (user_id, role_id)
SELECT pg_temp.u(11)::uuid, id FROM public.system_roles WHERE name = 'System Administrator';
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at, ended_at, ended_by) VALUES
  (pg_temp.u(1)::uuid, pg_temp.u(5)::uuid, pg_temp.u(8)::uuid, now() - interval '60 days', now() - interval '30 days', pg_temp.u(8)::uuid);
INSERT INTO public.coach_assignments (athlete_id, coach_id, assigned_by, started_at) VALUES
  (pg_temp.u(1)::uuid, pg_temp.u(2)::uuid, pg_temp.u(8)::uuid, now() - interval '30 days');
-- Another organization with its own skill catalog.
INSERT INTO public.organizations (id, name, slug, timezone)
VALUES ('d7000000-0000-4000-8000-00000000f001', 'Other Club', 'other-club-s6', 'America/Los_Angeles');
INSERT INTO public.branches (id, organization_id, name, is_default)
VALUES ('d7000000-0000-4000-8000-00000000f101', 'd7000000-0000-4000-8000-00000000f001', 'Other Main', true);
UPDATE public.profiles SET home_branch_id = 'd7000000-0000-4000-8000-00000000f101' WHERE id = pg_temp.u(4)::uuid;
SELECT app_private.seed_default_skill_ladders('d7000000-0000-4000-8000-00000000f001');

-- 1. Permissions, structure, seed -------------------------------------------------------------
SELECT is(
  (SELECT array_agg(pos.name ORDER BY pos.name COLLATE "C") FROM public.position_permissions pp
     JOIN public.permissions p ON p.id = pp.permission_id JOIN public.positions pos ON pos.id = pp.position_id
    WHERE p.name = 'skills:verify'),
  ARRAY['Coach', 'President', 'Vice President'],
  'skills:verify is held by Coach, Vice President and President only (no Leader, Athlete or System Administrator)'
);
SELECT is(
  (SELECT array_agg(pos.name ORDER BY pos.name COLLATE "C") FROM public.position_permissions pp
     JOIN public.permissions p ON p.id = pp.permission_id JOIN public.positions pos ON pos.id = pp.position_id
    WHERE p.name = 'skills:manage'),
  ARRAY['Coach', 'President', 'Vice President'],
  'skills:manage is held by Coach, Vice President and President only'
);
SELECT is(
  (SELECT count(*) FROM public.system_role_permissions srp JOIN public.permissions p ON p.id = srp.permission_id
    WHERE p.name IN ('skills:verify', 'skills:manage')),
  0::bigint,
  'Rule A: no system role holds either skills permission'
);
SELECT is(
  (SELECT bool_and(relrowsecurity) FROM pg_class
    WHERE oid IN ('public.skills'::regclass, 'public.skill_progressions'::regclass, 'public.athlete_skill_status'::regclass,
                  'public.skill_attempts'::regclass, 'public.skill_achievements'::regclass)),
  true,
  'RLS is enabled on all five skill tables'
);
SELECT is(
  (SELECT array_agg(has_table_privilege(r, t, priv) ORDER BY r, t, priv)
   FROM unnest(ARRAY['anon', 'authenticated']) r,
        unnest(ARRAY['public.skills', 'public.skill_progressions', 'public.athlete_skill_status',
                     'public.skill_attempts', 'public.skill_achievements']) t,
        unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) priv),
  (SELECT array_agg(false) FROM generate_series(1, 30)),
  'ADR-002: neither anon nor authenticated holds INSERT/UPDATE/DELETE on any skill table (mutation is RPC-only)'
);
SELECT is(
  (SELECT array_agg(has_table_privilege(r, t, 'SELECT') ORDER BY r, t)
   FROM unnest(ARRAY['anon', 'authenticated']) r,
        unnest(ARRAY['public.skills', 'public.skill_progressions', 'public.athlete_skill_status',
                     'public.skill_attempts', 'public.skill_achievements']) t),
  ARRAY[false, false, false, false, false, true, true, true, true, true],
  'authenticated holds SELECT on the skill tables (filtered by RLS); anon holds none'
);
SELECT is(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name IN ('athlete_skill_status', 'skill_attempts')
      AND column_name ~* '(note|comment|remark|reason)'),
  0::bigint,
  'F-S6-P09: neither athlete_skill_status nor skill_attempts has a free-text notes/comment column'
);
SELECT is(
  (SELECT ARRAY[(SELECT count(*) FROM public.skills WHERE organization_id = '00000000-0000-4000-8000-000000000001'),
                (SELECT count(*) FROM public.skill_progressions sp JOIN public.skills s ON s.id = sp.skill_id
                  WHERE s.organization_id = '00000000-0000-4000-8000-000000000001')]),
  ARRAY[6, 28]::bigint[],
  'the default organization has the six seeded ladders and 28 rungs'
);
SELECT is(
  (SELECT array_agg(s.slug || ':' || c ORDER BY s.slug) FROM public.skills s
     JOIN LATERAL (SELECT count(*) c FROM public.skill_progressions sp WHERE sp.skill_id = s.id) x ON true
    WHERE s.organization_id = '00000000-0000-4000-8000-000000000001'),
  ARRAY['front-lever:5', 'handstand:5', 'l-sit:5', 'muscle-up:5', 'pistol-squat:4', 'planche:4'],
  'F-S6-P07: the frozen ladder shapes (planche 4, front lever 5, muscle-up 5, handstand 5, pistol 4, l-sit 5)'
);
SELECT is(
  (SELECT ARRAY[sp.name, sp.target_hold_seconds::text, sp.description]
   FROM public.skill_progressions sp WHERE sp.id = pg_temp.rung('planche', 2)),
  ARRAY['Advanced Tuck Planche', '12', 'Hips extended to 90 degrees between torso and thighs, flat back, straight arms.'],
  'F-S6-P07: frozen criteria (Advanced Tuck Planche: 12 s hold)'
);
SELECT is(
  pg_temp.sqlstate_of(format(
    $sql$ INSERT INTO public.athlete_skill_status (athlete_id, skill_id, current_progression_id) VALUES (%L, %L, %L) $sql$,
    pg_temp.u(1), pg_temp.skill('planche'), pg_temp.rung('front-lever', 1))),
  '23503',
  'F-S6-P06: the composite FK makes it impossible to pair a skill with a rung that belongs to another skill'
);
SELECT is(
  ARRAY[
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.skill_progressions (skill_id, rank_order, name) VALUES (%L, 9, 'No target') $sql$, pg_temp.skill('planche'))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.skill_progressions (skill_id, rank_order, name, target_reps) VALUES (%L, 1, 'Dup rank', 3) $sql$, pg_temp.skill('planche'))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.skill_attempts (athlete_id, progression_id) VALUES (%L, %L) $sql$, pg_temp.u(1), pg_temp.rung('planche', 1))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.skill_attempts (athlete_id, progression_id, actual_reps, status) VALUES (%L, %L, 3, 'approved') $sql$, pg_temp.u(1), pg_temp.rung('planche', 1))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.skill_attempts (athlete_id, progression_id, actual_reps, video_url) VALUES (%L, %L, 3, 'ftp://x') $sql$, pg_temp.u(1), pg_temp.rung('planche', 1))),
    pg_temp.sqlstate_of(format($sql$ INSERT INTO public.skill_achievements (athlete_id, progression_id, verified_by, status) VALUES (%L, %L, %L, 'revoked') $sql$, pg_temp.u(1), pg_temp.rung('planche', 1), pg_temp.u(2)))
  ],
  ARRAY['23514', '23505', '23514', '23514', '23514', '23514'],
  'CHECKs: a rung needs a target; rank is unique per skill; an attempt needs a measurement, review fields must agree with status, video must be http(s); a revoked achievement needs its actor and reason'
);
SELECT is(
  (SELECT bool_and(pg_get_constraintdef(c.oid) ~ m) FROM pg_constraint c,
     unnest(ARRAY['SET_SKILL_STATUS', 'LOG_SKILL_ATTEMPT', 'REVIEW_SKILL_ATTEMPT', 'VERIFY_SKILL', 'REVOKE_SKILL', 'UPDATE_PROGRESSION',
                  'START_SESSION', 'SYNC_BUNDLE', 'CREATE_ASSIGNMENT', 'CANCEL_ASSIGNMENT', 'MIGRATE_ASSIGNMENT_VERSION']) m
    WHERE c.conname = 'idempotency_keys_mutation_type_check'),
  true,
  'F-S6-P05: the idempotency ledger accepts the six skill mutation types and still accepts every accepted Sprint 4/5 type'
);

-- Workflow state (through the real RPCs) --------------------------------------------------------
--   Juan trains Planche rung 1 and Front Lever rung 1, then logs three attempts;
--   Coach A approves the first.
SELECT pg_temp.remember('a1', (pg_temp.as_jsonb(pg_temp.u(1), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 18, NULL, 'https://youtube.com/watch?v=sample', %L) $sql$,
  pg_temp.rung('planche', 1), gen_random_uuid())) ->> 'id')::uuid);
SELECT pg_temp.remember('a2', (pg_temp.as_jsonb(pg_temp.u(1), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 13, NULL, NULL, %L) $sql$,
  pg_temp.rung('planche', 2), gen_random_uuid())) ->> 'id')::uuid);
SELECT pg_temp.remember('a3', (pg_temp.as_jsonb(pg_temp.u(1), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 10, NULL, NULL, %L) $sql$,
  pg_temp.rung('front-lever', 1), gen_random_uuid())) ->> 'id')::uuid);
SELECT pg_temp.as_jsonb(pg_temp.u(1), format($sql$ SELECT public.set_athlete_skill_status(%L, %L, %L, %L) $sql$,
  pg_temp.u(1), pg_temp.skill('planche'), pg_temp.rung('planche', 1), gen_random_uuid()));
SELECT pg_temp.as_jsonb(pg_temp.u(1), format($sql$ SELECT public.set_athlete_skill_status(%L, %L, %L, %L) $sql$,
  pg_temp.u(1), pg_temp.skill('front-lever'), pg_temp.rung('front-lever', 1), gen_random_uuid()));
SELECT pg_temp.remember('ach1', (pg_temp.as_jsonb(pg_temp.u(2), format(
  $sql$ SELECT public.review_skill_attempt(%L, true, 'Flawless protraction and straight arms. Approved!', %L) $sql$,
  pg_temp.recall('a1'), gen_random_uuid())) ->> 'achievement_id')::uuid);

-- 2. The 11-identity RLS matrix (F-S6-P03 / F-S6-P14) ------------------------------------------
--    order: Juan, Coach A, Peer, Cross-org, Former coach, Unassigned coach, Leader, VP, President,
--           Inactive member, SysAdmin-only
SELECT is(
  pg_temp.matrix('SELECT count(*) FROM public.athlete_skill_status'),
  ARRAY[2, 2, 0, 0, 0, 0, 2, 2, 2, 0, 0]::bigint[],
  'Tier 1 (status): athlete, current coach and leadership (Leader/VP/President) see it; peer, other org, former and unassigned coach, inactive member and SysAdmin-only see 0'
);
SELECT is(
  pg_temp.matrix('SELECT count(*) FROM public.skill_attempts'),
  ARRAY[3, 3, 0, 0, 0, 0, 0, 3, 3, 0, 0]::bigint[],
  'Tier 2 (attempts): athlete, current coach, VP and President only — a LEADER sees 0 (review feedback is not a leak channel); former coach 0'
);
SELECT is(
  pg_temp.matrix('SELECT count(*) FROM public.skill_achievements'),
  ARRAY[1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 0]::bigint[],
  'Tier 3 (verified milestones) are club-visible to every same-organization position holder (incl. peer and former coach); other org, inactive and SysAdmin-only see 0'
);
SELECT is(
  pg_temp.matrix($sql$ SELECT count(*) FROM public.skills WHERE organization_id = '00000000-0000-4000-8000-000000000001' $sql$),
  ARRAY[6, 6, 6, 0, 6, 6, 6, 6, 6, 0, 0]::bigint[],
  'the skill catalog: same-organization position holders see the 6 ladders; the other organization sees none of them; inactive and SysAdmin-only see 0'
);
SELECT is(
  pg_temp.matrix($sql$ SELECT count(*) FROM public.skill_progressions sp JOIN public.skills s ON s.id = sp.skill_id
                        WHERE s.organization_id = '00000000-0000-4000-8000-000000000001' $sql$),
  ARRAY[28, 28, 28, 0, 28, 28, 28, 28, 28, 0, 0]::bigint[],
  'the 28 rungs follow the same organization scope'
);
SELECT is(
  pg_temp.as_bigint(pg_temp.u(4), 'SELECT count(*) FROM public.skill_progressions'),
  28::bigint,
  'the other organization sees exactly its OWN 28 rungs (a separate catalog), never the default organization''s'
);
SELECT is(
  (SELECT ARRAY[app_private.is_active_member()::text, app_private.holds_active_position()::text, has_role_row::text]
   FROM (SELECT pg_temp.act(pg_temp.u(11))) a,
        LATERAL (SELECT EXISTS (SELECT 1 FROM public.user_system_roles WHERE user_id = pg_temp.u(11)::uuid) AS has_role_row) r),
  ARRAY['true', 'false', 'true'],
  'F-S6-P14 setup: the SysAdmin-only account is an ACTIVE member holding a system role but NO club position'
);
SELECT is(
  pg_temp.as_bigint(pg_temp.u(11), $sql$ SELECT (SELECT count(*) FROM public.skills) + (SELECT count(*) FROM public.skill_progressions)
       + (SELECT count(*) FROM public.athlete_skill_status) + (SELECT count(*) FROM public.skill_attempts)
       + (SELECT count(*) FROM public.skill_achievements) $sql$),
  0::bigint,
  'F-S6-P14: a pure System Administrator reads 0 rows across ALL FIVE skill tables'
);

-- 3. Tier-1 status authority (F-S6-P04) -------------------------------------------------------
SELECT is(
  ARRAY(SELECT pg_temp.as_sqlstate(pg_temp.u(n), format($sql$ SELECT public.set_athlete_skill_status(%L, %L, %L, %L) $sql$,
          pg_temp.u(1), pg_temp.skill('planche'), pg_temp.rung('planche', 2), gen_random_uuid()))
        FROM generate_series(1, 11) n),
  ARRAY['ok', 'ok', '42501', '42501', '42501', '42501', '42501', 'ok', 'ok', '42501', '42501'],
  'F-S6-P04: the athlete, their current coach, VP and President may set Juan''s trained rung; a peer, other org, former coach, unassigned coach, Leader, inactive member and SysAdmin-only get 42501'
);
SELECT is(
  (SELECT ARRAY[count(*)::text, min(current_progression_id::text)] FROM public.athlete_skill_status
    WHERE athlete_id = pg_temp.u(1)::uuid AND skill_id = pg_temp.skill('planche')),
  ARRAY['1', pg_temp.rung('planche', 2)::text],
  'the repeated upserts left exactly one status row for (athlete, skill), on the last rung set'
);
SELECT is(
  pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.set_athlete_skill_status(%L, %L, %L, %L) $sql$,
    pg_temp.u(1), pg_temp.skill('planche'), pg_temp.rung('front-lever', 1), gen_random_uuid())),
  '22023',
  'the RPC rejects a rung that belongs to a different skill (22023) before the composite FK ever has to'
);
SELECT is(
  pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.set_athlete_skill_status(%L, %L, %L, NULL) $sql$,
    pg_temp.u(1), pg_temp.skill('planche'), pg_temp.rung('planche', 1))),
  '22000',
  'a NULL idempotency key is refused (22000)'
);

-- 4. log_skill_attempt: validation and idempotency --------------------------------------------
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, NULL, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 0, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, NULL, 0, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 5, NULL, 'ftp://example.com/v', %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, (now() + interval '3 days')::date, 5, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 5, NULL, NULL, NULL) $sql$, pg_temp.rung('planche', 1))),
    pg_temp.as_sqlstate(pg_temp.u(11), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 5, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(10), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 5, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(4), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 5, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid()))
  ],
  ARRAY['22023', '22023', '22023', '22023', '22023', '22000', '42501', '42501', 'P0002'],
  'log_skill_attempt: no metric / zero hold / zero reps / non-http video / future date → 22023; NULL key → 22000; SysAdmin-only and inactive → 42501; another organization''s rung → P0002'
);
SELECT pg_temp.remember('kx', gen_random_uuid());
SELECT pg_temp.remember('ax', (pg_temp.as_jsonb(pg_temp.u(1), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 7, NULL, '   ', %L) $sql$, pg_temp.rung('front-lever', 2), pg_temp.recall('kx'))) ->> 'id')::uuid);
SELECT is(
  (SELECT ARRAY[
     (pg_temp.as_jsonb(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 7, NULL, '   ', %L) $sql$,
        pg_temp.rung('front-lever', 2), pg_temp.recall('kx'))) ->> 'id'),
     (SELECT count(*)::text FROM public.skill_attempts WHERE athlete_id = pg_temp.u(1)::uuid AND progression_id = pg_temp.rung('front-lever', 2)),
     (SELECT coalesce(video_url, 'NULL') FROM public.skill_attempts WHERE id = pg_temp.recall('ax'))]),
  ARRAY[pg_temp.recall('ax')::text, '1', 'NULL'],
  'F-S6-P05: replaying log_skill_attempt with the SAME key returns the SAME attempt and creates no second row; a blank video url is stored as NULL'
);
SELECT is(
  pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ SELECT public.log_skill_attempt(%L, NULL, 99, NULL, '   ', %L) $sql$,
    pg_temp.rung('front-lever', 2), pg_temp.recall('kx'))),
  '42501',
  'F-S6-P05: the same key with a DIFFERENT payload (99 s instead of 7 s) fails closed (42501)'
);
SELECT is(
  (SELECT ARRAY[(SELECT count(*)::text FROM public.skill_attempts WHERE athlete_id = pg_temp.u(1)::uuid AND progression_id = pg_temp.rung('front-lever', 2)),
                (SELECT actual_hold_seconds::text FROM public.skill_attempts WHERE id = pg_temp.recall('ax'))]),
  ARRAY['1', '7'],
  '...and the original attempt is untouched'
);

-- 5. review_skill_attempt ---------------------------------------------------------------------
SELECT is(
  ARRAY(SELECT pg_temp.as_sqlstate(pg_temp.u(n), format($sql$ SELECT public.review_skill_attempt(%L, true, NULL, %L) $sql$,
          pg_temp.recall('a2'), gen_random_uuid()))
        FROM unnest(ARRAY[1, 3, 4, 5, 6, 7, 10, 11]) n),
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501', '42501', '42501'],
  'review: the athlete themself, a peer, other org, FORMER coach, unassigned coach, Leader, inactive and SysAdmin-only are all refused (42501) — and none of them changed the attempt'
);
SELECT is(
  (SELECT status FROM public.skill_attempts WHERE id = pg_temp.recall('a2')),
  'pending_review',
  '...so the attempt is still pending'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, true, %L, %L) $sql$, pg_temp.recall('a2'), repeat('x', 1001), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, true, NULL, NULL) $sql$, pg_temp.recall('a2'))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, NULL, NULL, %L) $sql$, pg_temp.recall('a2'), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, true, NULL, %L) $sql$, gen_random_uuid(), gen_random_uuid()))
  ],
  ARRAY['22023', '22000', '22023', 'P0002'],
  'review validation: feedback over 1000 chars → 22023; NULL key → 22000; NULL decision → 22023; unknown attempt → P0002'
);
SELECT pg_temp.remember('kr', gen_random_uuid());
SELECT is(
  (SELECT ARRAY[r ->> 'status', ((r ->> 'achievement_id') IS NOT NULL)::text]
   FROM (SELECT pg_temp.as_jsonb(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, true, 'Solid hold.', %L) $sql$,
          pg_temp.recall('a2'), pg_temp.recall('kr'))) AS r) x),
  ARRAY['approved', 'true'],
  'the current primary coach approves a pending attempt'
);
SELECT is(
  (SELECT ARRAY[a.status, a.reviewed_by::text, (a.reviewed_at IS NOT NULL)::text, a.review_feedback]
   FROM public.skill_attempts a WHERE a.id = pg_temp.recall('a2')),
  ARRAY['approved', pg_temp.u(2), 'true', 'Solid hold.'],
  'the attempt records who reviewed it, when, and the feedback'
);
SELECT is(
  (SELECT ARRAY[ac.status, ac.verified_by::text, ac.skill_attempt_id::text]
   FROM public.skill_achievements ac WHERE ac.athlete_id = pg_temp.u(1)::uuid AND ac.progression_id = pg_temp.rung('planche', 2)),
  ARRAY['active', pg_temp.u(2), pg_temp.recall('a2')::text],
  'approval upserted the verified achievement, linked to the approved attempt'
);
SELECT is(
  ARRAY[
    (pg_temp.as_jsonb(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, true, 'Solid hold.', %L) $sql$,
       pg_temp.recall('a2'), pg_temp.recall('kr'))) ->> 'status'),
    (SELECT count(*)::text FROM public.skill_achievements WHERE athlete_id = pg_temp.u(1)::uuid AND progression_id = pg_temp.rung('planche', 2)),
    pg_temp.audits('skill_achievement',
      (SELECT id FROM public.skill_achievements WHERE athlete_id = pg_temp.u(1)::uuid AND progression_id = pg_temp.rung('planche', 2)), 'verified')::text
  ],
  ARRAY['approved', '1', '1'],
  'F-S6-P05: replaying the review with the same key returns the cached result and does NOT approve or audit twice'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, false, 'Solid hold.', %L) $sql$, pg_temp.recall('a2'), pg_temp.recall('kr'))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.review_skill_attempt(%L, true, 'Solid hold.', %L) $sql$, pg_temp.recall('a2'), gen_random_uuid()))
  ],
  ARRAY['42501', '22000'],
  'F-S6-P05: the same key with a flipped decision → 42501; a NEW key on an already-reviewed attempt → 22000 (the loser of a race)'
);
SELECT is(
  (SELECT ARRAY[r ->> 'status'] FROM (SELECT pg_temp.as_jsonb(pg_temp.u(8), format(
     $sql$ SELECT public.review_skill_attempt(%L, false, 'Hold form breaks at 8 s.', %L) $sql$, pg_temp.recall('a3'), gen_random_uuid())) AS r) x),
  ARRAY['rejected'],
  'a Vice President may reject a pending attempt'
);
SELECT is(
  (SELECT ARRAY[a.status, a.review_feedback, (SELECT count(*)::text FROM public.skill_achievements
                                              WHERE athlete_id = pg_temp.u(1)::uuid AND progression_id = pg_temp.rung('front-lever', 1))]
   FROM public.skill_attempts a WHERE a.id = pg_temp.recall('a3')),
  ARRAY['rejected', 'Hold form breaks at 8 s.', '0'],
  'a rejected attempt creates no achievement'
);
SELECT is(
  (SELECT ARRAY[status, review_feedback] FROM (SELECT
     (pg_temp.as_jsonb(pg_temp.u(1), 'SELECT to_jsonb(a) FROM public.skill_attempts a WHERE a.id = ' || quote_literal(pg_temp.recall('a3')))) ->> 'status' AS status,
     (pg_temp.as_jsonb(pg_temp.u(1), 'SELECT to_jsonb(a) FROM public.skill_attempts a WHERE a.id = ' || quote_literal(pg_temp.recall('a3')))) ->> 'review_feedback' AS review_feedback) x),
  ARRAY['rejected', 'Hold form breaks at 8 s.'],
  'the athlete reads the reviewer''s feedback on their own attempt'
);

-- 6. Self-verification is impossible (finding F-S6-E02) ---------------------------------------
SELECT pg_temp.remember('vp_attempt', (pg_temp.as_jsonb(pg_temp.u(8), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 20, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())) ->> 'id')::uuid);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(8), format($sql$ SELECT public.review_skill_attempt(%L, true, NULL, %L) $sql$, pg_temp.recall('vp_attempt'), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(8), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$, pg_temp.u(8), pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(9), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$, pg_temp.u(9), pg_temp.rung('planche', 1), gen_random_uuid()))
  ],
  ARRAY['42501', '42501', '42501'],
  'F-S6-E02: an officer who is also an athlete can neither review nor verify their OWN skill (42501) — verification is a third-party attestation'
);
SELECT is(
  (SELECT status FROM public.skill_attempts WHERE id = pg_temp.recall('vp_attempt')),
  'pending_review',
  '...and the officer''s own attempt stays pending until someone else reviews it'
);
SELECT is(
  (SELECT r ->> 'status' FROM (SELECT pg_temp.as_jsonb(pg_temp.u(9), format(
     $sql$ SELECT public.review_skill_attempt(%L, true, NULL, %L) $sql$, pg_temp.recall('vp_attempt'), gen_random_uuid())) AS r) x),
  'approved',
  'the President (a different officer) can review the Vice President''s attempt (organization-wide scope)'
);

-- 7. verify_skill_achievement (F-S6-P06 lineage, F-S6-P13 mandatory key) ------------------------
SELECT pg_temp.remember('peer_attempt', (pg_temp.as_jsonb(pg_temp.u(3), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 15, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 3), gen_random_uuid())) ->> 'id')::uuid);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L, %L) $sql$,
      pg_temp.u(1), pg_temp.rung('planche', 3), gen_random_uuid(), pg_temp.recall('peer_attempt'))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L, %L) $sql$,
      pg_temp.u(1), pg_temp.rung('planche', 3), gen_random_uuid(), pg_temp.recall('a2'))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L, %L) $sql$,
      pg_temp.u(1), pg_temp.rung('front-lever', 1), gen_random_uuid(), pg_temp.recall('a3'))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L, %L) $sql$,
      pg_temp.u(1), pg_temp.rung('planche', 3), gen_random_uuid(), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, NULL) $sql$,
      pg_temp.u(1), pg_temp.rung('planche', 3)))
  ],
  ARRAY['22000', '22000', '22000', 'P0002', '22000'],
  'F-S6-P06 lineage: an attempt of ANOTHER athlete → 22000; of ANOTHER rung → 22000; a REJECTED attempt → 22000; an unknown attempt → P0002; NULL key → 22000'
);
SELECT is(
  ARRAY(SELECT pg_temp.as_sqlstate(pg_temp.u(n), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$,
          pg_temp.u(1), pg_temp.rung('planche', 3), gen_random_uuid()))
        FROM unnest(ARRAY[1, 3, 4, 5, 6, 7, 10, 11]) n),
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501', '42501', '42501'],
  'verify: the athlete, peer, other org, former coach, unassigned coach, Leader (org-wide view, but no skills:verify), inactive and SysAdmin-only are refused (42501)'
);
SELECT pg_temp.remember('kv', gen_random_uuid());
SELECT pg_temp.remember('ach3', (pg_temp.as_jsonb(pg_temp.u(2), format(
  $sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$, pg_temp.u(1), pg_temp.rung('planche', 3), pg_temp.recall('kv'))) ->> 'id')::uuid);
SELECT is(
  (SELECT ARRAY[ac.status, ac.verified_by::text, (ac.skill_attempt_id IS NULL)::text] FROM public.skill_achievements ac WHERE ac.id = pg_temp.recall('ach3')),
  ARRAY['active', pg_temp.u(2), 'true'],
  'the current coach verifies a rung directly (no attempt required)'
);
SELECT is(
  ARRAY[
    (pg_temp.as_jsonb(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$,
       pg_temp.u(1), pg_temp.rung('planche', 3), pg_temp.recall('kv'))) ->> 'id'),
    pg_temp.audits('skill_achievement', pg_temp.recall('ach3'), 'verified')::text,
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$,
       pg_temp.u(1), pg_temp.rung('planche', 4), pg_temp.recall('kv')))
  ],
  ARRAY[pg_temp.recall('ach3')::text, '1', '42501'],
  'replaying verify with the same key returns the same achievement (one audit row); the same key for a different rung → 42501'
);
SELECT pg_temp.remember('pend', (pg_temp.as_jsonb(pg_temp.u(1), format(
  $sql$ SELECT public.log_skill_attempt(%L, NULL, 30, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 4), gen_random_uuid())) ->> 'id')::uuid);
SELECT pg_temp.as_jsonb(pg_temp.u(2), format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L, %L) $sql$,
  pg_temp.u(1), pg_temp.rung('planche', 4), gen_random_uuid(), pg_temp.recall('pend')));
SELECT is(
  (SELECT ARRAY[a.status, a.reviewed_by::text] FROM public.skill_attempts a WHERE a.id = pg_temp.recall('pend')),
  ARRAY['approved', pg_temp.u(2)],
  'verifying WITH a pending attempt approves that attempt and records the verifier (the attempt lineage is closed, not left pending)'
);

-- 8. revoke_skill_achievement (mandatory reason) -------------------------------------------------
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, '', %L) $sql$, pg_temp.recall('ach3'), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, '   ', %L) $sql$, pg_temp.recall('ach3'), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, NULL, %L) $sql$, pg_temp.recall('ach3'), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, %L, %L) $sql$, pg_temp.recall('ach3'), repeat('x', 1001), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, 'Because.', NULL) $sql$, pg_temp.recall('ach3'))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, 'Because.', %L) $sql$, gen_random_uuid(), gen_random_uuid()))
  ],
  ARRAY['22000', '22000', '22000', '22023', '22000', 'P0002'],
  'revoke: a blank / whitespace / NULL reason → 22000; over-long → 22023; NULL key → 22000; unknown achievement → P0002'
);
SELECT is(
  ARRAY(SELECT pg_temp.as_sqlstate(pg_temp.u(n), format($sql$ SELECT public.revoke_skill_achievement(%L, 'Not allowed.', %L) $sql$,
          pg_temp.recall('ach3'), gen_random_uuid()))
        FROM unnest(ARRAY[1, 3, 4, 5, 6, 7, 10, 11]) n),
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501', '42501', '42501'],
  'revoke: the athlete, peer, other org, former coach, unassigned coach, Leader, inactive and SysAdmin-only are refused (42501)'
);
SELECT pg_temp.remember('krv', gen_random_uuid());
SELECT is(
  (SELECT r ->> 'status' FROM (SELECT pg_temp.as_jsonb(pg_temp.u(2), format(
     $sql$ SELECT public.revoke_skill_achievement(%L, 'Video clip was from prior year; form check re-evaluation required', %L) $sql$,
     pg_temp.recall('ach3'), pg_temp.recall('krv'))) AS r) x),
  'revoked',
  'the coach revokes an achievement with a reason'
);
SELECT is(
  (SELECT ARRAY[ac.status, ac.revoked_by::text, (ac.revoked_at IS NOT NULL)::text, ac.revocation_reason]
   FROM public.skill_achievements ac WHERE ac.id = pg_temp.recall('ach3')),
  ARRAY['revoked', pg_temp.u(2), 'true', 'Video clip was from prior year; form check re-evaluation required'],
  'the revocation records who, when and why'
);
SELECT is(
  (SELECT ARRAY[pg_temp.audits('skill_achievement', pg_temp.recall('ach3'), 'revoked')::text,
                (SELECT new_values ->> 'revocation_reason' FROM public.audit_logs
                  WHERE entity_type = 'skill_achievement' AND entity_id = pg_temp.recall('ach3')::text AND action = 'revoked'),
                (SELECT actor_user_id::text FROM public.audit_logs
                  WHERE entity_type = 'skill_achievement' AND entity_id = pg_temp.recall('ach3')::text AND action = 'revoked')]),
  ARRAY['1', 'Video clip was from prior year; form check re-evaluation required', pg_temp.u(2)],
  'the revocation emitted one immutable audit event carrying the reason and the acting coach'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, 'Again.', %L) $sql$, pg_temp.recall('ach3'), gen_random_uuid())),
    (pg_temp.as_jsonb(pg_temp.u(2), format($sql$ SELECT public.revoke_skill_achievement(%L, 'Video clip was from prior year; form check re-evaluation required', %L) $sql$,
       pg_temp.recall('ach3'), pg_temp.recall('krv'))) ->> 'status'),
    pg_temp.audits('skill_achievement', pg_temp.recall('ach3'), 'revoked')::text
  ],
  ARRAY['22000', 'revoked', '1'],
  'an already-revoked achievement → 22000 under a new key; replaying the SAME key returns the cached result without a second audit row'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ UPDATE public.skill_achievements SET status = 'revoked', revoked_by = %L, revoked_at = now() WHERE id = %L $sql$,
    pg_temp.u(2), pg_temp.recall('ach1'))),
  '23514',
  'the CHECK backs the RPC: even a direct write cannot revoke without a reason'
);
SELECT is(
  (SELECT r ->> 'status' FROM (SELECT pg_temp.as_jsonb(pg_temp.u(8), format(
     $sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$, pg_temp.u(1), pg_temp.rung('planche', 3), gen_random_uuid())) AS r) x),
  'active',
  'a revoked milestone can be re-verified by an officer'
);
SELECT is(
  (SELECT ARRAY[ac.status, ac.revoked_by::text, ac.revoked_at::text, ac.revocation_reason, ac.verified_by::text]
   FROM public.skill_achievements ac WHERE ac.id = pg_temp.recall('ach3')),
  ARRAY['active', NULL, NULL, NULL, pg_temp.u(8)],
  '...which clears the revocation fields and re-attributes the verification'
);

-- 9. update_skill_progression (Feature 8.1, F-S6-P07) --------------------------------------------
SELECT is(
  ARRAY(SELECT pg_temp.as_sqlstate(pg_temp.u(n), format($sql$ SELECT public.update_skill_progression(%L, 'Advanced Tuck Planche', 'x', 15, NULL, %L) $sql$,
          pg_temp.rung('planche', 2), gen_random_uuid()))
        FROM unnest(ARRAY[1, 3, 4, 7, 10, 11]) n),
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501'],
  'criteria editing needs skills:manage: the athlete, peer, other org, Leader, inactive member and SysAdmin-only get 42501'
);
SELECT pg_temp.remember('ku', gen_random_uuid());
SELECT is(
  (SELECT ARRAY[r ->> 'target_hold_seconds', r ->> 'name'] FROM (SELECT pg_temp.as_jsonb(pg_temp.u(2), format(
     $sql$ SELECT public.update_skill_progression(%L, 'Advanced Tuck Planche', 'Hips extended, flat back, straight arms.', 15, NULL, %L) $sql$,
     pg_temp.rung('planche', 2), pg_temp.recall('ku'))) AS r) x),
  ARRAY['15', 'Advanced Tuck Planche'],
  'a Coach edits a rung''s criteria (12 s → 15 s)'
);
SELECT is(
  (SELECT ARRAY[old_values ->> 'target_hold_seconds', new_values ->> 'target_hold_seconds', new_values ->> 'updated_by']
   FROM public.audit_logs WHERE entity_type = 'skill_progression' AND entity_id = pg_temp.rung('planche', 2)::text AND action = 'updated'),
  ARRAY['12', '15', pg_temp.u(2)],
  'F-S6-P07: the edit is audited with the old (12) and new (15) values and the acting coach'
);
SELECT is(
  ARRAY[
    (pg_temp.as_jsonb(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, 'Advanced Tuck Planche', 'Hips extended, flat back, straight arms.', 15, NULL, %L) $sql$,
       pg_temp.rung('planche', 2), pg_temp.recall('ku'))) ->> 'target_hold_seconds'),
    pg_temp.audits('skill_progression', pg_temp.rung('planche', 2), 'updated')::text,
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, 'Advanced Tuck Planche', 'Hips extended, flat back, straight arms.', 20, NULL, %L) $sql$,
       pg_temp.rung('planche', 2), pg_temp.recall('ku')))
  ],
  ARRAY['15', '1', '42501'],
  'replaying the edit with the same key is a no-op (one audit row); the same key with another target → 42501'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, 'Name', NULL, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 2), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, 'Name', NULL, 0, NULL, %L) $sql$, pg_temp.rung('planche', 2), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, '   ', NULL, 5, NULL, %L) $sql$, pg_temp.rung('planche', 2), gen_random_uuid())),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, 'Name', NULL, 5, NULL, NULL) $sql$, pg_temp.rung('planche', 2))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ SELECT public.update_skill_progression(%L, 'Name', NULL, 5, NULL, %L) $sql$, gen_random_uuid(), gen_random_uuid()))
  ],
  ARRAY['22023', '22023', '22023', '22000', 'P0002'],
  'criteria validation: no target / zero target / blank name → 22023; NULL key → 22000; unknown rung → P0002'
);
INSERT INTO public.member_positions (profile_id, position_id)
SELECT pg_temp.u(4)::uuid, id FROM public.positions WHERE name = 'Coach';
SELECT is(
  pg_temp.as_sqlstate(pg_temp.u(4), format($sql$ SELECT public.update_skill_progression(%L, 'Hijack', NULL, 5, NULL, %L) $sql$,
    pg_temp.rung('planche', 2), gen_random_uuid())),
  '42501',
  'a Coach of ANOTHER organization holds skills:manage but cannot edit this organization''s rung (42501)'
);
SELECT is(
  (SELECT ARRAY[sp.name, sp.target_hold_seconds::text] FROM public.skill_progressions sp WHERE sp.id = pg_temp.rung('planche', 2)),
  ARRAY['Advanced Tuck Planche', '15'],
  '...and the rung was not touched'
);
SELECT app_private.seed_default_skill_ladders('00000000-0000-4000-8000-000000000001');
SELECT is(
  ARRAY[
    (SELECT count(*)::text FROM public.skills WHERE organization_id = '00000000-0000-4000-8000-000000000001'),
    (SELECT count(*)::text FROM public.skill_progressions sp JOIN public.skills s ON s.id = sp.skill_id WHERE s.organization_id = '00000000-0000-4000-8000-000000000001'),
    (SELECT target_hold_seconds::text FROM public.skill_progressions WHERE id = pg_temp.rung('planche', 2))
  ],
  ARRAY['6', '28', '15'],
  'the seed is idempotent AND never overwrites a coach''s edit (re-running it left 6/28 rows and the edited 15 s)'
);

-- 10. Lock ordering and serialization statements (structural) -------------------------------------
SELECT is(
  (SELECT bool_and(position('acquire_idempotency' in p.prosrc) > 0
                   AND position('acquire_idempotency' in p.prosrc) < position('FOR UPDATE' in p.prosrc))
   FROM pg_proc p WHERE p.oid IN (
     'app_private.review_skill_attempt_internal(uuid, boolean, text, uuid)'::regprocedure,
     'app_private.revoke_skill_achievement_internal(uuid, text, uuid)'::regprocedure,
     'app_private.update_skill_progression_internal(uuid, text, text, integer, integer, uuid)'::regprocedure,
     'app_private.verify_skill_achievement_internal(uuid, uuid, uuid, uuid)'::regprocedure)),
  true,
  'F-S6-P05: every mutation that takes a domain row lock reserves its idempotency key BEFORE the FOR UPDATE'
);
SELECT is(
  ARRAY[
    (SELECT (position('FROM public.skill_attempts WHERE id = p_skill_attempt_id FOR UPDATE' in prosrc) > 0)::text
       FROM pg_proc WHERE oid = 'app_private.verify_skill_achievement_internal(uuid, uuid, uuid, uuid)'::regprocedure),
    (SELECT (position('ON CONFLICT (athlete_id, skill_id) DO UPDATE' in prosrc) > 0)::text
       FROM pg_proc WHERE oid = 'app_private.set_athlete_skill_status_internal(uuid, uuid, uuid, uuid)'::regprocedure),
    (SELECT (position('FROM public.skill_achievements WHERE id = p_achievement_id FOR UPDATE' in prosrc) > 0)::text
       FROM pg_proc WHERE oid = 'app_private.revoke_skill_achievement_internal(uuid, text, uuid)'::regprocedure),
    (SELECT (position('FROM public.skill_attempts WHERE id = p_attempt_id FOR UPDATE' in prosrc) > 0)::text
       FROM pg_proc WHERE oid = 'app_private.review_skill_attempt_internal(uuid, boolean, text, uuid)'::regprocedure)
  ],
  ARRAY['true', 'true', 'true', 'true'],
  'serialization statements: verify locks the linked attempt (finding F-S6-E03), status upserts on the (athlete, skill) key, revoke locks the achievement, review locks the attempt'
);

-- 11. F-S6-P15 privilege delegation; F-S6-P13 mandatory key ---------------------------------------
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(NULL, format($sql$ SELECT public.set_athlete_skill_status(%L, %L, %L, %L) $sql$, pg_temp.u(1), pg_temp.skill('planche'), pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(NULL, format($sql$ SELECT public.log_skill_attempt(%L, NULL, 5, NULL, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(NULL, format($sql$ SELECT public.review_skill_attempt(%L, true, NULL, %L) $sql$, pg_temp.recall('a2'), gen_random_uuid())),
    pg_temp.as_sqlstate(NULL, format($sql$ SELECT public.verify_skill_achievement(%L, %L, %L) $sql$, pg_temp.u(1), pg_temp.rung('planche', 1), gen_random_uuid())),
    pg_temp.as_sqlstate(NULL, format($sql$ SELECT public.revoke_skill_achievement(%L, 'x', %L) $sql$, pg_temp.recall('ach1'), gen_random_uuid())),
    pg_temp.as_sqlstate(NULL, format($sql$ SELECT public.update_skill_progression(%L, 'x', NULL, 5, NULL, %L) $sql$, pg_temp.rung('planche', 1), gen_random_uuid()))
  ],
  ARRAY['42501', '42501', '42501', '42501', '42501', '42501'],
  'F-S6-P15: anon is denied (42501) on all six public mutating RPCs'
);
SELECT is(
  (SELECT array_agg(DISTINCT mutation_type ORDER BY mutation_type)
   FROM app_private.idempotency_keys
   WHERE status = 'completed'
     AND mutation_type IN ('SET_SKILL_STATUS', 'LOG_SKILL_ATTEMPT', 'REVIEW_SKILL_ATTEMPT', 'VERIFY_SKILL', 'REVOKE_SKILL', 'UPDATE_PROGRESSION')),
  ARRAY['LOG_SKILL_ATTEMPT', 'REVIEW_SKILL_ATTEMPT', 'REVOKE_SKILL', 'SET_SKILL_STATUS', 'UPDATE_PROGRESSION', 'VERIFY_SKILL'],
  'F-S6-P15: all six public mutating RPCs executed SUCCESSFULLY as authenticated in this suite (each left a completed ledger entry of its own type)'
);
SELECT is(
  (SELECT array_agg(has_function_privilege(r, f, 'EXECUTE') ORDER BY r, f)
   FROM unnest(ARRAY['anon', 'authenticated']) r,
        unnest(ARRAY['public.set_athlete_skill_status(uuid, uuid, uuid, uuid)', 'public.log_skill_attempt(uuid, date, integer, integer, text, uuid)',
                     'public.review_skill_attempt(uuid, boolean, text, uuid)', 'public.verify_skill_achievement(uuid, uuid, uuid, uuid)',
                     'public.revoke_skill_achievement(uuid, text, uuid)', 'public.update_skill_progression(uuid, text, text, integer, integer, uuid)']) f),
  ARRAY[false, false, false, false, false, false, true, true, true, true, true, true],
  'F-S6-P15: the public wrappers are executable by authenticated and NOT by anon'
);
SELECT is(
  (SELECT array_agg(has_function_privilege(r, f, 'EXECUTE') ORDER BY r, f)
   FROM unnest(ARRAY['anon', 'authenticated']) r,
        unnest(ARRAY['app_private.set_athlete_skill_status_internal(uuid, uuid, uuid, uuid)', 'app_private.log_skill_attempt_internal(uuid, date, integer, integer, text, uuid)',
                     'app_private.review_skill_attempt_internal(uuid, boolean, text, uuid)', 'app_private.verify_skill_achievement_internal(uuid, uuid, uuid, uuid)',
                     'app_private.revoke_skill_achievement_internal(uuid, text, uuid)', 'app_private.update_skill_progression_internal(uuid, text, text, integer, integer, uuid)']) f),
  ARRAY[false, false, false, false, false, false, true, true, true, true, true, true],
  'F-S6-P15: the six private delegates are executable by authenticated and NOT by anon'
);
SELECT is(
  ARRAY[
    (SELECT array_agg(NOT p.prosecdef) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('set_athlete_skill_status', 'log_skill_attempt', 'review_skill_attempt', 'verify_skill_achievement',
                         'revoke_skill_achievement', 'update_skill_progression'))::text,
    (SELECT bool_and(p.prosecdef AND p.proconfig @> ARRAY['search_path=""'])::text FROM pg_proc p WHERE p.pronamespace = 'app_private'::regnamespace
       AND p.proname IN ('set_athlete_skill_status_internal', 'log_skill_attempt_internal', 'review_skill_attempt_internal',
                         'verify_skill_achievement_internal', 'revoke_skill_achievement_internal', 'update_skill_progression_internal',
                         'holds_active_position', 'can_view_athlete_training', 'can_verify_skill', 'can_set_athlete_skill_status',
                         'can_view_athlete_skill_status', 'can_view_athlete_skill_attempts', 'can_view_athlete_skill_achievements'))
  ],
  ARRAY['{t,t,t,t,t,t}', 'true'],
  'F-S6-P15: the six public wrappers are SECURITY INVOKER; the six delegates and seven helpers are SECURITY DEFINER with an empty search_path'
);
SELECT is(
  (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('set_athlete_skill_status', 'log_skill_attempt', 'review_skill_attempt', 'verify_skill_achievement',
                       'revoke_skill_achievement', 'update_skill_progression')
     AND pg_get_function_arguments(p.oid) ~ 'p_idempotency_key uuid DEFAULT'),
  0::bigint,
  'F-S6-P13: p_idempotency_key is required with NO default on all six mutating RPCs (including verify_skill_achievement)'
);
SELECT is(
  pg_temp.sqlstate_of(format($sql$ SELECT public.verify_skill_achievement(%L, %L) $sql$, pg_temp.u(1), pg_temp.rung('planche', 1))),
  '42883',
  'F-S6-P13: verify_skill_achievement cannot even be CALLED without a key (no such function)'
);
SELECT is(
  ARRAY[
    pg_temp.as_sqlstate(pg_temp.u(1), format($sql$ INSERT INTO public.skill_attempts (athlete_id, progression_id, actual_reps) VALUES (%L, %L, 3) $sql$, pg_temp.u(1), pg_temp.rung('planche', 1))),
    pg_temp.as_sqlstate(pg_temp.u(2), format($sql$ UPDATE public.skill_attempts SET status = 'approved' WHERE id = %L $sql$, pg_temp.recall('a3'))),
    pg_temp.as_sqlstate(pg_temp.u(8), format($sql$ DELETE FROM public.skill_achievements WHERE id = %L $sql$, pg_temp.recall('ach1'))),
    pg_temp.as_sqlstate(pg_temp.u(9), format($sql$ UPDATE public.skill_progressions SET target_reps = 99 WHERE id = %L $sql$, pg_temp.rung('planche', 1)))
  ],
  ARRAY['42501', '42501', '42501', '42501'],
  'ADR-002: direct DML is refused (42501) even for a Coach, a Vice President and the President — the RPCs are the only write path'
);

SELECT * FROM finish();
ROLLBACK;
