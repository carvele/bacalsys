import { useQuery } from '@tanstack/react-query';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Card, CenteredSpinner, Notice } from '@/components/ui';
import { displayName } from '@/features/coaching/coach-roster';
import { useAuth } from '@/features/auth/use-auth';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 2.6: a coach's current athletes (D2). Reads coach_assignments filtered to
 * the caller; RLS independently limits the rows to assignments the caller is a
 * party to, and fails closed if the caller is no longer an active member.
 */
export default function MyAthletesScreen() {
  const { profile } = useAuth();
  const coachId = profile?.id;

  const athletes = useQuery({
    queryKey: ['my-athletes', coachId],
    enabled: !!coachId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('coach_assignments')
        .select('id, started_at, notes, athlete:profiles!coach_assignments_athlete_id_fkey(id, full_name)')
        .eq('coach_id', coachId!)
        .is('ended_at', null)
        .order('started_at', { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  if (athletes.isPending) return <CenteredSpinner label="Loading your athletes…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={athletes.data ?? []}
        keyExtractor={(a) => a.id}
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        refreshControl={
          <RefreshControl refreshing={athletes.isRefetching} onRefresh={() => athletes.refetch()} tintColor="#F97316" />
        }
        ListHeaderComponent={
          <View className="gap-3">
            {athletes.isError ? <Notice tone="danger">{describeError(athletes.error)}</Notice> : null}
            {athletes.data?.length ? (
              <Text className="text-ink-muted">
                You are the primary coach of {athletes.data.length} athlete{athletes.data.length === 1 ? '' : 's'}.
              </Text>
            ) : null}
          </View>
        }
        ListEmptyComponent={
          athletes.isError ? null : (
            <Card>
              <Text className="text-center text-ink-muted">
                No athletes are assigned to you yet. A Vice President or President assigns primary coaches.
              </Text>
            </Card>
          )
        }
        renderItem={({ item }) => (
          <Card className="gap-1">
            <Text className="text-title text-ink">{displayName(item.athlete?.full_name)}</Text>
            <Text className="text-sm text-ink-faint">Coaching since {new Date(item.started_at).toLocaleDateString()}</Text>
            {item.notes ? <Text className="text-ink-muted">{item.notes}</Text> : null}
          </Card>
        )}
      />
    </SafeAreaView>
  );
}
