# F-02: Raw invite token restored into user metadata by Supabase Auth

- **Class:** Bug
- **Found by:** live walking-skeleton E2E, check #24 (hosted `bacalsys-dev`)
- **Not reproducible offline:** the PGlite auth shim has no GoTrue

**Symptom:** after an invited signup, `auth.users.raw_user_meta_data` still held `invite_token`.

**Root cause:** `handle_new_user()` stripped the key in an AFTER INSERT trigger, but GoTrue saves the user row again
~16 ms later in the same signup flow, writing its in-memory metadata (token included) back.
`postgres` *can* update `auth.users`, so this was not a privilege problem.

**Fix:** migration `006_strip_invite_token_on_update.sql`, a `BEFORE UPDATE` trigger that always removes the key.
Regression: `003_registration_invitations.test.sql` #20, which simulates the re-save and fails without 006.
The live E2E then passed 24/24.

**Impact had it shipped:** low. The token is single-use and already claimed. This is data hygiene, not access control.
