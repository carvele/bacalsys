# F-08: Text links invisible on Android (className on Expo Router <Link>)

- **Class:** Bug (native-only)
- **Found by:** first boot of the Android development client (Pixel 4 emulator, Android 16)

**Symptom:** "Create an account" (login) and "Sign in" (register) rendered in near-black on the dark background.
They were correct orange on web, so every web test passed.

**Root cause:** NativeWind applies `className` to React Native core components. Expo Router's `<Link>` is not one,
so on iOS/Android the class is silently dropped; react-native-web happens to forward it.

**Fix:** new `TextLink` primitive (`src/components/ui`) that uses `<Link asChild>` with a styled `Pressable` + `Text`,
adding link semantics and a larger touch target. Verified on the emulator: correct color, tap navigates to Register.
Regression: an ESLint `no-restricted-syntax` rule (`eslint.config.js`) rejects `className` on `<Link>` in any
`src/**/*.tsx`. It runs in `npm run lint` and CI, and was confirmed by re-introducing the bug.

**Lesson:** web verification does not prove native styling. Keep the Android dev-client check in each sprint's gate.
