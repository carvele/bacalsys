import NetInfo from '@react-native-community/netinfo';
import { focusManager, onlineManager, QueryClient } from '@tanstack/react-query';
import { AppState, Platform, type AppStateStatus } from 'react-native';

import { env } from './env';
import { netInfoConfiguration } from './netinfo-config';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 2,
    },
  },
});

let wired = false;

/**
 * Connects TanStack Query to device connectivity (NetInfo → onlineManager) and
 * app foreground state (AppState → focusManager). Idempotent; call once at startup.
 * Returns an unsubscribe function for tests.
 */
export function wireQueryLifecycle(): () => void {
  if (wired) return () => {};
  wired = true;

  // Must run before the first listener so the initial reachability probe uses it.
  const netInfoConfig = netInfoConfiguration(Platform.OS, env.supabaseUrl, env.supabaseAnonKey);
  if (netInfoConfig) NetInfo.configure(netInfoConfig);

  onlineManager.setEventListener((setOnline) =>
    NetInfo.addEventListener((state) => {
      setOnline(state.isConnected !== false && state.isInternetReachable !== false);
    }),
  );

  // Web already has window focus/visibility handling built in.
  if (Platform.OS === 'web') {
    return () => {
      wired = false;
    };
  }

  const onAppStateChange = (status: AppStateStatus) => {
    focusManager.setFocused(status === 'active');
  };
  const subscription = AppState.addEventListener('change', onAppStateChange);
  return () => {
    subscription.remove();
    wired = false;
  };
}
