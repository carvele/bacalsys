# BaCalSys — Bataan Calisthenics System

Training and coaching platform for the Bataan calisthenics community. One Expo
(SDK 57) codebase serves Android, iOS and Web, backed by Supabase (Postgres, Auth, RLS).

- **Baseline:** BaCalSys Implementation Roadmap v1.2 (frozen). Deviations are recorded as ADRs in [`docs/adr/`](docs/adr).
- **Live web build:** https://carvele.github.io/bacalsys/ (deployed from `main` by `.github/workflows/web.yml`).
- **Current state:** Sprint 1, walking skeleton. See [`docs/sprint-1/README.md`](docs/sprint-1/README.md).

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Node.js | ≥ 22.13 | everything |
| Supabase CLI | ≥ 2.115 | local backend |
| Docker Desktop | current | `supabase start`, `supabase test db`, `db:types` |
| Android Studio / Xcode | current | local dev-client builds (or use EAS) |

## First run

```bash
npm install
cp .env.example .env.local          # then paste the anon/publishable key from `supabase status`
npm run db:start                    # local Supabase (Docker)
npm run db:reset                    # apply migrations 001–005 + seed.sql from scratch
npm run web                         # or: npm run android / npm run ios (dev client)
```

Local seed President (development only): `president@bacalsys.local` / `BaCalSys-Local-President-1`.

## Scripts

| Script | What it does |
|---|---|
| `npm run web` / `android` / `ios` | Run the app (native uses the Expo dev client) |
| `npm run typecheck` / `lint` / `test` | TypeScript, ESLint, Jest unit tests |
| `npm run db:verify` | **No Docker needed.** Builds a fresh Postgres (PGlite), applies all migrations + seed, runs every pgTAP file |
| `npm run db:test` | Canonical pgTAP run against the local Supabase stack |
| `npm run db:types` | Regenerate `src/types/database.ts` from the local schema |
| `npm run e2e:skeleton` | Live walking-skeleton check through Auth + PostgREST (local stack) |
| `npm run e2e:skeleton:hosted` | Same check against the hosted dev project (needs git-ignored `.env.hosted.local`) |
| `npm run build:web` / `build:web:pages` | Production web export (root path / GitHub Pages sub-path) + bundle secret check |
| `npm run serve:web` | Serve `dist/` locally with SPA fallback |
| `npm run verify` | typecheck + lint + Jest + db:verify |

## Layout

```
src/app/                 Expo Router routes (ADR-001: src/app is the route root)
  (auth)/                login, register, pending-approval
  (athlete)/             Athlete Home
  (officer)/             member approvals (requires members:approve)
src/features/auth/       session store (Zustand), access-context hook, route resolution
src/lib/                 Supabase client, secure session storage, TanStack Query lifecycle
supabase/migrations/     001 security baseline … 005 RLS policies
supabase/tests/          pgTAP suites
scripts/db/              offline verification harness (PGlite + platform/pgTAP shims)
scripts/e2e/             live walking-skeleton script
docs/adr/                architectural decision records
```

## Security model (short version)

- `app_private` holds SECURITY DEFINER authorization logic and is never exposed through the Data API.
- Clients never write privileged tables directly. Approval, invitations and position changes go through
  `public.*` RPC wrappers that call `app_private.has_permission()` and then delegate.
- New functions and tables are not callable or readable by `anon`/`authenticated` unless granted
  explicitly (see ADR-002).
- Every table has RLS enabled. The audit log is append-only for every runtime role.
- The Expo Router guards are UX only. Authorization is always enforced in the database.
