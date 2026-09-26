This is an Expo/React Native mobile application. Prioritize mobile-first patterns, performance, and cross-platform compatibility.

## Expo has changed — do not trust your training data

Expo ships breaking changes every SDK release. APIs you remember are likely renamed, moved, or removed. Before writing any code that touches an Expo, EAS, or React Native API:

1. Read the major version of the `expo` package in `package.json`.
2. Fetch the matching versioned docs: `https://docs.expo.dev/versions/v<major>.0.0/`
3. For anything else, fetch https://docs.expo.dev/llms.txt — an index of all Expo docs with corrections to common LLM misconceptions. Follow its links to the specific page you need; never answer from memory.

## Commands

Use `bunx` instead of `npx` if the project uses bun (`bun.lock` present).

```bash
npx expo install <package>  # ALWAYS use instead of npm/yarn/pnpm/bun add — resolves SDK-compatible versions
npx expo start              # start the dev server
npx expo lint               # lint
npx tsc --noEmit            # typecheck
npx expo-doctor             # diagnose dependency and config issues
npx expo install --fix      # fix incompatible package versions
```

Run lint and typecheck before declaring any task done.

## Navigation & Routing

- Use **Expo Router** for all navigation. Routes live in `src/app/` — every file there is a screen, `_layout.tsx` files define navigators. Keep non-route code (components, hooks, utils) outside `src/app/`.
- Import `Link`, `router`, and `useLocalSearchParams` from `expo-router`.
- Docs: https://docs.expo.dev/router/introduction.md

## Building with EAS

Use EAS to build, sign, and submit the app in the cloud (`eas build`, `eas submit`) and to ship over-the-air updates (`eas update`) — no local Xcode or Android Studio required. Run EAS CLI as `bunx eas-cli <command>` in Bun projects, or `npx eas-cli@latest <command>` otherwise; substitute that for bare `eas` in docs examples.
Docs: https://docs.expo.dev/eas/index.md

## Rules

- If `ios/` and `android/` directories do not exist, they are generated (Continuous Native Generation). Never create or edit them by hand — configure native behavior in `app.json` and config plugins.
- Expo Go only includes its bundled native modules. After adding a library with native code, the app needs a development build: `npx expo run:ios|android` locally, or `eas build --profile development`.
- Prefer recommended Expo modules over third-party libraries, and check your available skills before adding dependencies. Docs: https://docs.expo.dev/versions/latest/index.md

## BaCalSys project rules

- **Baseline:** BaCalSys Implementation Roadmap v1.2 is frozen. Do not redesign the architecture. Classify every
  change as Bug, Backlog Refinement, or ADR. ADRs go in `docs/adr/ADR-xxx.md` *before* coding.
- **Database:** add new migrations as `supabase/migrations/NNN_name.sql`. Never edit an applied migration.
  Every SECURITY DEFINER function pins `SET search_path = ''` and schema-qualifies everything.
  Privileged writes go through `public.*` wrappers → `app_private.*_internal`. Grant every table and function explicitly (ADR-002).
- **Verify before declaring done:** `npm run verify` (typecheck + lint + Jest + offline pgTAP rebuild), then
  `npm run e2e:skeleton:hosted` against the hosted dev project. With Docker available, also `npm run db:test` and
  `npm run e2e:skeleton` locally. UI or native changes also need a web check and, per sprint gate, an Android dev-client boot.
- **Client route guards are UX only.** Authorization lives in RLS and `app_private.has_permission()`.
- Sprint status, acceptance and findings: `docs/sprints/<sprint>/` (STATUS.md, ACCEPTANCE.md, findings/).

## Planner / Executor / Reviewer workflow

BaCalSys is built by three AI tools with fixed roles. The product owner relays work between them.

| Role | Tool | Owns |
|---|---|---|
| **Planner** | Antigravity | Architecture, the frozen roadmap, backlog, task specs, ADR decisions |
| **Executor** | Claude | Code, migrations, commands, UI, automated tests, commits, evidence |
| **Reviewer** | ChatGPT | Architecture audits, security reviews, gate approvals |

**Executor rules**

- **Build from the spec.** Implement the Planner's task specs and acceptance criteria. Don't re-plan the architecture or
  add scope. If a spec conflicts with the baseline or can't be met as written, raise an ADR with status **Proposed**
  (`docs/adr/`, using `ADR-000-template.md`) and send the decision back to the Planner. An ADR becomes **Accepted** only
  when the product owner relays that decision. Never change the baseline silently.
- **Classify every discovery.** Anything found during execution is a Bug, Backlog Refinement, or ADR. Record it as one file
  per finding in `docs/sprints/<sprint>/findings/` (symptom, root cause, class, fix, regression test). Fix bugs with a
  failing-first regression test, and use forward-only migrations.
- **Produce evidence, not assertions.** Each sprint delivers `STATUS.md` (engineering record), `ACCEPTANCE.md` (one row per
  gate item with evidence: commands run, test counts, CI run links, screenshots) and `findings/`. State what was
  **not** verified as plainly as what was. A check that wasn't run is marked pending or waived, never passed.
- **Reviewer gates.** A gate is closed only when the product owner relays the Reviewer's approval. The Executor never
  self-approves, never marks a checklist item done without evidence, and tags a sprint (`sprint-NN-accepted`) only
  after every item is satisfied or explicitly waived.
- **Stay in your lane.** Hands-on steps the Executor must not perform, such as creating accounts or entering passwords in a
  browser, deleting production data, or logging into third-party services, go back to the product owner as short,
  exact instructions.

**Handoff artifacts**

| From → To | Artifact |
|---|---|
| Planner → Executor | Task spec + Definition of Done; ADR decisions |
| Executor → Planner | Proposed ADRs; open decisions (e.g. `findings/permission-matrix-review.md`) |
| Executor → Reviewer | `STATUS.md`, `ACCEPTANCE.md`, `findings/`, CI links, the git diff or tag |
| Reviewer → Executor | Gate checklist, required fixes, approvals |
