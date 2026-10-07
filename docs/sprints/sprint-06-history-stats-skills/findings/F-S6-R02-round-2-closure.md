# F-S6-R02 — Round 2 Reviewer Gate Closure: Android Post-Fix Replay Evidence & Hosted Migration Reconcile

- **Class:** Backlog Refinement / Verification & Governance Reconciliation.
- **Found by:** ChatGPT (Reviewer) during Sprint 6 Round 2 gate review.
- **Relayed to:** Antigravity (Planner + Executor).

## Symptom

1. **Android Replay Screenshot Artifact:**
   `android-02-session-replay.png` committed in Round 2 showed a development-build LogBox notification banner at the bottom (white bar with red `!` badge) from the pre-fix execution where F-S6-E07 (duplicate key) was discovered, rather than a clean post-fix capture.
2. **Logcat Filtering:**
   `android-smoke.log` in Round 2 contained broad system logs rather than strictly app-filtered logs for `ph.bacalsys.app`.
3. **Hosted Migration History Desynchronization:**
   Hosted Supabase (`sfptojkkmjggssqzyseo`) recorded both `20260929000008` and an orphan `20260929140215` (both named `athlete_skill_status_fk_index`) in `supabase_migrations.schema_migrations`. Git only contains canonical `20260929000008_athlete_skill_status_fk_index.sql`.

## Root Cause

1. The previous screenshot was captured during initial testing right before the F-S6-E07 fix was applied.
2. The previous logcat command was captured from a system buffer dump without filtering specifically to the app process PID.
3. The duplicate migration entry on hosted was left over from a previous interrupted run where `20260929140215` had been recorded directly into the migration history.

## Fix & Closure

1. **Clean Android Session Replay Re-run:**
   - Navigated the physical Android device (`Infinix X6880`, `13195704AS018838`, Android 14) running Expo SDK 57 dev client via deep link `bacalsys://history/ee613c48-a96f-4f1f-9af1-b23cc94497a0`.
   - Captured new `android-02-session-replay.png`.
   - Visually inspected: zero LogBox notification, zero warning banners, clean rendering of prescribed vs actual sets (Push-up set 1 extra + set 1 skipped, Plank set 1 skipped).
2. **Proper App-Filtered Logcat & Crash Buffer Evidence:**
   - Filtered logcat strictly by app process PID (`12263` for `ph.bacalsys.app`): `adb logcat --pid=12263 -d`.
   - Checked crash buffer: `adb logcat -b crash -d` -> empty (0 crashes recorded).
   - Saved clean output to `docs/sprints/sprint-06-history-stats-skills/evidence/android-smoke.log`.
3. **Hosted Migration History Reconcile:**
   - Reconciled hosted migration tracking table `supabase_migrations.schema_migrations` on project `sfptojkkmjggssqzyseo`: removed orphan `20260929140215`.
   - Verified that `20260929000008` is the top migration, exactly matching Git repository `supabase/migrations/20260929000008_athlete_skill_status_fk_index.sql` 1:1.
   - Verified that composite index `athlete_skill_status_skill_progression_idx (skill_id, current_progression_id)` remains intact, valid, and indexed in PostgreSQL.
