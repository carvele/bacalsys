import { useQuery } from '@tanstack/react-query';
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { Text, View } from 'react-native';

import { Button, Card, Notice } from '@/components/ui';
import {
  canStartOccurrence,
  playerParams,
  showsCompletionMark,
  statusLabel,
  statusTone,
  todaysTraining,
  type StatusTone,
} from '@/features/assignments/occurrences';
import { useOrgTimezone } from '@/features/assignments/use-org-timezone';
import { useAuth } from '@/features/auth/use-auth';
import { addDaysIso, relativeDayLabel, todayIso } from '@/lib/date-tz';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

const TONE_STYLE: Record<StatusTone, { box: string; text: string }> = {
  neutral: { box: 'bg-surface-sunken', text: 'text-ink-muted' },
  active: { box: 'bg-brand-soft', text: 'text-brand' },
  success: { box: 'bg-success-soft', text: 'text-success' },
  warning: { box: 'bg-warning-soft', text: 'text-warning' },
  danger: { box: 'bg-danger-soft', text: 'text-danger' },
};

/**
 * Sprint 5 · Task 5.13 — the athlete's "Today's training". Live query of the
 * caller's own assignment_occurrences for the ORGANIZATION-local today (plus an
 * overdue occurrence still in progress), each showing the routine, its pinned
 * version, a status chip, the coach's notes and — for upcoming / in-progress
 * workouts — a "Start workout" button that opens the Workout Player with both
 * the occurrence's pinned version and its id, so the session links to it.
 * RLS independently limits the rows to the athlete's own occurrences.
 */
export function TodaysTrainingCard() {
  const router = useRouter();
  const { profile } = useAuth();
  const timezone = useOrgTimezone();
  const today = todayIso(timezone);

  const occurrences = useQuery({
    queryKey: ['todays-training', profile?.id, today],
    enabled: !!profile?.id,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('assignment_occurrences')
        .select(
          'id, scheduled_date, status, workout_version_id, workout_versions(version_number, workout_templates(name)), workout_assignments(notes)',
        )
        .eq('athlete_id', profile!.id)
        .gte('scheduled_date', addDaysIso(today, -1))
        .lte('scheduled_date', today)
        .order('scheduled_date');
      if (error) throw error;
      return data ?? [];
    },
  });

  // Coming back to Home after a workout must show its new status.
  useFocusEffect(
    useCallback(() => {
      void occurrences.refetch();
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []),
  );

  const rows = todaysTraining(occurrences.data ?? [], today);

  return (
    <Card className="gap-3">
      <Text className="text-title text-ink">Today&apos;s training</Text>
      {occurrences.isError ? <Notice tone="danger">{describeError(occurrences.error)}</Notice> : null}
      {!occurrences.isError && !occurrences.isPending && rows.length === 0 ? (
        <Text className="text-ink-muted">No workouts scheduled for today. Your coach&apos;s assignments will appear here.</Text>
      ) : null}
      {rows.map((o) => {
        const tone = TONE_STYLE[statusTone(o.status)];
        const routine = o.workout_versions?.workout_templates?.name ?? 'Workout';
        return (
          <View key={o.id} className="gap-2 rounded-control border border-surface-border p-3">
            <View className="flex-row items-center justify-between gap-2">
              <Text className="flex-1 text-base font-semibold text-ink">{routine}</Text>
              <View className="rounded-full bg-surface-sunken px-2 py-0.5">
                <Text className="text-xs font-semibold text-ink-muted">v{o.workout_versions?.version_number ?? '?'}</Text>
              </View>
            </View>
            <View className="flex-row flex-wrap items-center gap-2">
              <View className={`rounded-full px-3 py-1 ${tone.box}`}>
                <Text className={`text-sm font-semibold ${tone.text}`}>{statusLabel(o.status)}</Text>
              </View>
              <Text className="text-sm text-ink-faint">{relativeDayLabel(o.scheduled_date, today)}</Text>
              {showsCompletionMark(o.status) ? <Text className="text-lg text-success">✓</Text> : null}
            </View>
            {o.workout_assignments?.notes ? <Text className="text-ink-muted">“{o.workout_assignments.notes}”</Text> : null}
            {canStartOccurrence(o.status) ? (
              <Button
                label={o.status === 'in_progress' ? 'Resume workout' : 'Start workout'}
                onPress={() => router.push({ pathname: '/workout/active', params: playerParams({ id: o.id, workoutVersionId: o.workout_version_id }) })}
              />
            ) : null}
          </View>
        );
      })}
    </Card>
  );
}
