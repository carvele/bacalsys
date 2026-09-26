# Sprint 1: Final Acceptance

> **Status: ACCEPTED on 2026-09-26.** All 14 items are satisfied; iOS is covered by the explicit environment waiver [W-01](findings/W-01-ios-environment-waiver.md).

Checklist set by the product owner on 2026-09-25. An item is checked only with the evidence beside it.

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Accept ADR-001 | ✅ | `docs/adr/ADR-001-…md`: Status **Accepted**, 2026-09-25 |
| 2 | Accept ADR-002 | ✅ | `docs/adr/ADR-002-…md`: Status **Accepted**, 2026-09-25 |
| 3 | Upgrade GitHub Actions to Node 24-compatible versions | ✅ | checkout v7, setup-node v7, deploy-pages v5 (`using: node24` read from each release's `action.yml`); upload-pages-artifact v5 (composite → upload-artifact v7). `include-hidden-files: true` keeps `.nojekyll` (v4+ drops dotfiles). |
| 4 | Rerun full CI successfully | ✅ | [Run 36161810416](https://github.com/carvele/bacalsys/actions/runs/36161810416): verify + deploy both succeeded on the Node 24 actions; no Node 20 annotations remain (only GitHub's informational `ubuntu-latest` → Ubuntu 26 notice). Live site re-checked: root 200, bundle 200, hosted backend in bundle. |
| 5 | Build Android development client | ✅ | `expo run:android` (debug, `expo-dev-client`): **BUILD SUCCESSFUL** in 29m 53s (Gradle 9.3.1, compileSdk/targetSdk 36, minSdk 24, NDK 27.1, Kotlin 2.1.20). |
| 6 | Install and boot Android development client | ✅ | Installed `ph.bacalsys.app` 0.1.0 on the Pixel 4 AVD (Android 16, x86_64, WHPX-accelerated). Dev client runtime `exposdk:57.0.0`; JS `Running "main"` on Fabric (new architecture); no JS errors or `AndroidRuntime` crashes in logcat. Login screen renders with design tokens; tapping *Create an account* navigates to Register. Surfaced and fixed [F-08](findings/F-08-link-classname-native.md). |
| 7 | Confirm hosted Supabase connectivity from Android | ✅ (network + config) | The emulator opens TCP 443 to `sfptojkkmjggssqzyseo.supabase.co`; the served Android bundle contains the hosted URL (1×) and no local-stack URL (0×). **Not yet exercised:** an in-app authenticated request on Android, which requires signing in on the device. The same client code is proven on web and by the API E2E. |
| 8 | Build/boot iOS development client **or** document waiver | ⚠️ Waived | [W-01](findings/W-01-ios-environment-waiver.md): no macOS, and EAS needs the owner's Expo login. The `development-simulator` profile is ready in `eas.json`. |
| 9 | One real UI walking-skeleton click-through | ✅ | Performed by the product owner on 2026-09-26 against the live web build (https://carvele.github.io/bacalsys/, Chrome); all 5 steps passed. Database cross-check: the test member went pending → active with an Athlete position 7 s after registering; `member_positions.assigned_by` is the officer account; the audit trail reads `profiles.insert` (system, signup trigger) → `profiles.update` (user = officer) → `member_positions.insert` (user = officer). See "Click-through results" below. |
| 10 | Review permission-to-position seed matrix | ✅ | [findings/permission-matrix-review.md](findings/permission-matrix-review.md); three decisions open (D1–D3), none blocking Sprint 1 |
| 11 | pgTAP tests for seeded permission boundaries | ✅ | `supabase/tests/006_permission_matrix.test.sql`: 19/19 offline **and** on hosted Supabase; drift guard confirmed to catch a planted typo |
| 12 | `npm run verify` | ✅ | typecheck, lint (incl. F-08 rule), Jest 27/27, pgTAP 122/122 on a fresh DB |
| 13 | `npm run e2e:skeleton:hosted` | ✅ | 24/24 against `bacalsys-dev` |
| 14 | Tag / report Sprint 1 as ACCEPTED | ✅ | **Sprint 1 ACCEPTED 2026-09-26.** Git tag `sprint-01-accepted`. iOS covered by waiver W-01. |

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

### Click-through results (2026-09-26, Chrome, live web build)

The officer account was promoted to President via SQL (actor `migration`, audited) after the product owner registered it
through the live site. That registration also exercised the real signup path, landing in `pending_approval` in the default branch.

| Step | Result |
|---|---|
| 1. Officer account: *Check status* → Home with President chip + Officer tools | ✅ pass |
| 2. Private window: register test member → **Awaiting approval** | ✅ pass |
| 3. Officer: *Review member applications* → *Approve as Athlete* → *Confirm* | ✅ pass |
| 4. Test member: *Check status* → Athlete Home, no Officer tools | ✅ pass |
| 5. Test member: open `/bacalsys/member-approvals` directly → back on Home, no queue shown | ✅ pass |

## Hosted E2E test-data cleanup (strategy, not a blocker)

Each hosted E2E run leaves two throwaway members (`juan.<ts>@bacalsys.local`, `maria.<ts>@bacalsys.local`).
`scripts/e2e/cleanup-hosted.sql` removes E2E identities older than 24 h that match only that exact pattern. Deletions
cascade to profiles and positions, and the audit log keeps the history. Run it deliberately, for example before each
sprint's acceptance. It is not automated, because it permanently deletes rows.
