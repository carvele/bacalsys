-- =============================================================================
-- Sprint 5 · Task 5.15 — service-side concurrency probes (hosted bacalsys-dev)
--
-- The overdue job and the occurrence generator are not callable by any client
-- role, and the SQL tooling used against the hosted project serializes calls, so
-- two ordinary SQL sessions can never truly overlap. These probes therefore use
-- pg_cron itself: a one-off probe job (which runs in its OWN background session)
-- takes the locks under test and holds them by keeping its transaction open
-- (pg_sleep), while a second SQL session races it. Each probe removes its job
-- (cron.unschedule) when done; afterwards cron.job holds only the two production
-- jobs.
--
-- What each probe proves (results are recorded in STATUS.md §8):
--   R3a  overdue job holds the occurrence lock  → START waits, then fails 22000 ("missed")
--   R3b  START holds the occurrence lock        → overdue job skips the row (SKIP LOCKED), never blocks
--   R5a  cancellation holds the assignment lock → generator waits, then creates nothing for it
--   R5b  generator holds the assignment share   → cancellation waits, then purges everything generated
--
-- Placeholders: <ATHLETE> <LEADER> <VERSION> <OCCURRENCE> <ASSIGNMENT>. The probe jobs
-- are started with a '1 seconds' schedule and unscheduled at the END of the racing
-- session (an unschedule inside a still-running racer takes effect at ITS commit).
-- =============================================================================

-- R3a --------------------------------------------------------------------------
-- 1) job (holds the occurrence row lock for 25s, inside one transaction):
SELECT cron.schedule('s5-probe-r3a', '1 seconds',
  $job$DO $x$ BEGIN PERFORM app_private.mark_overdue_assignments_as_missed(); PERFORM pg_sleep(25); END $x$;$job$);
-- 2) racer (an athlete STARTs the same overdue, still-upcoming occurrence):
CREATE FUNCTION pg_temp.race_start() RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE t0 timestamptz := clock_timestamp(); res text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '<ATHLETE>', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.start_workout_session('<VERSION>', gen_random_uuid(), '<OCCURRENCE>');
    res := 'STARTED';
  EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ': ' || SQLERRM;
  END;
  RESET ROLE;
  PERFORM cron.unschedule('s5-probe-r3a');
  RETURN jsonb_build_object('start_result', res, 'blocked_seconds', round(extract(epoch FROM clock_timestamp() - t0)::numeric, 2));
END $f$;
SELECT pg_temp.race_start();

-- R3b --------------------------------------------------------------------------
-- 1) job (a START takes and holds the occurrence lock for 25s):
SELECT cron.schedule('s5-probe-r3b', '1 seconds', $job$DO $x$ BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '<ATHLETE>', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.start_workout_session('<VERSION>', gen_random_uuid(), '<OCCURRENCE>');
  RESET ROLE;
  PERFORM pg_sleep(25);
END $x$;$job$);
-- 2) racer: run the real overdue job while the START is uncommitted; record what it did.
CREATE FUNCTION pg_temp.race_cron() RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE seen text; t0 timestamptz; moved integer; secs numeric;
BEGIN
  PERFORM pg_sleep(3);
  seen := (SELECT status FROM public.assignment_occurrences WHERE id = '<OCCURRENCE>');   -- still 'upcoming': START uncommitted
  t0 := clock_timestamp();
  moved := app_private.mark_overdue_assignments_as_missed();                              -- must return immediately, moving 0
  secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 3);
  PERFORM pg_sleep(26);
  PERFORM cron.unschedule('s5-probe-r3b');
  RETURN jsonb_build_object('seen', seen, 'moved', moved, 'seconds', secs,
    'final', (SELECT status FROM public.assignment_occurrences WHERE id = '<OCCURRENCE>'));   -- 'in_progress'
END $f$;
SELECT pg_temp.race_cron();

-- R5a --------------------------------------------------------------------------
-- 1) job (a leader's CANCEL holds the assignment FOR UPDATE for 25s):
SELECT cron.schedule('s5-probe-r5a', '1 seconds', $job$DO $x$ BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '<LEADER>', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.cancel_workout_assignment('<ASSIGNMENT>', gen_random_uuid());
  RESET ROLE;
  PERFORM pg_sleep(25);
END $x$;$job$);
-- 2) racer: the real generator must wait for the cancel, then skip the assignment.
--    SELECT app_private.generate_recurring_occurrences();  -- time it; afterwards count the assignment's occurrences (0)

-- R5b --------------------------------------------------------------------------
-- 1) job (the generator takes and holds FOR SHARE on every active recurring assignment for 45s):
SELECT cron.schedule('s5-probe-r5b', '1 seconds',
  $job$DO $x$ BEGIN PERFORM app_private.generate_recurring_occurrences(); PERFORM pg_sleep(45); END $x$;$job$);
-- 2) racer: a leader cancels the assignment; it waits for the generator, then deletes every occurrence
--    (audit new_values.deleted_occurrences = original rows + the rows the generator just created).
