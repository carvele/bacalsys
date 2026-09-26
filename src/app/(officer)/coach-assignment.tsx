import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Redirect } from 'expo-router';
import { useMemo, useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, CenteredSpinner, Chip, Notice, TextField } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import {
  buildRoster,
  eligibleCoaches,
  searchRoster,
  type ActiveAssignment,
  type MemberRow,
  type RosterEntry,
} from '@/features/coaching/coach-roster';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

const rosterKey = ['coach-roster'] as const;

/**
 * Task 2.6: primary coach assignment for holders of coaches:assign (D3: VP and
 * President). Assigning an athlete who already has a coach is a reassignment:
 * public.assign_primary_coach() atomically closes the old row (history kept)
 * and opens the new one. The permission check here is UX only.
 */
export default function CoachAssignmentScreen() {
  const { access } = useAuth();
  const queryClient = useQueryClient();
  const [search, setSearch] = useState('');
  const [openAthleteId, setOpenAthleteId] = useState<string | null>(null);
  const [pending, setPending] = useState<{ athlete: RosterEntry; coach: RosterEntry } | null>(null);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const allowed = hasPermission(access, 'coaches:assign');

  const roster = useQuery({
    queryKey: rosterKey,
    enabled: allowed,
    queryFn: async () => {
      const [members, assignments] = await Promise.all([
        supabase
          .from('profiles')
          .select('id, full_name, member_positions!member_positions_profile_id_fkey(ended_at, positions(name))')
          .eq('status', 'active'),
        supabase.from('coach_assignments').select('id, athlete_id, coach_id, started_at').is('ended_at', null),
      ]);
      if (members.error) throw members.error;
      if (assignments.error) throw assignments.error;
      return buildRoster(members.data as MemberRow[], assignments.data as ActiveAssignment[]);
    },
  });

  const assign = useMutation({
    mutationFn: async ({ athlete, coach }: { athlete: RosterEntry; coach: RosterEntry }) => {
      const { error } = await supabase.rpc('assign_primary_coach', { p_athlete_id: athlete.id, p_coach_id: coach.id });
      if (error) throw error;
      return { athlete, coach };
    },
    onSuccess: ({ athlete, coach }) => {
      setMessage({
        tone: 'success',
        text: athlete.currentCoach
          ? `${athlete.name} moved from ${athlete.currentCoach.name} to ${coach.name}. The earlier assignment is kept in history.`
          : `${coach.name} is now ${athlete.name}'s primary coach.`,
      });
      setOpenAthleteId(null);
    },
    onError: (error) =>
      setMessage({
        tone: 'danger',
        text: describeError(error, { '55000': 'That athlete or coach is not eligible (inactive, or already assigned).' }),
      }),
    onSettled: () => {
      setPending(null);
      queryClient.invalidateQueries({ queryKey: rosterKey });
    },
  });

  const athletes = useMemo(() => searchRoster(roster.data?.athletes ?? [], search), [roster.data, search]);

  if (!allowed) return <Redirect href="/" />;
  if (roster.isPending) return <CenteredSpinner label="Loading members…" />;
  const coaches = roster.data?.coaches ?? [];

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={athletes}
        keyExtractor={(a) => a.id}
        keyboardShouldPersistTaps="handled"
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        refreshControl={
          <RefreshControl refreshing={roster.isRefetching} onRefresh={() => roster.refetch()} tintColor="#F97316" />
        }
        ListHeaderComponent={
          <View className="gap-3">
            {roster.isError ? <Notice tone="danger">{describeError(roster.error)}</Notice> : null}
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
            {coaches.length === 0 && !roster.isError ? (
              <Notice tone="warning">No active member holds the Coach position yet.</Notice>
            ) : null}
            <TextField label="Search members" value={search} onChangeText={setSearch} placeholder="Name" autoCorrect={false} />
          </View>
        }
        ListEmptyComponent={
          <Card>
            <Text className="text-center text-ink-muted">No active members match.</Text>
          </Card>
        }
        renderItem={({ item }) => {
          const open = openAthleteId === item.id;
          const choices = eligibleCoaches(item, coaches);
          const confirming = pending?.athlete.id === item.id ? pending : null;
          return (
            <Card className="gap-3">
              <View className="gap-0.5">
                <Text className="text-title text-ink">{item.name}</Text>
                <Text className="text-sm text-ink-muted">
                  {item.currentCoach
                    ? `Coach: ${item.currentCoach.name} · since ${new Date(item.currentCoach.since).toLocaleDateString()}`
                    : 'No primary coach'}
                </Text>
              </View>

              {confirming ? (
                <View className="gap-2">
                  <Text className="text-ink">
                    {item.currentCoach
                      ? `Reassign ${item.name} from ${item.currentCoach.name} to ${confirming.coach.name}?`
                      : `Assign ${confirming.coach.name} as ${item.name}'s primary coach?`}
                  </Text>
                  <View className="flex-row gap-2">
                    <View className="flex-1">
                      <Button label="Cancel" variant="secondary" onPress={() => setPending(null)} disabled={assign.isPending} />
                    </View>
                    <View className="flex-1">
                      <Button label="Confirm" onPress={() => assign.mutate(confirming)} loading={assign.isPending} />
                    </View>
                  </View>
                </View>
              ) : open ? (
                <View className="gap-2">
                  <Text className="text-sm font-medium text-ink-muted">Choose a coach</Text>
                  {choices.length ? (
                    <View className="flex-row flex-wrap gap-2">
                      {choices.map((c) => (
                        <Chip key={c.id} label={c.name} onPress={() => setPending({ athlete: item, coach: c })} />
                      ))}
                    </View>
                  ) : (
                    <Text className="text-ink-faint">No other active coach is available.</Text>
                  )}
                  <Button label="Close" variant="ghost" onPress={() => setOpenAthleteId(null)} />
                </View>
              ) : (
                <Button
                  label={item.currentCoach ? 'Change coach' : 'Assign coach'}
                  variant="secondary"
                  onPress={() => {
                    setMessage(null);
                    setOpenAthleteId(item.id);
                  }}
                  disabled={assign.isPending || coaches.length === 0}
                />
              )}
            </Card>
          );
        }}
      />
    </SafeAreaView>
  );
}
