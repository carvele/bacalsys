# F-S6-E04 — `get_athlete_summary_metrics` re-checks authorization itself (defense in depth)

- **Class:** Bug (authorization bypass in the frozen predicate text, closed before any hosted apply). Not reachable
  through the app's own UI — no screen calls the delegate directly — but reachable by any authenticated caller
  through PostgREST's `/rest/v1/rpc/get_athlete_summary_metrics` regardless of what the client renders.
- **Found by:** the Executor, writing Task 6.6 and noticing the delegate is `GRANT EXECUTE ... TO authenticated`
  (required so the `SECURITY INVOKER` public wrappers can call it, per F-S6-P15) with no authorization check of its
  own in the frozen listing — unlike `get_session_replay_internal`, which does check `can_view_workout_session`
  itself before reading anything.

## Symptom (as specified)

Section 13's `app_private.get_athlete_summary_metrics(p_athlete_id, p_start_date, p_end_date)` listing computes and
returns the summary directly from `p_athlete_id`, trusting that only `get_my_athlete_summary` (always passes
`auth.uid()`) and `get_athlete_summary` (checks `can_view_athlete_training` before calling it) ever reach it. That
is true **through the app**, but the function is independently `GRANT`ed to `authenticated` (necessary for the
`SECURITY INVOKER` wrappers to work at all), so any authenticated caller who discovered its name could call
`app_private.get_athlete_summary_metrics('<any-athlete-uuid>', NULL, NULL)` directly via PostgREST and read that
athlete's full adherence and volume history, bypassing both wrappers' authorization entirely.

## Fix

`app_private.get_athlete_summary_metrics`
([20260929000006_training_history_and_statistics_rpcs.sql](../../../../supabase/migrations/20260929000006_training_history_and_statistics_rpcs.sql))
re-checks `app_private.can_view_athlete_training(p_athlete_id)` itself at the top, raising `42501` if it fails —
the same defense the roadmap already applies to `get_session_replay_internal`. The two public wrappers are
unaffected; a legitimate caller sees no behavioral change.

## Verification

`supabase/tests/016_training_history_and_statistics.test.sql` assertion #42: calling the delegate directly, as a
peer athlete, for another athlete's summary is refused (`42501`).
