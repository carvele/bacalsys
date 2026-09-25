# ADR-001: Expo Router version pin and route root directory

- **Status**: Accepted (pending product-owner acknowledgement)
- **Date**: 2026-09-25
- **Sprint**: 1 (Task 1.1)
- **Classification**: ADR (baseline text is internally inconsistent; resolution chosen below)

## Context

Roadmap v1.2 specifies two things that cannot both be true:

1. Frontend: **Expo SDK 57** (React Native 0.86).
2. Task 1.1: "Initialize Expo SDK 57 project with TypeScript strict mode and **Expo Router v4**."

Since SDK 55, `expo-router` is versioned in lock-step with the SDK. The SDK 57
template (`create-expo-app --template default@sdk-57`) pins `expo-router ~57.0.23`.
Expo Router v4 belongs to SDK 52 and is not compatible with React Native 0.86.

In addition, the roadmap's Sprint 1 task list writes route paths as
`app/(auth)/login.tsx`, while the SDK 57 template places routes under
`src/app/` (the `app/` root is still supported, but `src/app/` is the current default).

## Decision

- Use the **`expo-router` release that ships with SDK 57** (`~57.0.x`), installed with
  `npx expo install`. SDK 57 is the binding constraint, because the rest of the stack
  (React Native 0.86, Reanimated 4, NativeWind 4.2.7) depends on it.
- Keep typed routes (`experiments.typedRoutes: true`) as the baseline requires.
- Keep route files under **`src/app/`**. The roadmap's route paths map one-to-one:
  `app/(auth)/login.tsx` → `src/app/(auth)/login.tsx`, and so on. Group names,
  file names and URL paths are unchanged.

## Consequences

- No product behavior or architecture change. The route groups `(auth)`, `(athlete)`
  and `(officer)` are implemented exactly as named in the roadmap.
- Protected routing uses `Stack.Protected` (available in this router version) as a
  client-side UX guard only. Authorization is still enforced server-side by RLS and
  `app_private` functions.
- Future roadmap references to "Expo Router v4" should be read as "the Expo Router
  release bundled with the pinned Expo SDK".
