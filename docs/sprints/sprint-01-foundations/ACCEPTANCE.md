# Sprint 1: Final Acceptance

Checklist set by the product owner on 2026-09-25. An item is checked only with the evidence beside it.

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Accept ADR-001 | ✅ | `docs/adr/ADR-001-…md`: Status **Accepted**, 2026-09-25 |
| 2 | Accept ADR-002 | ✅ | `docs/adr/ADR-002-…md`: Status **Accepted**, 2026-09-25 |
| 3 | Upgrade GitHub Actions to Node 24-compatible versions | ✅ | checkout v7, setup-node v7, deploy-pages v5 (`using: node24` read from each release's `action.yml`); upload-pages-artifact v5 (composite → upload-artifact v7). `include-hidden-files: true` keeps `.nojekyll` (v4+ drops dotfiles). |
| 4 | Rerun full CI successfully | _pending_ | _filled in after push_ |
| 5 | Build Android development client | ✅ | `expo run:android` (debug, `expo-dev-client`): **BUILD SUCCESSFUL** in 29m 53s (Gradle 9.3.1, compileSdk/targetSdk 36, minSdk 24, NDK 27.1, Kotlin 2.1.20). |
| 6 | Install and boot Android development client | ✅ | Installed `ph.bacalsys.app` 0.1.0 on the Pixel 4 AVD (Android 16, x86_64, WHPX-accelerated). Dev client runtime `exposdk:57.0.0`; JS `Running "main"` on Fabric (new architecture); no JS errors or `AndroidRuntime` crashes in logcat. Login screen renders with design tokens; tapping *Create an account* navigates to Register. Surfaced and fixed [F-08](findings/F-08-link-classname-native.md). |
| 7 | Confirm hosted Supabase connectivity from Android | ✅ (network + config) | The emulator opens TCP 443 to `sfptojkkmjggssqzyseo.supabase.co`; the served Android bundle contains the hosted URL (1×) and no local-stack URL (0×). **Not yet exercised:** an in-app authenticated request on Android, which requires signing in on the device. The same client code is proven on web and by the API E2E. |
| 8 | Build/boot iOS development client **or** document waiver | ⚠️ Waived | [W-01](findings/W-01-ios-environment-waiver.md): no macOS, and EAS needs the owner's Expo login. The `development-simulator` profile is ready in `eas.json`. |
| 9 | One real UI walking-skeleton click-through | _pending: needs the product owner_ | See "Click-through" below |
| 10 | Review permission-to-position seed matrix | ✅ | [findings/permission-matrix-review.md](findings/permission-matrix-review.md); three decisions open (D1–D3), none blocking Sprint 1 |
| 11 | pgTAP tests for seeded permission boundaries | ✅ | `supabase/tests/006_permission_matrix.test.sql`: 19/19 offline **and** on hosted Supabase; drift guard confirmed to catch a planted typo |
| 12 | `npm run verify` | ✅ | typecheck, lint (incl. F-08 rule), Jest 27/27, pgTAP 122/122 on a fresh DB |
| 13 | `npm run e2e:skeleton:hosted` | ✅ | 24/24 against `bacalsys-dev` |
| 14 | Tag / report Sprint 1 as ACCEPTED | _pending_ | only after items 1–13 |

Also done during acceptance, as requested:
- **TOTP MFA** re-enabled on `bacalsys-dev` (`[auth.mfa.totp]` in `config.toml`, pushed); the Pages URL was added to the Auth redirect list.
- Leaked-password protection stays off: a documented environment limitation (requires a paid plan).

## Click-through

Nothing here needs a password shared with the agent.

1. **Device A:** open https://carvele.github.io/bacalsys/ → *Create an account* with a throwaway address (any
   `name@example.com`; e-mail confirmation is off on the dev project). Expect **Awaiting approval**.
2. **Your officer account:** register a second account (Device B, or a private window) and tell the agent its e-mail.
   The agent promotes it to President via SQL (actor `migration`, audited), exactly like the seed.
3. **Device B:** sign in → *Review member applications* → approve Device A's account → *Confirm*.
4. **Device A:** tap *Check status* (or wait up to 30 s). Expect **Athlete Home** with the *Athlete* chip and
   **no** *Officer tools* card.
5. **Device A (protected navigation):** open https://carvele.github.io/bacalsys/member-approvals directly.
   Expect to land back on Athlete Home, with no approval queue shown.

Record the result (pass/fail per step, device/browser used) here.

## Hosted E2E test-data cleanup (strategy, not a blocker)

Each hosted E2E run leaves two throwaway members (`juan.<ts>@bacalsys.local`, `maria.<ts>@bacalsys.local`).
`scripts/e2e/cleanup-hosted.sql` removes E2E identities older than 24 h that match only that exact pattern. Deletions
cascade to profiles and positions, and the audit log keeps the history. Run it deliberately, for example before each
sprint's acceptance. It is not automated, because it permanently deletes rows.
