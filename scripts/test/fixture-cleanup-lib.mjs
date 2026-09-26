/**
 * Sprint 2 · Task 2.0 — guarded dev/test fixture cleanup (pure logic, unit-tested).
 *
 * Two independent guards:
 *   1. assertSafeTarget(): the environment check. Local stacks are always allowed;
 *      a remote project only when FIXTURE_CLEANUP_ALLOWED_URL names exactly that URL
 *      (explicit per-project opt-in) and its ref is not listed as protected.
 *   2. buildCleanupSql(): the data guard. It selects only accounts tagged as test
 *      fixtures (see fixtures.mjs), refuses to run if a candidate holds an executive
 *      position or a system role, caps the batch size, and never removes a fixture
 *      that real (non-fixture) records depend on. Coaching history and exercises are
 *      deleted only where every party is a fixture. Everything runs in one
 *      transaction; the append-only audit log keeps a record of each removal.
 */
import { FIXTURE_DOMAIN, FIXTURE_METADATA_KEY } from './fixtures.mjs';

const LOCAL_HOST = /^(127\.0\.0\.1|localhost|10\.0\.2\.2|\[::1\]|[a-z0-9-]+\.localhost)$/i;

export class UnsafeTargetError extends Error {}

/** Returns the parsed target, or throws UnsafeTargetError. */
export function assertSafeTarget(targetUrl, env = {}) {
  let url;
  try {
    url = new URL(targetUrl);
  } catch {
    throw new UnsafeTargetError(`Not a URL: ${targetUrl}`);
  }
  if (env.NODE_ENV === 'production') {
    throw new UnsafeTargetError('Refusing to run with NODE_ENV=production.');
  }
  if (LOCAL_HOST.test(url.hostname)) return { kind: 'local', host: url.hostname };

  const ref = /^([a-z0-9]{20})\.supabase\.co$/.exec(url.hostname)?.[1];
  if (!ref) throw new UnsafeTargetError(`Not a local stack or a Supabase project URL: ${url.hostname}`);

  const protectedRefs = (env.FIXTURE_CLEANUP_PROTECTED_REFS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (protectedRefs.includes(ref)) {
    throw new UnsafeTargetError(`Project ${ref} is listed in FIXTURE_CLEANUP_PROTECTED_REFS.`);
  }
  const allowed = (env.FIXTURE_CLEANUP_ALLOWED_URL ?? '').replace(/\/+$/, '');
  if (allowed !== url.origin) {
    throw new UnsafeTargetError(
      `Remote project ${ref} is not opted in. Set FIXTURE_CLEANUP_ALLOWED_URL=${url.origin} (dev projects only).`,
    );
  }
  return { kind: 'remote', ref };
}

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Guarded, transactional cleanup SQL for the tagged fixtures. */
export function buildCleanupSql({ minAgeMinutes = 0, maxAccounts = 200, includeLegacy = true } = {}) {
  if (!Number.isInteger(minAgeMinutes) || minAgeMinutes < 0) throw new Error('minAgeMinutes must be a non-negative integer');
  if (!Number.isInteger(maxAccounts) || maxAccounts < 1 || maxAccounts > 1000) throw new Error('maxAccounts must be 1..1000');

  const fixtureEmail = `^[a-z0-9._-]+@${escapeRegex(FIXTURE_DOMAIN)}$`;
  // Sprint 1 walking-skeleton accounts predate the tags; their exact pattern is unambiguous.
  const legacy = includeLegacy
    ? `\n     OR u.email ~ '^(juan|maria)\\.[0-9]{13}@bacalsys\\.local$'`
    : '';

  return `-- BaCalSys guarded fixture cleanup (scripts/test/cleanup-fixtures.mjs). One transaction.
BEGIN;
SELECT set_config('bacalsys.actor_type', 'system', true);

CREATE TEMP TABLE _fixture_users ON COMMIT DROP AS
SELECT u.id, u.email::text AS email
FROM auth.users u
WHERE u.created_at <= now() - make_interval(mins => ${minAgeMinutes})
  AND (
     (u.raw_user_meta_data ->> '${FIXTURE_METADATA_KEY}' = 'true' AND u.email ~ '${fixtureEmail}')${legacy}
  );

DO $guard$
DECLARE
  v_removed integer;
BEGIN
  IF EXISTS (
    SELECT 1 FROM _fixture_users f
    JOIN public.member_positions mp ON mp.profile_id = f.id AND mp.ended_at IS NULL
    JOIN public.positions pos ON pos.id = mp.position_id
    WHERE pos.name IN ('Vice President', 'President')
  ) OR EXISTS (
    SELECT 1 FROM _fixture_users f
    JOIN public.user_system_roles r ON r.user_id = f.id AND r.ended_at IS NULL
  ) THEN
    RAISE EXCEPTION 'fixture cleanup aborted: a tagged candidate holds an executive position or a system role';
  END IF;

  IF (SELECT count(*) FROM _fixture_users) > ${maxAccounts} THEN
    RAISE EXCEPTION 'fixture cleanup aborted: % candidates exceeds the limit of ${maxAccounts}',
      (SELECT count(*) FROM _fixture_users);
  END IF;

  -- Keep any fixture that a non-fixture record depends on, until stable.
  LOOP
    DELETE FROM _fixture_users f
    WHERE EXISTS (
      SELECT 1 FROM public.coach_assignments ca
      WHERE f.id IN (ca.athlete_id, ca.coach_id, ca.assigned_by, ca.ended_by)
        AND NOT (ca.athlete_id IN (SELECT id FROM _fixture_users)
                 AND ca.coach_id IN (SELECT id FROM _fixture_users))
    ) OR EXISTS (
      SELECT 1 FROM public.exercises e
      WHERE e.reviewed_by = f.id
        AND (e.created_by IS NULL OR e.created_by NOT IN (SELECT id FROM _fixture_users))
    );
    GET DIAGNOSTICS v_removed = ROW_COUNT;
    EXIT WHEN v_removed = 0;
  END LOOP;
END
$guard$;

CREATE TEMP TABLE _fixture_cleanup_report ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM _fixture_users) AS accounts,
  (SELECT count(*) FROM public.coach_assignments
    WHERE athlete_id IN (SELECT id FROM _fixture_users) AND coach_id IN (SELECT id FROM _fixture_users)) AS coach_assignments,
  (SELECT count(*) FROM public.exercises WHERE created_by IN (SELECT id FROM _fixture_users)) AS exercises;

DELETE FROM public.coach_assignments
WHERE athlete_id IN (SELECT id FROM _fixture_users) AND coach_id IN (SELECT id FROM _fixture_users);
DELETE FROM public.exercises WHERE created_by IN (SELECT id FROM _fixture_users);
-- Cascades to profiles, member_positions and invitations; audit_logs keeps the history.
DELETE FROM auth.users WHERE id IN (SELECT id FROM _fixture_users);

SELECT * FROM _fixture_cleanup_report;
COMMIT;
`;
}
