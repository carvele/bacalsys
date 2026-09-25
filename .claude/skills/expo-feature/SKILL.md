---
name: expo-feature
description: Implement BaCalSys Expo/React Native features using project navigation, styling, query, accessibility, and cross-platform conventions.
---

# BaCalSys Expo Feature

Use for screens, components, hooks, routing, forms, mobile/web responsive behavior, and native Expo integrations.

## Baseline

- Expo SDK 57
- TypeScript
- Expo Router
- NativeWind/Tailwind design tokens
- TanStack Query for remote query caching
- SQLite for durable offline workout mutations

Do not introduce competing navigation, styling, server-state, or persistence frameworks without an accepted ADR.

## Workflow

1. Inspect adjacent screens/components and existing design primitives.
2. Reuse patterns and tokens.
3. Separate:
   - remote server data
   - local ephemeral UI state
   - durable offline mutation state
4. Make layout usable on phone and responsive web.
5. Protect privileged routes in UI, but rely on backend authorization for security.
6. Handle loading, empty, error, offline, and retry states.
7. Add accessible labels, touch targets, keyboard behavior, and form error messaging.
8. Avoid unnecessary platform forks; where required, isolate them.

## Expo/native integrations

- Use absolute timestamps for timers that must survive backgrounding.
- Use `expo-audio` for audio cues.
- Remote push behavior must be verified in an Expo Development Build.
- Never put sensitive pain/discomfort details in push notification text.

## Verification

Run relevant TypeScript, lint, component tests, web verification, and targeted native verification.

Do not claim native behavior works solely because web passes.
