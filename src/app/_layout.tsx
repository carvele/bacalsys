import '../global.css';

import { QueryClientProvider } from '@tanstack/react-query';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { CenteredSpinner } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth, useAuthBootstrap } from '@/features/auth/use-auth';
import { queryClient, wireQueryLifecycle } from '@/lib/query-client';

SplashScreen.preventAutoHideAsync().catch(() => {});
wireQueryLifecycle();

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <QueryClientProvider client={queryClient}>
        <StatusBar style="light" />
        <RootNavigator />
      </QueryClientProvider>
    </SafeAreaProvider>
  );
}

/**
 * Route guard (Task 1.13). Which groups exist depends on the resolved access
 * route. This is a UX gate only: RLS and the app_private checks enforce
 * authorization on the server regardless of what the client renders.
 *
 *   signed-out / pending / error → (auth)   login, register, pending-approval
 *   active                       → (athlete) home
 *   active + members:approve     → (officer) member approvals
 */
function RootNavigator() {
  useAuthBootstrap();
  const { route, access } = useAuth();

  useEffect(() => {
    if (route !== 'loading') SplashScreen.hideAsync().catch(() => {});
  }, [route]);

  if (route === 'loading') return <CenteredSpinner />;

  const isActive = route === 'active';
  const canReviewMembers = isActive && hasPermission(access, 'members:approve');

  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: '#0B0F14' } }}>
      <Stack.Protected guard={isActive}>
        <Stack.Screen name="(athlete)" />
        <Stack.Protected guard={canReviewMembers}>
          <Stack.Screen name="(officer)" />
        </Stack.Protected>
      </Stack.Protected>
      <Stack.Protected guard={!isActive}>
        <Stack.Screen name="(auth)" />
      </Stack.Protected>
    </Stack>
  );
}
