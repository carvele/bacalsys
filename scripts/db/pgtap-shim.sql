-- =============================================================================
-- pgTAP-compatible subset for the offline PGlite harness (PGlite ships without
-- the pgTAP extension). Implements exactly the functions used by
-- supabase/tests/*.test.sql with pgTAP's signatures and TAP output, so the same
-- files run unchanged under `supabase test db` (real pgTAP) and here.
--   plan, ok, is, isnt, throws_ok, lives_ok, is_empty, isnt_empty, finish
-- =============================================================================
CREATE FUNCTION extensions._tap_state() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- Created once (by the session owner, from plan()) and shared with every role
  -- a test switches into, mirroring pgTAP's GRANT on its __tcache__ table.
  IF to_regclass('pg_temp.__tap') IS NULL THEN
    CREATE TEMP TABLE __tap (n serial, ok boolean NOT NULL);
    GRANT ALL ON TABLE pg_temp.__tap TO PUBLIC;
    GRANT ALL ON SEQUENCE pg_temp.__tap_n_seq TO PUBLIC;
  END IF;
END $$;

CREATE FUNCTION extensions.plan(integer) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM extensions._tap_state();
  TRUNCATE pg_temp.__tap RESTART IDENTITY;
  PERFORM set_config('tap.planned', $1::text, true);
  RETURN '1..' || $1;
END $$;

CREATE FUNCTION extensions.ok(boolean, text DEFAULT '') RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_n integer; v_ok boolean := COALESCE($1, false);
BEGIN
  PERFORM extensions._tap_state();
  INSERT INTO pg_temp.__tap (ok) VALUES (v_ok) RETURNING n INTO v_n;
  RETURN CASE WHEN v_ok THEN 'ok ' ELSE 'not ok ' END || v_n || ' - ' || COALESCE($2, '');
END $$;

CREATE FUNCTION extensions.is(anyelement, anyelement, text DEFAULT '') RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_res text;
BEGIN
  v_res := extensions.ok($1 IS NOT DISTINCT FROM $2, $3);
  IF $1 IS DISTINCT FROM $2 THEN
    v_res := v_res || E'\n#   have: ' || COALESCE($1::text, 'NULL') || E'\n#   want: ' || COALESCE($2::text, 'NULL');
  END IF;
  RETURN v_res;
END $$;

CREATE FUNCTION extensions.isnt(anyelement, anyelement, text DEFAULT '') RETURNS text LANGUAGE sql AS $$
  SELECT extensions.ok($1 IS DISTINCT FROM $2, $3);
$$;

-- throws_ok(sql, errcode, errmsg, description); errmsg NULL = any message.
CREATE FUNCTION extensions.throws_ok(text, char(5), text, text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE $1;
  RETURN extensions.ok(false, $4) || E'\n#   no exception raised';
EXCEPTION WHEN OTHERS THEN
  IF ($2 IS NULL OR SQLSTATE = $2) AND ($3 IS NULL OR SQLERRM = $3) THEN
    RETURN extensions.ok(true, $4);
  END IF;
  RETURN extensions.ok(false, $4) || E'\n#   caught: ' || SQLSTATE || ': ' || SQLERRM
    || E'\n#   wanted: ' || COALESCE($2, '*') || ': ' || COALESCE($3, '*');
END $$;

CREATE FUNCTION extensions.lives_ok(text, text DEFAULT '') RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE $1;
  RETURN extensions.ok(true, $2);
EXCEPTION WHEN OTHERS THEN
  RETURN extensions.ok(false, $2) || E'\n#   died: ' || SQLSTATE || ': ' || SQLERRM;
END $$;

CREATE FUNCTION extensions.is_empty(text, text DEFAULT '') RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_found boolean;
BEGIN
  EXECUTE 'SELECT EXISTS (' || $1 || ')' INTO v_found;
  RETURN extensions.ok(NOT v_found, $2);
END $$;

CREATE FUNCTION extensions.isnt_empty(text, text DEFAULT '') RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_found boolean;
BEGIN
  EXECUTE 'SELECT EXISTS (' || $1 || ')' INTO v_found;
  RETURN extensions.ok(v_found, $2);
END $$;

CREATE FUNCTION extensions.finish() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE v_planned integer := NULLIF(current_setting('tap.planned', true), '')::integer;
        v_run integer; v_failed integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT ok) INTO v_run, v_failed FROM pg_temp.__tap;
  IF v_planned IS NOT NULL AND v_run <> v_planned THEN
    RETURN NEXT '# Looks like you planned ' || v_planned || ' tests but ran ' || v_run;
  END IF;
  IF v_failed > 0 THEN
    RETURN NEXT '# Looks like you failed ' || v_failed || ' test(s) of ' || v_run;
  END IF;
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO PUBLIC;
