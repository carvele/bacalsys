# W-01: iOS development build (explicit environment waiver)

- **Status:** waived for Sprint 1 closure (environment constraint, not a pass)
- **Requirement:** DoD #1, "boots on … iOS development build"

**Constraint:** iOS builds require Xcode on macOS, and this environment is Windows only. The alternative is an EAS cloud
build (`eas build --profile development --platform ios`, with `ios.simulator: true` for a simulator build), which needs
the product owner's Expo account login. A device build would also need an Apple Developer account. The agent cannot
provide either.

**What is covered:** the JavaScript, routing, styling and Supabase layers shared with Android are verified on Android
and web. iOS-specific surfaces not yet exercised: Keychain-backed `expo-secure-store`, iOS keyboard avoidance
(`KeyboardAvoidingView` behavior `padding`), and safe-area insets on notched devices.

**To lift the waiver:** run `npx eas-cli@latest build --profile development-simulator --platform ios` once from an Expo-authenticated machine (profile already in `eas.json`),
and boot it in any iOS simulator. Record the result here.
