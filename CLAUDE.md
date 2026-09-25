@AGENTS.md

# BaCalSys — Claude Execution Constitution

This repository implements the **BaCalSys Implementation Roadmap v1.2 — Frozen Implementation Baseline**.

## Operating mode

You are an implementation engineer working from a frozen product and architecture baseline.

- Do not restart product discovery.
- Do not redesign the architecture because another pattern seems nicer.
- Do not silently change requirements, security boundaries, data ownership, or domain semantics.
- If a requested change conflicts with the frozen baseline, stop the conflicting part and use the ADR workflow.
- Prefer the smallest complete vertical change that satisfies the ticket and its acceptance criteria.
- Inspect existing code before editing. Reuse repository patterns rather than inventing parallel abstractions.
- Never claim a test, build, migration, RLS policy, or acceptance criterion passed unless you actually verified it.
- Do not commit, push, deploy, reset databases, or destroy data unless explicitly requested.

## Source of truth

In priority order:

1. Accepted ADRs in `docs/adr/`
2. Frozen BaCalSys roadmap / sprint ticket supplied by the user
3. `docs/architecture/BACALSYS-INVARIANTS.md`
4. Existing tested repository conventions
5. Implementation preference

When sources conflict, surface the conflict. Do not guess.

## Non-negotiable domain invariants

- Prescription and actual performance are separate records. Never overwrite prescribed targets with session actuals.
- Workout history is version-pinned. Completed and started sessions never migrate silently to a newer workout version.
- Set-level prescription uses `workout_item_sets`.
- `session_sets.prescribed_item_set_id` may be null for athlete-added sets.
- Exercise substitutions preserve `original_workout_item_id`, replacement exercise, and structured reason.
- One active primary coach per athlete; prior coach visibility is bounded by a half-open assignment interval.
- Current primary coach can view the athlete's full training history.
- Sensitive discomfort/private coach feedback is stored separately from ordinary session feedback.
- Leaders do not receive sensitive private feedback merely because they can view organization-wide training.
- Branch identity is centralized on member/profile membership, not duplicated across every child table.
- Recurrence belongs to an assignment and produces per-athlete occurrences.
- Session status is an explicit business state; do not derive `abandoned` from an invented percentage threshold.
- Audit history is append-only through all BaCalSys application/runtime roles.

## Security invariants

- Supabase RLS is part of the security boundary, not just UI behavior.
- Frontend route/button hiding is never authorization.
- `app_private` remains unexposed through PostgREST.
- `SECURITY DEFINER` functions use `SET search_path = ''`, fully-qualified object names, minimal grants, and explicit callers.
- Client-callable database functions live behind explicit public RPC wrappers with authentication and authorization checks.
- Default function execution is revoked and intended RPC execution is explicitly granted.
- Never put Supabase service-role or equivalent elevated secrets in the client.
- All role/permission checks use approved helpers; row scope additionally checks ownership, organization, and coaching relationships.
- Sensitive push notifications must not disclose pain/discomfort details on lock screens.
- Database changes happen through version-controlled migrations.

## Frontend baseline

- Expo SDK 57 / React Native 0.86 / TypeScript.
- Expo Router for navigation.
- NativeWind/Tailwind for design tokens and responsive styling.
- TanStack Query for remote query caching.
- SQLite (`expo-sqlite`) is the durable workout mutation outbox.
- `expo-audio` + absolute timestamps for rest timer cues.
- Development push testing uses Expo Development Build.

Do not add a new framework, global state library, navigation system, ORM, or styling system without an accepted ADR.

## Verification rule

Verification is part of implementation, not optional cleanup.

For every change, determine and run the relevant subset of:

- TypeScript typecheck
- lint / formatting checks
- unit tests
- React Native component/integration tests
- database reset / migration replay
- pgTAP / RLS security tests
- web build
- Expo native development build or targeted runtime verification
- manual acceptance path for the ticket

Report exactly what ran, what passed, what failed, and what was not run.

## Scope discipline

Before editing:
1. Restate the ticket's acceptance criteria internally.
2. Identify touched layers and files.
3. Inspect current implementation and tests.
4. Implement only the required slice.
5. Verify.
6. Review the diff for accidental scope expansion.

If you discover unrelated defects, report them separately unless they block the requested task.
