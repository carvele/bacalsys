import { useQuery } from '@tanstack/react-query';
import { useLocalSearchParams } from 'expo-router';
import { ScrollView, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { SessionReplayTable } from '@/components/SessionReplayTable';
import { Card, CenteredSpinner, Notice } from '@/components/ui';
import { replayTotals, sessionOutcome } from '@/features/history/replay';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { parseSessionReplay } from '@/types/skills';

/**
 * Sprint 6 · Task 6.12 — Session Replay. Consumes `public.get_session_replay`
 * (F-S6-P02): the RPC itself decides whether the caller may see this session at
 * all, and separately whether private feedback and medical substitutions are
 * included (Rule E) — this screen only renders what comes back, never widens it.
 */
export default function SessionReplayScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();

  const query = useQuery({
    queryKey: ['session-replay', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_session_replay', { p_session_id: id! });
      if (error) throw error;
      return parseSessionReplay(data);
    },
  });

  if (query.isPending) return <CenteredSpinner label="Loading session…" />;

  if (query.isError) {
    return (
      <SafeAreaView edges={['bottom']} className="flex-1 bg-surface p-4">
        <Notice tone="danger">
          {describeError(query.error, { '42501': 'You are not authorized to view this session.', '22000': 'That session no longer exists.' })}
        </Notice>
      </SafeAreaView>
    );
  }

  const replay = query.data;
  const totals = replayTotals(replay.items);

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <ScrollView contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4">
        <Card className="gap-2">
          <View className="flex-row items-center justify-between">
            <Text className="text-title text-ink">{sessionOutcome(replay.session)}</Text>
            <Text className="text-sm text-ink-faint">{new Date(replay.session.startedAt).toLocaleDateString()}</Text>
          </View>
          <Text className="text-ink-muted">
            {totals.completed} of {totals.prescribed} prescribed set{totals.prescribed === 1 ? '' : 's'} completed
            {totals.extra > 0 ? ` · ${totals.extra} extra set${totals.extra === 1 ? '' : 's'}` : ''}
          </Text>
          {replay.feedback ? (
            <Text className="text-sm text-ink-muted">
              Difficulty {replay.feedback.difficultyRating}/10 · Energy {replay.feedback.energyLevel}/5
            </Text>
          ) : null}
          {replay.privateFeedback ? (
            <View className="mt-1 rounded-control border border-danger bg-danger-soft px-3 py-2">
              <Text className="text-sm font-semibold text-danger">
                {replay.privateFeedback.hasDiscomfort ? `Discomfort noted${replay.privateFeedback.discomfortArea ? `: ${replay.privateFeedback.discomfortArea}` : ''}` : 'No discomfort reported'}
              </Text>
              {replay.privateFeedback.noteToCoach ? <Text className="mt-1 text-sm text-danger">{replay.privateFeedback.noteToCoach}</Text> : null}
            </View>
          ) : null}
        </Card>

        <SessionReplayTable replay={replay} />
      </ScrollView>
    </SafeAreaView>
  );
}
