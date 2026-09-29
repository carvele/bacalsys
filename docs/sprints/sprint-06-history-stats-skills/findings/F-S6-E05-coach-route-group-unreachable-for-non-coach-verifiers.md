# F-S6-E05 — a Vice President or President could not reach `(coach)/skills/verify`

- **Class:** Bug (navigation gap, client-only, closed before merge).
- **Found by:** the Executor, wiring Task 6.15's navigation against the Sprint 6 permission matrix
  (`skills:verify` → Coach, Vice President, President) and the accepted Sprint 1 root navigator.

## Symptom

`src/app/_layout.tsx`'s `RootNavigator` (accepted since Sprint 1) mounts the whole `(coach)` route segment behind
`Stack.Protected guard={isCoach}`, where `isCoach = access.positions.includes('Coach')`. Section 13's frozen file
tree places the Coach Skill Verification Queue at `src/app/(coach)/skills/verify.tsx` — inside that same segment.
A Vice President or President who is not also a Coach (the common case) holds `skills:verify` and would see the
"Skill verification queue" entry point, but the `(coach)` segment itself would never mount for them, so the route
would be unreachable regardless of what the screen itself checks.

This is a client-side navigation gap only: the RPCs (`review_skill_attempt`, `verify_skill_achievement`,
`revoke_skill_achievement`) already authorize VP/President correctly at the database layer (`can_verify_skill`);
nothing here was a security hole, only a dead end in the UI.

## Fix

`src/app/_layout.tsx` widens the guard to `isCoach || hasPermission(access, 'skills:verify')`, named
`canSeeCoachGroup`. `my-athletes.tsx` (Coach-relationship-specific) is unaffected — it still only shows athletes for
whoever actually coaches them, which is empty and harmless for a VP/President with no coaching relationships.

## Verification

Manual reasoning + `npx tsc --noEmit` / `npx expo lint` clean. Not covered by an automated test — there is no
Jest test harness over `RootNavigator`'s guard logic in this codebase (Sprint 1 established it, and none was added
since); flagged here rather than silently added. Functionally exercised on `bacalsys-dev` by
`scripts/e2e/sprint6-slices.mjs slices`, where the Vice President fixture calls the same RPCs the queue screen
calls (RPC-level proof; not a click-through of the route guard itself, which needs a device — see F-S6-E06).
