---
name: supabase-security
description: Implement or review BaCalSys Supabase migrations, RLS, RPCs, grants, temporal access, audit logging, and database security.
---

# BaCalSys Supabase Security

Use for any PostgreSQL schema, migration, RLS, RPC, permission, trigger, cron, or Supabase Storage authorization work.

## Mandatory migration rules

- All database changes are version-controlled migrations.
- Prefer constraints/indexes over application-only invariants when possible.
- Use `timestamptz` for absolute timestamps.
- Preserve historical rows instead of destructive rewrites where the domain requires history.
- After schema changes, regenerate TypeScript database types if the repository supports it.

## Private helper rules

Internal helpers belong in `app_private`.

For `SECURITY DEFINER`:
- `SET search_path = ''`
- fully qualify referenced objects
- minimize privileges
- revoke default execution
- grant execution only where required
- never trust caller-supplied user IDs when `auth.uid()` should define the principal

Do not expose `app_private` through PostgREST.

## Public RPC rules

Client-callable workflows use explicit `public` wrappers.

Each wrapper must:
1. derive authenticated principal from `auth.uid()`
2. reject unauthenticated access
3. validate permission and row scope
4. validate inputs
5. call internal logic
6. expose only necessary output

Revoke function execute from unintended roles and explicitly grant intended callers.

## RLS rules

- Enable RLS on application tables.
- Permission checks and row scope are separate concepts.
- Compose:
  - ownership
  - organization membership
  - active position/system-role permissions
  - current coach relationships
  - former coach time windows
- Former coach interval is half-open.
- Current primary coach sees full athlete history.
- Leader organization-wide training visibility must not imply private discomfort visibility.
- Never use client-side filtering as authorization.

## Audit rules

- Clients cannot directly insert/update/delete audit rows.
- Trusted trigger/function writes only.
- Update/delete hard-fail.
- Support user and system actors.
- Do not claim database-owner-level immutability; guarantee application/runtime immutability.

## Testing

For each security change, add tests for:
- allowed caller
- forbidden caller
- neighboring role
- cross-user row
- expired/ended temporal role
- former coach before/during/after window
- current coach
- organization-wide role
- anonymous caller where relevant

Never relax policy merely to get a test green.
