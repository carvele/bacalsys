import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useRef, useState } from 'react';
import { Modal, ScrollView, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, Chip, Notice, TextField } from '@/components/ui';
import { activePositions, displayName, type MemberRow } from '@/features/coaching/coach-roster';
import {
  buildCreateAssignmentArgs,
  emptyAssignDraft,
  filterAthletes,
  isAssignDraftValid,
  toggleAllVisible,
  toggleAthlete,
  validateAssignDraft,
  type AssignDraft,
  type AthleteOption,
} from '@/features/assignments/assignment-form';
import { useOrgTimezone } from '@/features/assignments/use-org-timezone';
import { WEEKDAYS, normalizeDays, todayIso } from '@/lib/date-tz';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/features/auth/use-auth';
import { hasPermission } from '@/features/auth/access';

/**
 * Sprint 5 · Task 5.11 — assign a routine to one or more athletes, once or on a
 * recurring weekday schedule (Section 12, "Mobile & Frontend Architecture" 1).
 *
 * Athlete picker: a Coach sees the athletes they currently coach; leadership
 * (Leader / VP / President, training:view_org) additionally sees the roster they
 * are allowed to read. UX only — public.create_workout_assignment() re-validates
 * scope, version viewability, schedule shape and timezone on the server.
 *
 * Idempotent submit: one idempotency key per distinct payload. Retrying the SAME
 * request after a dropped connection re-uses the key (the server returns the
 * original assignment), while editing the form mints a fresh key.
 */
export function AssignWorkoutModal({
  visible,
  onClose,
  templateId: fixedTemplateId,
  initialAthleteIds = [],
  onAssigned,
}: {
  visible: boolean;
  onClose: () => void;
  /** When omitted, the modal first asks which routine to assign. */
  templateId?: string;
  initialAthleteIds?: string[];
  onAssigned?: () => void;
}) {
  const { profile, access } = useAuth();
  const queryClient = useQueryClient();
  const timezone = useOrgTimezone();
  const today = todayIso(timezone);
  const leadership = hasPermission(access, 'training:view_org');

  const [pickedTemplateId, setPickedTemplateId] = useState<string | null>(null);
  const templateId = fixedTemplateId ?? pickedTemplateId;
  const [draft, setDraft] = useState<AssignDraft>(() => emptyAssignDraft(today, initialAthleteIds));
  const [query, setQuery] = useState('');
  const [showErrors, setShowErrors] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const keyRef = useRef<{ signature: string; key: string } | null>(null);

  const patch = (p: Partial<AssignDraft>) => {
    setDraft((d) => ({ ...d, ...p }));
    setMessage(null);
  };

  const templates = useQuery({
    queryKey: ['assignable-templates'],
    enabled: visible && !fixedTemplateId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('workout_templates')
        .select('id, name, visibility')
        .eq('is_archived', false)
        .order('name');
      if (error) throw error;
      return data;
    },
  });

  const versions = useQuery({
    queryKey: ['assignable-versions', templateId],
    enabled: visible && !!templateId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('workout_versions')
        .select('id, version_number, notes, is_sealed')
        .eq('template_id', templateId!)
        .eq('is_sealed', true)
        .order('version_number', { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  const athletes = useQuery({
    queryKey: ['assignable-athletes', profile?.id, leadership],
    enabled: visible && !!profile?.id,
    queryFn: async (): Promise<AthleteOption[]> => {
      const byId = new Map<string, AthleteOption>();
      const coached = await supabase
        .from('coach_assignments')
        .select('athlete:profiles!coach_assignments_athlete_id_fkey(id, full_name)')
        .is('ended_at', null);
      if (coached.error) throw coached.error;
      for (const row of coached.data ?? []) {
        if (row.athlete) byId.set(row.athlete.id, { id: row.athlete.id, name: displayName(row.athlete.full_name) });
      }
      if (leadership) {
        const roster = await supabase
          .from('profiles')
          .select('id, full_name, member_positions!member_positions_profile_id_fkey(ended_at, positions(name))')
          .eq('status', 'active');
        if (!roster.error) {
          for (const m of (roster.data ?? []) as MemberRow[]) {
            if (activePositions(m).includes('Athlete')) byId.set(m.id, { id: m.id, name: displayName(m.full_name) });
          }
        }
      }
      return Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name));
    },
  });

  const visibleAthletes = useMemo(() => filterAthletes(athletes.data ?? [], query), [athletes.data, query]);
  const errors = validateAssignDraft(draft, today);
  const valid = isAssignDraftValid(errors) && !!templateId;

  const close = () => {
    setPickedTemplateId(null);
    setDraft(emptyAssignDraft(today, initialAthleteIds));
    setQuery('');
    setShowErrors(false);
    setMessage(null);
    keyRef.current = null;
    onClose();
  };

  const submit = async () => {
    if (!valid || !templateId) {
      setShowErrors(true);
      return;
    }
    const withoutKey = buildCreateAssignmentArgs(draft, { templateId, timezone, idempotencyKey: '' });
    const signature = JSON.stringify({ ...withoutKey, p_idempotency_key: undefined });
    if (keyRef.current?.signature !== signature) keyRef.current = { signature, key: randomId() };
    setSubmitting(true);
    setMessage(null);
    const { data, error } = await supabase.rpc('create_workout_assignment', { ...withoutKey, p_idempotency_key: keyRef.current.key });
    setSubmitting(false);
    if (error) {
      setMessage({
        tone: 'danger',
        text: describeError(error, {
          '42501': 'You can only assign to athletes you coach (or, as club leadership, in your organization), using routines you can see.',
          '22000': 'That routine has no sealed version to assign.',
        }),
      });
      return;
    }
    const created = (data as { occurrences_created?: number } | null)?.occurrences_created ?? 0;
    setMessage({ tone: 'success', text: `Assigned. ${created} workout${created === 1 ? '' : 's'} scheduled.` });
    keyRef.current = null;
    void queryClient.invalidateQueries({ queryKey: ['todays-training'] });
    void queryClient.invalidateQueries({ queryKey: ['coach-upcoming-occurrences'] });
    void queryClient.invalidateQueries({ queryKey: ['template-assignments'] });
    onAssigned?.();
  };

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={close}>
      <SafeAreaView className="flex-1 bg-surface">
        <ScrollView contentContainerClassName="w-full max-w-[640px] self-center gap-4 p-4" keyboardShouldPersistTaps="handled">
          <Text className="text-title text-ink">Assign workout</Text>
          {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}

          {!fixedTemplateId ? (
            <Card className="gap-2">
              <Text className="text-base font-semibold text-ink">Routine</Text>
              {templates.isPending ? <Text className="text-ink-muted">Loading routines…</Text> : null}
              {templates.isError ? <Notice tone="danger">{describeError(templates.error)}</Notice> : null}
              <View className="flex-row flex-wrap gap-2">
                {(templates.data ?? []).map((t) => (
                  <Chip key={t.id} label={t.name} selected={pickedTemplateId === t.id} onPress={() => { setPickedTemplateId(t.id); patch({ versionId: null }); }} />
                ))}
              </View>
              {showErrors && !templateId ? <Text className="text-sm text-danger">Pick a routine.</Text> : null}
            </Card>
          ) : null}

          <Card className="gap-3">
            <Text className="text-base font-semibold text-ink">Athletes</Text>
            <TextField label="Search athletes" value={query} onChangeText={setQuery} autoCorrect={false} />
            <Button
              label="Select all shown"
              variant="secondary"
              disabled={visibleAthletes.length === 0}
              onPress={() => patch({ athleteIds: toggleAllVisible(draft.athleteIds, visibleAthletes) })}
            />
            {athletes.isPending ? <Text className="text-ink-muted">Loading athletes…</Text> : null}
            {athletes.isError ? <Notice tone="danger">{describeError(athletes.error)}</Notice> : null}
            {!athletes.isPending && (athletes.data ?? []).length === 0 ? (
              <Text className="text-ink-muted">You have no athletes to assign to yet.</Text>
            ) : null}
            <View className="flex-row flex-wrap gap-2">
              {visibleAthletes.map((a) => (
                <Chip key={a.id} label={a.name} selected={draft.athleteIds.includes(a.id)} onPress={() => patch({ athleteIds: toggleAthlete(draft.athleteIds, a.id) })} />
              ))}
            </View>
            <Text className="text-sm text-ink-faint">{draft.athleteIds.length} selected</Text>
            {showErrors && errors.athletes ? <Text className="text-sm text-danger">{errors.athletes}</Text> : null}
          </Card>

          <Card className="gap-3">
            <Text className="text-base font-semibold text-ink">Schedule</Text>
            <View className="flex-row gap-2">
              <Chip label="Single date" selected={draft.mode === 'single'} onPress={() => patch({ mode: 'single' })} />
              <Chip label="Recurring" selected={draft.mode === 'recurring'} onPress={() => patch({ mode: 'recurring' })} />
            </View>
            {draft.mode === 'single' ? (
              <TextField
                label="Date (YYYY-MM-DD)"
                value={draft.targetDate}
                onChangeText={(v) => patch({ targetDate: v })}
                autoCapitalize="none"
                autoCorrect={false}
                error={showErrors ? errors.targetDate : null}
              />
            ) : (
              <>
                <Text className="text-sm text-ink-muted">Repeats on</Text>
                <View className="flex-row flex-wrap gap-2">
                  {WEEKDAYS.map((d) => (
                    <Chip
                      key={d.iso}
                      label={d.short}
                      selected={draft.days.includes(d.iso)}
                      onPress={() => patch({ days: normalizeDays(draft.days.includes(d.iso) ? draft.days.filter((x) => x !== d.iso) : [...draft.days, d.iso]) })}
                    />
                  ))}
                </View>
                {showErrors && errors.days ? <Text className="text-sm text-danger">{errors.days}</Text> : null}
                <TextField label="Start date (YYYY-MM-DD)" value={draft.startDate} onChangeText={(v) => patch({ startDate: v })} autoCapitalize="none" autoCorrect={false} error={showErrors ? errors.startDate : null} />
                <TextField label="End date (optional)" value={draft.endDate} onChangeText={(v) => patch({ endDate: v })} autoCapitalize="none" autoCorrect={false} error={showErrors ? errors.endDate : null} />
                <Text className="text-sm text-ink-faint">
                  Workouts are scheduled two weeks ahead in {timezone} and topped up every day.
                </Text>
              </>
            )}
          </Card>

          {templateId ? (
            <Card className="gap-2">
              <Text className="text-base font-semibold text-ink">Version</Text>
              <View className="flex-row flex-wrap gap-2">
                <Chip label="Latest" selected={draft.versionId === null} onPress={() => patch({ versionId: null })} />
                {(versions.data ?? []).map((v) => (
                  <Chip key={v.id} label={`v${v.version_number}`} selected={draft.versionId === v.id} onPress={() => patch({ versionId: v.id })} />
                ))}
              </View>
              {draft.versionId ? (
                <Text className="text-sm text-ink-muted">{(versions.data ?? []).find((v) => v.id === draft.versionId)?.notes || 'No changelog note.'}</Text>
              ) : null}
            </Card>
          ) : null}

          <Card className="gap-2">
            <TextField label="Notes for the athletes (optional)" value={draft.notes} onChangeText={(v) => patch({ notes: v })} multiline placeholder="Coaching cues…" error={showErrors ? errors.notes : null} />
            <Text className="text-sm text-ink-faint">{draft.notes.length}/2000</Text>
          </Card>

          <Button label="Assign" onPress={submit} loading={submitting} />
          <Button label={message?.tone === 'success' ? 'Done' : 'Cancel'} variant="ghost" onPress={close} />
        </ScrollView>
      </SafeAreaView>
    </Modal>
  );
}
