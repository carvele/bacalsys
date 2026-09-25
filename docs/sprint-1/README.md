# Sprint 1: Walking Skeleton & Foundations: Status Report

Baseline: BaCalSys Implementation Roadmap v1.2 (frozen). Date: 2026-09-25.

## Summary

All fifteen engineering tasks are implemented, and the walking skeleton has now been **verified live**
against a hosted Supabase dev project (`bacalsys-dev`, Postgres 17, real Auth, PostgREST and RLS):

| Verification | Where | Result |
|---|---|---|
| Live walking-skeleton E2E (Task 1.15), 24 checks | hosted `bacalsys-dev` | **24/24** |
| pgTAP suites 001–005 with real pgTAP | hosted Supabase Postgres 17 | **103/103** (latest suite versions) |
| pgTAP suites 001–005, database rebuilt from scratch | offline PGlite (PG 18.3) | **103/103** |
| Jest unit tests | local | **23/23** |
| Typecheck, lint, `expo-doctor`, web export | local | clean, 21/21 |
| Generated DB types (`src/types/database.ts`) | from hosted schema | replaced the hand-written file |

The hosted run found **two real defects that the offline harness could not see**. Both are fixed,
covered by regression tests, and re-verified live (see [Findings from live verification](#findings-from-live-verification)).

Still open: a **native (Android/iOS) dev build** has not been compiled, and the **app UI click-through**
(register → approve → sign in by hand) has not been performed. The same flow was verified through the API.

## Task status

| Task | Deliverable | Status |
|---|---|---|
| 1.1 | Expo SDK 57 (RN 0.86.3), TS strict, Expo Router typed routes, dev client, `eas.json` profiles | Done ([ADR-001](../adr/ADR-001-expo-router-version-and-route-root.md)) |
| 1.2 | NativeWind 4.2.7 + Tailwind 3.4, dark-first semantic tokens | Done |
| 1.3 | Supabase client (chunked SecureStore native / localStorage web), NetInfo→`onlineManager`, AppState→`focusManager` | Done |
| 1.4 | `001_security_baseline.sql` | Done ([ADR-002](../adr/ADR-002-global-function-execute-revocation.md)) |
| 1.5 | `002_identity_rbac_schema.sql` | Done |
| 1.6 | `003_auth_functions.sql`: verbatim `has_permission` / `get_my_access_context`, signup trigger, invitation + approval RPCs | Done |
| 1.7 | `004_audit_logs.sql`: immutable log, verbatim blocking trigger, actor types | Done |
| 1.8 | `005_rls_policies.sql` | Done |
| 1.9 | `seed.sql` | Done |
| 1.10 | Zustand session store, `useAuth`, access-context query | Done |
| 1.11 | `(auth)/login`, `register`, `pending-approval` | Done |
| 1.12 | `(officer)/member-approvals` | Done |
| 1.13 | `(athlete)/index` + `Stack.Protected` guards | Done |
| 1.14 | pgTAP suites 001–005 | Done: passing on real Supabase and offline |
| 1.15 | Live walking-skeleton E2E | **Done: 24/24 on hosted Supabase** |
| (fix) | `006_strip_invite_token_on_update.sql`, `007_advisor_hardening.sql` | Done: found during live verification |

## Definition of Done

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Boots on Web + Android/iOS dev build | Web ✅ · Native ⏳ | Web boots against local and hosted backends; `expo-doctor` 21/21; native build not yet compiled |
| 2 | Supabase environment runs migrations reproducibly | ✅ (hosted) · local ⏳ | 001–007 applied cleanly to hosted; offline harness rebuilds from scratch every run; local `supabase start` needs Docker |
| 3 | `app_private` exists, not exposed | ✅ | test 001 #1–4 on real Supabase |
| 4 | Default function EXECUTE revoked | ✅ | test 001 #6–7 on real Supabase (ADR-002) |
| 5 | Org, positions, permissions, position_permissions | ✅ | test 002 #3 |
| 6 | System-role tables with temporal columns | ✅ | test 002 #1–2, #9–13 |
| 7 | Registration creates pending profile via trigger | ✅ | live E2E #1–2 (real Auth signup); test 003 #1–4 |
| 8 | Invitations: SHA-256, single-use, expiry | ✅ | test 003 #5–25; live E2E #21–24 |
| 9 | President views pending applications and approves | ✅ | live E2E #4–8 (separate client/"device") |
| 10 | Approval atomically sets active + inserts Athlete | ✅ | live E2E #7–8, #10; test 005 #12–13 (forced failure rolls back) |
| 11 | `get_my_access_context()` exact output | ✅ | live E2E #5, #11; test 002 |
| 12 | Pending users blocked at PendingApprovalScreen | ✅ | live E2E #2–3; route resolver fails closed (Jest) |
| 13 | Approved users land on Athlete Home | ✅ | live E2E #9–11; Jest route matrix |
| 14 | Cross-user access rejected by RLS | ✅ | live E2E #12–19 through PostgREST; test 005 #15–26 |
| 15 | Automated pgTAP / Jest security tests | ✅ | 103 pgTAP (real + offline) + 23 Jest |
| 16 | DB recreatable from scratch | ✅ | `npm run db:verify` (offline); hosted built from empty via 001–007 |

### Note on DoD #14 wording

PostgreSQL RLS does not raise an error on a disallowed `SELECT`; it filters the rows. Reads of another
member's records therefore return **zero rows**, and cross-member UPDATEs match **zero rows** (target verified
untouched). Every disallowed *write* or *privileged call* fails with **`42501 permission denied`**, including all anon access.

## Findings from live verification

| # | Finding | Class | Resolution |
|---|---|---|---|
| 1 | The raw invite token stayed in `auth.users` user metadata after signup (live E2E #24). Supabase Auth re-saves the user row after insert, overwriting the trigger's cleanup. | Bug | `006`: `BEFORE UPDATE` trigger always strips `invite_token`. Regression test 003 #20 fails without it. Now 24/24 live. |
| 2 | Supabase advisor: `app_private.prevent_audit_log_mutation` (verbatim baseline body) has a mutable `search_path`. | Backlog refinement | `007`: `ALTER FUNCTION … SET search_path = ''` (body unchanged). New test 001 #16 covers every function, not just SECURITY DEFINER ones. |
| 3 | Supabase advisor: 8 unindexed foreign keys. | Backlog refinement | `007`: covering indexes. |
| 4 | Test 002 compared permission arrays in order. `jsonb_agg(DISTINCT …)` orders by collation, which differs between hosted (locale) and PGlite (C). | Test bug | Compare as a set. The verbatim RPC is unchanged; the client only uses `includes()`. |
| 5 | Test 003 assumed an empty invitations table. | Test bug | Scoped to the test's own fixture. |

Advisor items accepted as-is:
- **"SECURITY DEFINER callable by authenticated"** on the four `public.*` RPCs is the baseline's wrapper pattern. Each wrapper checks `has_permission()` before delegating.
- **Leaked-password protection** and **MFA options** are Auth settings, not schema. See below.

## Hosted dev environment

- **Project:** `bacalsys-dev` (ref `sfptojkkmjggssqzyseo`, ap-northeast-1, $0/month).
  `jezsy-rbac-disposable` was **paused** to free a free-tier slot, as authorized. It was not deleted; deleting it is left to its owner.
- **Auth config** was pushed from `supabase/config.toml` (`supabase config push`). Changes on this dev project:
  email confirmation off, site URL `http://localhost:8081`, redirect `bacalsys://`, email resend limit 1s, OTP length 6.
  It also **disabled TOTP MFA enrollment**, an unintended side effect of pushing the local defaults. Re-enable it if dev needs MFA.
- **Dev President:** `president.dev@bacalsys.local`. The password was generated by
  `scripts/e2e/walking-skeleton.mjs --bootstrap-president` and exists only in the git-ignored `.env.hosted.local`.
  The account was promoted via SQL (actor `migration`). The documented local seed password is **not** used on hosted.
- **Test data:** each E2E run leaves throwaway members (`juan.<ts>@…`, `maria.<ts>@…`) with random passwords. pgTAP runs leave nothing (verified).
- **Migrations applied:** 001–007, identical to the repo. The reference seed was applied without the local-only President block.

## ADRs raised

- **ADR-001** (Proposed, awaiting acceptance): The roadmap's "Expo Router v4" is incompatible with SDK 57. Resolved to the SDK-57-bundled router, with routes under `src/app/`.
- **ADR-002** (Proposed, awaiting acceptance): The schema-scoped default-privilege revoke leaves PUBLIC EXECUTE in place. Added a global revoke. Confirmed on real Supabase (test 001 #6–7).

## Backlog refinements (no architecture or product-behavior change)

1. Table default privileges revoked for `anon`/`authenticated`, alongside function EXECUTE.
2. Audit hardening: `BEFORE TRUNCATE` trigger; `token_hash` redacted from invitation audit rows; audit triggers on identity/RBAC tables.
3. Sprint 1 RPCs, all following the public-wrapper → `app_private` pattern: `approve_member`, `list_pending_members` (e-mail joined from `auth.users`, not duplicated), `create_invitation` (raw token returned once).
4. Invitation claim semantics: the token is bound to the e-mail. A claim counts as officer pre-approval. Invalid, expired or reused tokens never block signup. The register screen accepts `bacalsys://register?invite=<token>`; InviteClaimScreen is still to be built.
5. New signups join the organization's default branch (single-org assumption).
6. **Review requested:** the permission-to-position matrix in `seed.sql`.
7. `web.output: "single"` (SPA); chunked SecureStore for sessions.
8. `006` and `007` (above).

## Known gaps and follow-ups

- **Native dev build** not compiled (`npx expo run:android` or `eas build --profile development`).
- **App UI click-through** not performed by the agent (it doesn't create accounts or enter passwords in a browser).
  Run `npm run web` with `.env.hosted.local` values, register, approve as the dev President, and sign back in.
- **Local Docker stack** never run on this machine: virtualization is disabled in firmware and WSL isn't installed.
- **Hosted dev Auth:** consider enabling leaked-password protection (Pro-plan feature) and re-enabling TOTP.
- Not in Sprint 1 scope: reject/suspend actions, InviteClaimScreen, invitation management UI, coach visibility helpers (Sprint 2).
- Unused template packages (`@expo/ui`, `expo-glass-effect`, `expo-symbols`, `expo-image`, `expo-device`, `expo-web-browser`).

## Re-running verification

```bash
npm run verify
npm run e2e:skeleton:hosted
```

With Docker available, also run `npm run db:start`, `npm run db:reset`, `npm run db:test` and `npm run e2e:skeleton` locally.
