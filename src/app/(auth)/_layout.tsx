import { Stack } from 'expo-router';

import { useAuth } from '@/features/auth/use-auth';

/**
 * Signed-out users see login/register. Signed-in users who are not active
 * (pending, suspended, rejected, or membership failed to load) are held at
 * pending-approval and cannot reach any other screen (DoD #12).
 */
export default function AuthLayout() {
  const { route } = useAuth();
  const signedOut = route === 'signed-out';

  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: '#0B0F14' } }}>
      <Stack.Protected guard={signedOut}>
        <Stack.Screen name="login" />
        <Stack.Screen name="register" />
      </Stack.Protected>
      <Stack.Protected guard={!signedOut}>
        <Stack.Screen name="pending-approval" />
      </Stack.Protected>
    </Stack>
  );
}
