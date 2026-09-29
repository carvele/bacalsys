import '../global.css';

import { QueryClientProvider } from '@tanstack/react-query';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { CenteredSpinner } from '@/components/ui';
import { hasPermission, OFFICER_PERMISSIONS } from '@/features/auth/access';
import { useAuth, useAuthBootstrap } from '@/features/auth/use-auth';
import { queryClient, wireQueryLifecycle } from '@/lib/query-client';
import { offlineOutboxService } from '@/services/sync/outbox-sync';

SplashScreen.preventAutoHideAsync().catch(() => {});
wireQueryLifecycle();
// Sprint 4 · Task 4.10: opens the durable outbox, recovers any stale
// 'syncing' rows from a crash, and starts watching connectivity.
void offlineOutboxService.initialize();

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
 *   signed-out / pending / error → (auth)    login, register, pending-approval
 *   active                       → (athlete) home, exercise library
 *   active + an officer tool     → (officer) member approvals, coach assignment,
 *                                            exercise approvals (each screen also
 *                                            checks its own permission)
 *   active + Coach position      → (coach)   my athletes
 */
function RootNavigator() {
  useAuthBootstrap();
  const { route, access } = useAuth();

  useEffect(() => {
    if (route !== 'loading') SplashScreen.hideAsync().catch(() => {});
  }, [route]);

  if (route === 'loading') return <CenteredSpinner />;

  const isActive = route === 'active';
  const hasOfficerTools = isActive && OFFICER_PERMISSIONS.some((p) => hasPermission(access, p));
  const isCoach = isActive && (access?.positions.includes('Coach') ?? false);
  // Sprint 6: skills:verify (Coach, Vice President, President) reaches the
  // verification queue under (coach)/skills/verify even for a non-Coach officer.
  const canVerifySkills = isActive && hasPermission(access, 'skills:verify');
  const canSeeCoachGroup = isCoach || canVerifySkills;

  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: '#0B0F14' } }}>
      <Stack.Protected guard={isActive}>
        <Stack.Screen name="(athlete)" />
        <Stack.Protected guard={hasOfficerTools}>
          <Stack.Screen name="(officer)" />
        </Stack.Protected>
        <Stack.Protected guard={canSeeCoachGroup}>
          <Stack.Screen name="(coach)" />
        </Stack.Protected>
      </Stack.Protected>
      <Stack.Protected guard={!isActive}>
        <Stack.Screen name="(auth)" />
      </Stack.Protected>
    </Stack>
  );
}
