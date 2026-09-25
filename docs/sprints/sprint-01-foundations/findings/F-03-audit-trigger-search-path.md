# F-03: Verbatim audit-immutability trigger function had a mutable search_path

- **Class:** Backlog refinement (hardening)
- **Found by:** Supabase database advisor, lint 0011 (hosted)

**Symptom:** `app_private.prevent_audit_log_mutation()`, copied verbatim from the roadmap, lacks `SET search_path`.
The existing test only covered SECURITY DEFINER functions, so it missed this plain trigger function.

**Fix:** `007_advisor_hardening.sql` runs `ALTER FUNCTION … SET search_path = ''`, leaving the baseline body unchanged.
Regression: new test `001_security_baseline.test.sql` #16 covers *every* BaCalSys function (fails without 007).
