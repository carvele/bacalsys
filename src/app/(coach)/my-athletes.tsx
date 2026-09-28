import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { AssignWorkoutModal } from '@/components/AssignWorkoutModal';
import { Button, Card, CenteredSpinner, Notice } from '@/components/ui';
import { summarizeByAthlete } from '@/features/assignments/occurrences';
import { displayName } from '@/features/coaching/coach-roster';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { formatCalendarDate } from '@/lib/date-tz';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 2.6: a coach's current athletes (D2). Reads coach_assignments filtered to
 * the caller; RLS independently limits the rows to assignments the caller is a
 * party to, and fails closed if the caller is no longer an active member.
 */
export default function MyAthletesScreen() {
  const { profile, access } = useAuth();
  const coachId = profile?.id;
  const canAssign = hasPermission(access, 'workout:assign');
  const [assigning, setAssigning] = useState<string | null>(null); // athlete id the modal is open for

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

  // Sprint 5 · Task 5.14: upcoming assigned workouts of the coach's athletes. RLS independently limits
  // these rows to the athletes the caller currently coaches.
  const athleteIds = (athletes.data ?? []).map((a) => a.athlete?.id).filter((id): id is string => !!id);
  const upcoming = useQuery({
    queryKey: ['coach-upcoming-occurrences', coachId, athleteIds.join(',')],
    enabled: !!coachId && athleteIds.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('assignment_occurrences')
        .select('athlete_id, scheduled_date, status')
        .in('athlete_id', athleteIds)
        .eq('status', 'upcoming');
      if (error) throw error;
      return data ?? [];
    },
  });
  const summaries = summarizeByAthlete(upcoming.data ?? []);

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
        renderItem={({ item }) => {
          const summary = item.athlete ? summaries.get(item.athlete.id) : undefined;
          return (
            <Card className="gap-1">
              <Text className="text-title text-ink">{displayName(item.athlete?.full_name)}</Text>
              <Text className="text-sm text-ink-faint">Coaching since {new Date(item.started_at).toLocaleDateString()}</Text>
              <Text className="text-ink-muted">
                {summary
                  ? `${summary.upcomingCount} upcoming workout${summary.upcomingCount === 1 ? '' : 's'} · next ${formatCalendarDate(summary.nextDate!)}`
                  : 'No upcoming workouts assigned'}
              </Text>
              {item.notes ? <Text className="text-ink-muted">{item.notes}</Text> : null}
              {canAssign && item.athlete ? (
                <View className="mt-2">
                  <Button label="Assign workout" variant="secondary" onPress={() => setAssigning(item.athlete!.id)} />
                </View>
              ) : null}
            </Card>
          );
        }}
      />
      {assigning ? (
        <AssignWorkoutModal
          visible
          initialAthleteIds={[assigning]}
          onClose={() => setAssigning(null)}
          onAssigned={() => void upcoming.refetch()}
        />
      ) : null}
    </SafeAreaView>
  );
}
