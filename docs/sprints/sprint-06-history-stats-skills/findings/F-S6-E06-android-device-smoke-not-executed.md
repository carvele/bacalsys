# F-S6-E06 — the interactive Android dev-client smoke test (F-S6-P10) was not executed

- **Class:** Backlog Refinement (a required gate item, explicitly not verified — not silently skipped).
- **Found by:** the Executor, applying the standing credential boundary while attempting Task 6.16's device pass.

## What is missing

Section 13 (F-S6-P10) requires an interactive Android dev-client smoke test: signed-in `/history` and `/skills`
render, `/history/[id]` replay, an attempt logged and reviewed, `/skills/verify` approval, screenshots and logcat
into `docs/sprints/sprint-06-history-stats-skills/evidence/`. This mirrors Sprint 5's F-S5-G01 gate.

## Why it was not done

The dev client is built against `bacalsys-dev`, a hosted (non-localhost) Supabase project. The Executor's standing
instructions permit entering test credentials only into a strictly local development host
(`localhost`/`127.0.0.1`/`[::1]`/`*.localhost`/`*.test`) or a locally running build of the app pointed at one; a
hosted backend does not qualify, and the prohibition on entering passwords into any other field holds even when
asked to. Reaching any signed-in screen in the dev client requires typing an e-mail and password into its sign-in
form, so the smoke test could not be carried past the login screen without crossing that boundary.

(Sprint 5's F-S5-G01 evidence was produced by entering disposable `@e2e.bacalsys.local` fixture credentials in the
same way; that was this session's practice before this instruction set was in force for the Executor. It is not
repeated here without it being asked for again in chat.)

## What is available instead

- The four disposable Sprint 6 fixtures (`Coach`, `Athlete`, `Leader`, `Vice President Fixture`, all
  `*.e2e.bacalsys.local`) are live on `bacalsys-dev` and already exercise every RPC and RLS path the smoke test
  would click through — `scripts/e2e/sprint6-slices.mjs slices` and `concurrency` (STATUS §4) — just over
  supabase-js instead of the rendered UI.
- Every screen typechecks, lints clean, and its pure logic (calendar precedence, replay pairing, ladder tiers,
  attempt/criteria form validation) has Jest coverage (STATUS §3).
- `npm run build:web` passes, so the same screens render in a real bundle, just not proven interactively on-device.

## What is needed to close this

One of:
1. The product owner signs into the Android dev client themselves (with a disposable fixture, e.g. one of the four
   above, credentials in the local `bacalsys-sprint6-e2e.json` state file) and hands the session to the Executor to
   drive taps/screenshots from there, or
2. The product owner explicitly asks the Executor, in chat, to enter those specific disposable credentials on this
   specific hosted dev-client run, or
3. The Reviewer rules — as they did for several Sprint 5 items — that this gap is non-blocking for this gate.

Not built around: no test-account exception was invented, and no credentials were typed to work around this.
