-- Sprint 1 DoD #3, #4, #16 — security baseline structure.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
-- ADR-002: let impersonated roles call pgTAP; rolled back with the test.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated;

SELECT plan(17);

-- app_private: unexposed schema, usable only for RLS evaluation --------------
SELECT ok(
  EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'app_private'),
  'app_private schema exists'
);
SELECT ok(
  NOT has_schema_privilege('anon', 'app_private', 'USAGE'),
  'anon has no USAGE on app_private'
);
SELECT ok(
  has_schema_privilege('authenticated', 'app_private', 'USAGE'),
  'authenticated has USAGE on app_private (RLS evaluation only)'
);
SELECT ok(
  NOT has_schema_privilege('authenticated', 'app_private', 'CREATE'),
  'authenticated cannot create objects in app_private'
);
SELECT ok(
  NOT has_schema_privilege('authenticated', 'public', 'CREATE')
    AND NOT has_schema_privilege('anon', 'public', 'CREATE'),
  'client roles cannot create objects in public (search-path protection)'
);

-- Default EXECUTE revocation on new public functions -------------------------
CREATE FUNCTION public.__default_privilege_probe() RETURNS integer LANGUAGE sql AS 'SELECT 1';
SELECT ok(
  NOT has_function_privilege('anon', 'public.__default_privilege_probe()', 'EXECUTE'),
  'new public function is NOT executable by anon by default'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.__default_privilege_probe()', 'EXECUTE'),
  'new public function is NOT executable by authenticated by default'
);

-- New public tables are not exposed without explicit grants -------------------
CREATE TABLE public.__default_table_probe (id int);
SELECT ok(
  NOT has_table_privilege('anon', 'public.__default_table_probe', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.__default_table_probe', 'SELECT'),
  'new public table is NOT readable by client roles by default'
);

-- Explicit RPC grants ---------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('anon', 'public.get_my_access_context()', 'EXECUTE'),
  'anon cannot execute get_my_access_context()'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.get_my_access_context()', 'EXECUTE'),
  'authenticated can execute get_my_access_context()'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'app_private.approve_member_internal(uuid, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'app_private.create_invitation_internal(uuid, text, uuid, integer)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'app_private.handle_new_user()', 'EXECUTE'),
  'internal implementations are not executable by authenticated'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app_private.has_permission(text)', 'EXECUTE'),
  'anon cannot execute app_private.has_permission'
);

-- anon has no table access at all --------------------------------------------
SELECT is_empty(
  $$ SELECT c.relname
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname NOT LIKE '\_\_%'
       AND (has_table_privilege('anon', c.oid, 'SELECT')
         OR has_table_privilege('anon', c.oid, 'INSERT')
         OR has_table_privilege('anon', c.oid, 'UPDATE')
         OR has_table_privilege('anon', c.oid, 'DELETE')) $$,
  'anon holds no privileges on any BaCalSys table'
);

-- RLS is enabled everywhere ---------------------------------------------------
SELECT is_empty(
  $$ SELECT c.relname
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname NOT LIKE '\_\_%'
       AND NOT c.relrowsecurity $$,
  'every public table has RLS enabled'
);

-- Every SECURITY DEFINER function pins an empty search_path -------------------
SELECT is_empty(
  $$ SELECT n.nspname || '.' || p.proname
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('public', 'app_private') AND p.prosecdef
       AND NOT COALESCE(p.proconfig @> ARRAY['search_path=""'], false) $$,
  'all SECURITY DEFINER functions set search_path = '''''
);

-- Every BaCalSys function (not only SECURITY DEFINER) pins search_path -------
-- Advisor lint 0011; extension-owned functions are excluded.
SELECT is_empty(
  $$ SELECT n.nspname || '.' || p.proname
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('public', 'app_private') AND p.proname NOT LIKE '\_\_%'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                       WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
       AND NOT COALESCE(p.proconfig @> ARRAY['search_path=""'], false) $$,
  'every BaCalSys function pins search_path'
);

-- Organization timezone default ----------------------------------------------
SELECT is(
  (SELECT column_default FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'organizations' AND column_name = 'timezone'),
  '''Asia/Manila''::text',
  'organizations.timezone defaults to Asia/Manila'
);

SELECT * FROM finish();
ROLLBACK;
