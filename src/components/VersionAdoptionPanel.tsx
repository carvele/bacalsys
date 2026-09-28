import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { Text, View } from 'react-native';

import { Button, Card, Chip, Notice } from '@/components/ui';
import {
  MIGRATION_CHOICES,
  MIGRATION_CHOICE_COPY,
  buildMigrateArgs,
  migratableOccurrences,
  toggleId,
  validateMigration,
  type MigrationChoice,
} from '@/features/assignments/version-migration';
import { daysOfWeekSummary, formatCalendarDate } from '@/lib/date-tz';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { supabase } from '@/lib/supabase';

interface AssignmentView {
  id: string;
  title: string;
  targetCount: number;
  occurrences: { id: string; scheduledDate: string; status: string }[];
}

/**
 * Sprint 5 · Task 5.12 — the Rule C choice, surfaced right after a new sealed
 * version is published. For every ACTIVE assignment of the template the author
 * picks one of three mutually exclusive outcomes (template-only /
 * future-assignments-only / selected upcoming workouts). Only upcoming
 * occurrences are ever offered — in-progress and finished ones can never move.
 * public.migrate_assignment_version() enforces all of it (temporal authority,
 * version viewability, the 22000 safety boundary); this panel only shapes the call.
 */
export function VersionAdoptionPanel({
  templateId,
  newVersionId,
  onDone,
}: {
  templateId: string;
  newVersionId: string;
  onDone: () => void;
}) {
  const queryClient = useQueryClient();
  const [choices, setChoices] = useState<Record<string, MigrationChoice>>({});
  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [results, setResults] = useState<Record<string, { tone: 'success' | 'danger'; text: string }>>({});
  const [showErrors, setShowErrors] = useState(false);
  const [applying, setApplying] = useState(false);

  const assignments = useQuery({
    queryKey: ['template-assignments', templateId],
    queryFn: async (): Promise<AssignmentView[]> => {
      const { data, error } = await supabase
        .from('workout_assignments')
        .select(
          'id, is_recurring, target_date, recurring_schedules(days_of_week), assignment_targets(athlete_id), assignment_occurrences(id, scheduled_date, status)',
        )
        .eq('workout_template_id', templateId)
        .eq('status', 'active');
      if (error) throw error;
      return (data ?? []).map((a) => ({
        id: a.id,
        title: a.is_recurring
          ? `Recurring · ${daysOfWeekSummary(a.recurring_schedules?.days_of_week ?? [])}`
          : `One-off · ${a.target_date ? formatCalendarDate(a.target_date) : ''}`,
        targetCount: a.assignment_targets?.length ?? 0,
        occurrences: (a.assignment_occurrences ?? [])
          .map((o) => ({ id: o.id, scheduledDate: o.scheduled_date, status: o.status }))
          .sort((x, y) => x.scheduledDate.localeCompare(y.scheduledDate)),
      }));
    },
  });

  const choiceOf = (id: string): MigrationChoice => choices[id] ?? 'template_only';
  const rows = assignments.data ?? [];
  const changing = useMemo(() => rows.filter((a) => choiceOf(a.id) !== 'template_only'), [rows, choices]); // eslint-disable-line react-hooks/exhaustive-deps

  const apply = async () => {
    const invalid = changing.some((a) => validateMigration(choiceOf(a.id), selected[a.id] ?? []).selection);
    if (invalid) {
      setShowErrors(true);
      return;
    }
    setApplying(true);
    const next: typeof results = {};
    for (const a of changing) {
      const { error } = await supabase.rpc(
        'migrate_assignment_version',
        buildMigrateArgs({
          assignmentId: a.id,
          newVersionId,
          choice: choiceOf(a.id),
          selectedOccurrenceIds: selected[a.id] ?? [],
          idempotencyKey: randomId(),
        }),
      );
      next[a.id] = error
        ? {
            tone: 'danger',
            text: describeError(error, {
              '42501': 'You can no longer change this assignment — an athlete moved to another coach. Ask club leadership.',
              '22000': 'One of the selected workouts has already started or finished, so it cannot move to the new version.',
            }),
          }
        : { tone: 'success', text: 'Updated.' };
    }
    setResults(next);
    setApplying(false);
    void queryClient.invalidateQueries({ queryKey: ['template-assignments', templateId] });
    void queryClient.invalidateQueries({ queryKey: ['todays-training'] });
    if (Object.values(next).every((r) => r.tone === 'success')) onDone();
  };

  if (assignments.isPending) return <Text className="text-ink-muted">Checking who is assigned this routine…</Text>;
  if (assignments.isError) return <Notice tone="danger">{describeError(assignments.error)}</Notice>;

  return (
    <View className="gap-4">
      <Notice tone="success">The new version is published. Choose how the routine&apos;s assignments should adopt it.</Notice>
      {rows.map((a) => {
        const choice = choiceOf(a.id);
        const upcoming = migratableOccurrences(a.occurrences);
        const err = showErrors && choice === 'selected_upcoming_assignments' ? validateMigration(choice, selected[a.id] ?? []).selection : undefined;
        return (
          <Card key={a.id} className="gap-3">
            <Text className="text-base font-semibold text-ink">{a.title}</Text>
            <Text className="text-sm text-ink-faint">
              {a.targetCount} athlete{a.targetCount === 1 ? '' : 's'} · {upcoming.length} upcoming workout{upcoming.length === 1 ? '' : 's'}
            </Text>
            <View className="gap-2">
              {MIGRATION_CHOICES.map((c) => (
                <View key={c} className="gap-1">
                  <Chip label={MIGRATION_CHOICE_COPY[c].title} selected={choice === c} onPress={() => setChoices((s) => ({ ...s, [a.id]: c }))} />
                  {choice === c ? <Text className="text-sm text-ink-muted">{MIGRATION_CHOICE_COPY[c].detail}</Text> : null}
                </View>
              ))}
            </View>
            {choice === 'selected_upcoming_assignments' ? (
              <View className="gap-2">
                {upcoming.length === 0 ? <Text className="text-ink-muted">Nothing upcoming to move.</Text> : null}
                <View className="flex-row flex-wrap gap-2">
                  {upcoming.map((o) => (
                    <Chip
                      key={o.id}
                      label={formatCalendarDate(o.scheduledDate)}
                      selected={(selected[a.id] ?? []).includes(o.id)}
                      onPress={() => setSelected((s) => ({ ...s, [a.id]: toggleId(s[a.id] ?? [], o.id) }))}
                    />
                  ))}
                </View>
                {err ? <Text className="text-sm text-danger">{err}</Text> : null}
              </View>
            ) : null}
            {results[a.id] ? <Notice tone={results[a.id].tone}>{results[a.id].text}</Notice> : null}
          </Card>
        );
      })}
      <Button label={changing.length === 0 ? 'Keep everything as is' : 'Apply choices'} onPress={changing.length === 0 ? onDone : apply} loading={applying} />
    </View>
  );
}
