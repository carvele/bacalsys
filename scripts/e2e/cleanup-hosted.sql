-- Removes throwaway identities created by scripts/e2e/walking-skeleton.mjs on the
-- hosted DEV project. Run deliberately (it permanently deletes rows); never on production.
--
-- Scope is deliberately narrow: only the exact E2E address pattern
-- (juan.<13-digit ms timestamp>@bacalsys.local, maria.<…>@bacalsys.local), older than 24 h.
-- Deleting auth.users cascades to profiles / member_positions; audit_logs keeps the history
-- (append-only), so every removed identity remains accounted for.

-- 1. Preview what would be removed.
SELECT id, email, created_at
FROM auth.users
WHERE email ~ '^(juan|maria)\.[0-9]{13}@bacalsys\.local$'
  AND created_at < now() - interval '24 hours'
ORDER BY created_at;

-- 2. Remove (uncomment after reviewing step 1).
-- BEGIN;
-- SELECT set_config('bacalsys.actor_type', 'system', true);
-- DELETE FROM auth.users
-- WHERE email ~ '^(juan|maria)\.[0-9]{13}@bacalsys\.local$'
--   AND created_at < now() - interval '24 hours';
-- COMMIT;
