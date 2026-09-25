import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect } from 'react';

import { supabase } from '@/lib/supabase';

import { parseAccessContext, resolveAccessRoute, type MemberStatus } from './access';
import { useSessionStore } from './session-store';

export const authKeys = {
  profile: (userId: string) => ['profile', userId] as const,
  access: (userId: string) => ['access-context', userId] as const,
};

/**
 * Mount once at the app root. Restores the persisted session and mirrors every
 * subsequent auth event into the session store.
 */
export function useAuthBootstrap() {
  const setSession = useSessionStore((s) => s.setSession);
  const queryClient = useQueryClient();

  useEffect(() => {
    let mounted = true;
    supabase.auth
      .getSession()
      .then(({ data }) => {
        if (mounted) setSession(data.session);
      })
      .catch(() => {
        if (mounted) setSession(null);
      });

    // Keep this callback synchronous: awaiting Supabase calls inside it can deadlock the auth client.
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      setSession(session);
      if (event === 'SIGNED_OUT') queryClient.clear();
    });

    return () => {
      mounted = false;
      data.subscription.unsubscribe();
    };
  }, [setSession, queryClient]);
}

/** Own profile. RLS always lets a member read their own row. */
function useOwnProfile(userId: string | undefined) {
  return useQuery({
    queryKey: authKeys.profile(userId ?? 'anonymous'),
    enabled: !!userId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles')
        .select('id, full_name, status, home_branch_id')
        .eq('id', userId!)
        .single();
      if (error) throw error;
      return data;
    },
    // While waiting for approval, re-check periodically so the gate opens on its own.
    refetchInterval: (query) => (query.state.data?.status === 'pending_approval' ? 30_000 : false),
  });
}

function useAccessContext(userId: string | undefined, status: MemberStatus | undefined) {
  return useQuery({
    queryKey: authKeys.access(userId ?? 'anonymous'),
    // Only active members hold positions; gated users skip the call.
    enabled: !!userId && status === 'active',
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_my_access_context');
      if (error) throw error;
      return parseAccessContext(data);
    },
  });
}

export function useAuth() {
  const session = useSessionStore((s) => s.session);
  const initialized = useSessionStore((s) => s.initialized);
  const userId = session?.user.id;

  const profileQuery = useOwnProfile(userId);
  const status = profileQuery.data?.status;
  const accessQuery = useAccessContext(userId, status);

  const route = resolveAccessRoute({
    initialized,
    hasSession: !!session,
    status,
    access: accessQuery.data,
    failed: profileQuery.isError || accessQuery.isError,
  });

  const { refetch: refetchProfile } = profileQuery;
  const { refetch: refetchAccess } = accessQuery;
  const refresh = useCallback(async () => {
    await Promise.all([refetchProfile(), status === 'active' ? refetchAccess() : undefined]);
  }, [refetchProfile, refetchAccess, status]);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
  }, []);

  return {
    route,
    email: session?.user.email ?? null,
    profile: profileQuery.data,
    access: accessQuery.data,
    error: profileQuery.error ?? accessQuery.error,
    isRefreshing: profileQuery.isFetching || accessQuery.isFetching,
    refresh,
    signOut,
  };
}
