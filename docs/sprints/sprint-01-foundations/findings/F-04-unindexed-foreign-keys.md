# F-04: Eight foreign keys without covering indexes

- **Class:** Backlog refinement (performance)
- **Found by:** Supabase database advisor, lint 0001 (hosted)

**Fix:** `007_advisor_hardening.sql` adds covering indexes on `member_positions`, `user_system_roles` and `invitations`
(`position_id`, `role_id`, `assigned_by`, `ended_by`, `claimed_by`, `preassigned_position_id`).
This keeps FK checks and `ON DELETE SET NULL/RESTRICT` cascades from scanning whole tables. Verified cleared on re-run.
