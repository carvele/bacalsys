import type { NetInfoConfiguration } from '@react-native-community/netinfo';

/**
 * NetInfo reachability settings.
 *
 * On web, NetInfo's default probe is `HEAD /` on the page's origin and treats
 * anything but HTTP 200 as "no internet". When the app is served from a
 * sub-path (GitHub Pages: /bacalsys/) the origin root returns 404, so NetInfo
 * reported offline and TanStack Query paused every request. Probe the Supabase
 * Auth health endpoint instead: it is the backend the app actually needs.
 *
 * Native keeps NetInfo's platform reachability (no override).
 */
export function netInfoConfiguration(
  platform: string,
  supabaseUrl: string,
  anonKey: string,
): Partial<NetInfoConfiguration> | null {
  if (platform !== 'web') return null;
  return {
    reachabilityUrl: `${supabaseUrl.replace(/\/$/, '')}/auth/v1/health`,
    reachabilityMethod: 'GET',
    reachabilityHeaders: { apikey: anonKey },
    reachabilityTest: async (response) => response.status === 200,
  };
}
