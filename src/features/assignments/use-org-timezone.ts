import { useQuery } from '@tanstack/react-query';

import { DEFAULT_TIMEZONE, todayIso } from '@/lib/date-tz';
import { supabase } from '@/lib/supabase';

/**
 * The caller's organization timezone (organizations.timezone). RLS lets a member
 * read only their own organization's row. Falls back to the club default while
 * loading or offline so date maths never blocks the UI.
 */
export function useOrgTimezone(): string {
  const q = useQuery({
    queryKey: ['organization-timezone'],
    staleTime: 60 * 60 * 1000,
    queryFn: async () => {
      const { data, error } = await supabase.from('organizations').select('timezone').limit(1).maybeSingle();
      if (error) throw error;
      return data?.timezone ?? DEFAULT_TIMEZONE;
    },
  });
  return q.data ?? DEFAULT_TIMEZONE;
}

/** The organization's calendar today (YYYY-MM-DD). */
export const useOrgToday = () => todayIso(useOrgTimezone());
