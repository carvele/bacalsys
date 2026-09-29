import { useQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { FlatList, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { TrainingCalendar } from '@/components/TrainingCalendar';
import { Card, CenteredSpinner, Notice } from '@/components/ui';
import { useOrgTimezone } from '@/features/assignments/use-org-timezone';
import { useAuth } from '@/features/auth/use-auth';
import { CALENDAR_STATUS_COLOR, CALENDAR_STATUS_LABEL, adherenceBarPercent, adherenceCaption, buildCalendarEntries, formatAdherence, groupByDay, monthEnd, monthStart } from '@/lib/training-stats';
import { addDaysIso, formatCalendarDate, todayIso } from '@/lib/date-tz';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { parseAthleteSummary } from '@/types/skills';

/**
 * Sprint 6 · Task 6.11 — Training Calendar (Feature 7.1). Shows the caller's own
 * history by default; a coach or officer opens `?athleteId=UUID` from the roster
 * to drill into an athlete they can see (`app_private.can_view_athlete_training`,
 * enforced server-side by `get_my_athlete_summary` / `get_athlete_summary` and by
 * the occurrence/session RLS the calendar query itself relies on — this screen
 * renders whatever comes back and nothing more).
 */
export default function TrainingCalendarScreen() {
  const { athleteId: paramAthleteId } = useLocalSearchParams<{ athleteId?: string }>();
  const { profile } = useAuth();
  const timezone = useOrgTimezone();
  const today = todayIso(timezone);
  const athleteId = paramAthleteId || profile?.id;
  const viewingOther = !!paramAthleteId && paramAthleteId !== profile?.id;

  const [month, setMonth] = useState(() => monthStart(today));
  const [selectedDay, setSelectedDay] = useState<string | null>(null);

  const athleteName = useQuery({
    queryKey: ['history-athlete-name', athleteId],
    enabled: viewingOther,
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('full_name').eq('id', athleteId!).maybeSingle();
      if (error) throw error;
      return data?.full_name?.trim() || 'Athlete';
    },
  });

  const rangeStart = monthStart(month);
  const rangeEnd = monthEnd(month);
  // Sessions are timestamps; pad a day each side so a session near midnight in
  // the organization's timezone is never missed by a UTC date comparison.
  const paddedStart = addDaysIso(rangeStart, -1);
  const paddedEnd = addDaysIso(rangeEnd, 1);

  const calendar = useQuery({
    queryKey: ['training-calendar', athleteId, rangeStart, rangeEnd],
    enabled: !!athleteId,
    queryFn: async () => {
      const [occRes, sessRes] = await Promise.all([
        supabase
          .from('assignment_occurrences')
          .select('id, scheduled_date, status, workout_versions(workout_templates(name))')
          .eq('athlete_id', athleteId!)
          .gte('scheduled_date', rangeStart)
          .lte('scheduled_date', rangeEnd),
        supabase
          .from('workout_sessions')
          .select('id, started_at, status, assignment_occurrence_id, session_exercises(session_sets(is_completed))')
          .eq('athlete_id', athleteId!)
          .gte('started_at', `${paddedStart}T00:00:00Z`)
          .lte('started_at', `${paddedEnd}T23:59:59Z`),
      ]);
      if (occRes.error) throw occRes.error;
      if (sessRes.error) throw sessRes.error;
      const occurrences = (occRes.data ?? []).map((o) => ({
        id: o.id,
        scheduled_date: o.scheduled_date,
        status: o.status,
        title: o.workout_versions?.workout_templates?.name,
      }));
      const sessions = (sessRes.data ?? []).map((s) => ({
        id: s.id,
        started_at: s.started_at,
        status: s.status,
        assignment_occurrence_id: s.assignment_occurrence_id,
        recordedSets: (s.session_exercises ?? []).reduce((n, se) => n + (se.session_sets ?? []).filter((set) => set.is_completed).length, 0),
      }));
      return buildCalendarEntries({ occurrences, sessions, timezone });
    },
  });

  const summary = useQuery({
    queryKey: ['athlete-summary', athleteId],
    enabled: !!athleteId,
    queryFn: async () => {
      const rpc = viewingOther ? supabase.rpc('get_athlete_summary', { p_athlete_id: athleteId! }) : supabase.rpc('get_my_athlete_summary', {});
      const { data, error } = await rpc;
      if (error) throw error;
      return parseAthleteSummary(data);
    },
  });

  const entries = calendar.data ?? [];
  const entriesByDay = useMemo(() => groupByDay(calendar.data ?? []), [calendar.data]);
  const selectedEntries = selectedDay ? (entriesByDay.get(selectedDay) ?? []) : [];

  const openEntry = (sessionId: string | null) => {
    if (sessionId) router.push({ pathname: '/history/[id]', params: { id: sessionId } });
  };

  if (calendar.isPending || summary.isPending) return <CenteredSpinner label="Loading training history…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={selectedEntries}
        keyExtractor={(e) => e.key}
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        ListHeaderComponent={
          <View className="gap-3 pb-2">
            {viewingOther ? <Text className="text-title text-ink">{athleteName.data ?? 'Athlete'}&apos;s training history</Text> : null}
            {calendar.isError ? <Notice tone="danger">{describeError(calendar.error)}</Notice> : null}
            {summary.isError ? <Notice tone="danger">{describeError(summary.error)}</Notice> : null}
            <Card>
              <TrainingCalendar
                monthIso={month}
                entriesByDay={entriesByDay}
                today={today}
                selected={selectedDay}
                onSelectDay={(d) => setSelectedDay(d === selectedDay ? null : d)}
                onPrevMonth={() => setMonth((m) => addDaysIso(monthStart(m), -1).slice(0, 8) + '01')}
                onNextMonth={() => setMonth((m) => addDaysIso(monthEnd(m), 1))}
              />
            </Card>
            {summary.data ? (
              <Card className="gap-2">
                <Text className="text-sm font-medium uppercase tracking-wide text-ink-muted">30-day adherence</Text>
                <View className="flex-row items-end gap-2">
                  <Text className="text-display text-ink">{formatAdherence(summary.data.adherenceRate)}</Text>
                </View>
                <View className="h-2 overflow-hidden rounded-full bg-surface-sunken">
                  <View
                    style={{ width: `${adherenceBarPercent(summary.data.adherenceRate)}%`, backgroundColor: '#10B981' }}
                    className="h-2 rounded-full"
                  />
                </View>
                <Text className="text-sm text-ink-muted">{adherenceCaption(summary.data)}</Text>
              </Card>
            ) : null}
            {selectedDay ? (
              <Text className="text-sm font-medium uppercase tracking-wide text-ink-muted">{formatCalendarDate(selectedDay)}</Text>
            ) : null}
          </View>
        }
        ListEmptyComponent={
          selectedDay ? (
            <Card>
              <Text className="text-center text-ink-muted">No training recorded on this day.</Text>
            </Card>
          ) : entries.length === 0 && !calendar.isError ? (
            <Card>
              <Text className="text-center text-ink-muted">Tap a highlighted day to see what happened.</Text>
            </Card>
          ) : null
        }
        renderItem={({ item }) => (
          <Card className="gap-1">
            <View className="flex-row items-center gap-2">
              <View style={{ backgroundColor: CALENDAR_STATUS_COLOR[item.status] }} className="h-2.5 w-2.5 rounded-full" />
              <Text className="flex-1 text-title text-ink">{item.title}</Text>
            </View>
            <Text className="text-sm text-ink-faint">{CALENDAR_STATUS_LABEL[item.status]}</Text>
            {item.sessionId ? (
              <Text onPress={() => openEntry(item.sessionId)} className="mt-1 font-semibold text-brand">
                View replay
              </Text>
            ) : null}
          </Card>
        )}
      />
    </SafeAreaView>
  );
}

