import { onlineManager, useQuery } from '@tanstack/react-query';
import { router } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, CenteredSpinner, Chip, Notice, TextField } from '@/components/ui';
import {
  ABANDONMENT_REASONS,
  buildFeedbackPayloads,
  buildOfflineBundle,
  emptySplitFeedback,
  summarizeActual,
  validateAbandonment,
  type SplitFeedbackDraft,
} from '@/features/workouts/session-player';
import { useWorkoutSessionStore } from '@/features/workouts/session-store';
import { labelFor, summarizeSet } from '@/features/workouts/workout-builder';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { supabase } from '@/lib/supabase';
import { offlineOutboxService } from '@/services/sync/outbox-sync';
import type { Json } from '@/types/database';

/**
 * Sprint 4 · Task 4.14 — Post-Workout Summary & Split Feedback.
 *
 * Reads the same in-memory session draft `active.tsx` built up (see
 * session-store.ts). Substitutions and sets already reached the server (or
 * the durable outbox) one at a time as the athlete progressed; this screen
 * only needs to submit the final outcome + Rule E split feedback.
 *
 * Scope note (see Sprint 4 STATUS.md "What was not verified"): if the session
 * ever went offline mid-workout, completion always uses the coalesced
 * SYNC_BUNDLE path here (safe even if connectivity has since returned) rather
 * than risk racing already-synced granular mutations against a fresh direct
 * `complete_workout_session` call.
 */
export default function WorkoutSummaryScreen() {
  const activeSession = useWorkoutSessionStore((s) => s.active);
  const clearSession = useWorkoutSessionStore((s) => s.clear);
  const [status, setStatus] = useState<'completed' | 'abandoned'>('completed');
  const [reasonCode, setReasonCode] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<SplitFeedbackDraft>(emptySplitFeedback());
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);

  const hierarchy = useQuery({
    queryKey: ['workout-version-hierarchy', activeSession?.workoutVersionId],
    enabled: !!activeSession,
    queryFn: async () => {
      const { data: blocks, error: blocksError } = await supabase
        .from('workout_blocks')
        .select('*')
        .eq('workout_version_id', activeSession!.workoutVersionId)
        .order('order_in_workout');
      if (blocksError) throw blocksError;
      const withItems = await Promise.all(
        (blocks ?? []).map(async (block) => {
          const { data: items } = await supabase
            .from('workout_items')
            .select('*, exercises(id, name)')
            .eq('block_id', block.id)
            .order('order_in_block');
          const withSets = await Promise.all(
            (items ?? []).map(async (item) => {
              const { data: sets } = await supabase.from('workout_item_sets').select('*').eq('workout_item_id', item.id).order('set_number');
              return { item, exercise: item.exercises, sets: sets ?? [] };
            }),
          );
          return { block, items: withSets };
        }),
      );
      return withItems;
    },
  });

  const steps = useMemo(() => (hierarchy.data ?? []).flatMap((b) => b.items), [hierarchy.data]);

  useEffect(() => {
    if (!activeSession && !done) router.replace('/workouts');
  }, [activeSession, done]);

  if (!activeSession) return <CenteredSpinner />;
  if (hierarchy.isLoading) return <CenteredSpinner label="Loading summary…" />;

  const submit = async () => {
    setError(null);
    const abandonError = validateAbandonment(status, status === 'abandoned' ? reasonCode : null);
    if (abandonError) {
      setError(abandonError);
      return;
    }
    setSubmitting(true);
    const { feedback: feedbackPayload, privateFeedback } = buildFeedbackPayloads(feedback);
    const completedAt = new Date().toISOString();

    const hadAnyOfflineActivity =
      activeSession.sessionId === null || (await offlineOutboxService.pendingForSession(activeSession.sessionCorrelationId)).length > 0;

    if (!hadAnyOfflineActivity && onlineManager.isOnline() && activeSession.sessionId) {
      const { error: completeError } = await supabase.rpc('complete_workout_session', {
        p_session_id: activeSession.sessionId,
        p_status: status,
        p_abandonment_reason_code: (status === 'abandoned' ? reasonCode : null) as string,
        p_feedback: feedbackPayload as Json,
        p_private_feedback: privateFeedback as Json,
        p_idempotency_key: randomId(),
      });
      if (completeError) {
        setError(describeError(completeError));
        setSubmitting(false);
        return;
      }
    } else {
      const bundle = buildOfflineBundle({
        sessionCorrelationId: activeSession.sessionCorrelationId,
        existingSessionId: activeSession.sessionId,
        workoutVersionId: activeSession.workoutVersionId,
        status,
        abandonmentReasonCode: status === 'abandoned' ? reasonCode : null,
        startedAt: activeSession.startedAt,
        completedAt,
        substitutions: Object.values(activeSession.substitutions).map((s) => ({
          originalWorkoutItemId: s.originalWorkoutItemId,
          replacementExerciseId: s.replacementExerciseId,
          performedMeasurementMode: s.performedMeasurementMode,
          reasonCode: s.reasonCode,
        })),
        sets: Object.values(activeSession.loggedSets).flat(),
        feedback: feedbackPayload,
        privateFeedback,
      });
      await offlineOutboxService.enqueueBundle(activeSession.sessionCorrelationId, bundle);
    }

    setDone(true);
    clearSession();
    setSubmitting(false);
    router.replace('/workouts');
  };

  return (
    <SafeAreaView className="flex-1 bg-surface">
      <ScrollView contentContainerClassName="w-full max-w-[480px] flex-1 self-center gap-4 p-4">
        <Text className="text-display text-ink">Workout summary</Text>
        {error ? <Notice tone="danger">{error}</Notice> : null}

        <Card className="gap-2">
          <Text className="text-base font-semibold text-ink">Prescribed vs actual</Text>
          {steps.map((step) => {
            const substitution = activeSession.substitutions[step.item.id];
            const logged = activeSession.loggedSets[step.item.id] ?? [];
            return (
              <View key={step.item.id} className="gap-1 border-b border-surface-border pb-2">
                <Text className="font-semibold text-ink">
                  {substitution ? `${substitution.replacementExerciseName} (was ${step.exercise?.name})` : step.exercise?.name}
                </Text>
                {step.sets.map((s: any, i: number) => (
                  <Text key={s.id} className="text-sm text-ink-muted">
                    Set {i + 1}: {summarizeSet(step.item.measurement_mode, s)} →{' '}
                    {logged[i] ? summarizeActual(substitution?.performedMeasurementMode ?? step.item.measurement_mode, logged[i].draft) : 'not logged'}
                  </Text>
                ))}
              </View>
            );
          })}
        </Card>

        <Card className="gap-3">
          <Text className="text-base font-semibold text-ink">How did it go?</Text>
          <View className="flex-row gap-2">
            <Chip label="Finished the workout" selected={status === 'completed'} onPress={() => setStatus('completed')} />
            <Chip label="Ending early" selected={status === 'abandoned'} onPress={() => setStatus('abandoned')} />
          </View>
          {status === 'abandoned' ? (
            <View className="flex-row flex-wrap gap-2">
              {ABANDONMENT_REASONS.map((r) => (
                <Chip key={r} label={labelFor(r)} selected={reasonCode === r} onPress={() => setReasonCode(r)} />
              ))}
            </View>
          ) : null}
        </Card>

        <Card className="gap-3">
          <Text className="text-base font-semibold text-ink">Ordinary feedback</Text>
          <Text className="text-sm text-ink-muted">Difficulty (1–10)</Text>
          <View className="flex-row flex-wrap gap-2">
            {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => (
              <Chip key={n} label={String(n)} selected={feedback.difficultyRating === n} onPress={() => setFeedback((f) => ({ ...f, difficultyRating: n }))} />
            ))}
          </View>
          <Text className="text-sm text-ink-muted">Energy (1–5)</Text>
          <View className="flex-row flex-wrap gap-2">
            {Array.from({ length: 5 }, (_, i) => i + 1).map((n) => (
              <Chip key={n} label={String(n)} selected={feedback.energyLevel === n} onPress={() => setFeedback((f) => ({ ...f, energyLevel: n }))} />
            ))}
          </View>
        </Card>

        <Card className="gap-3">
          <Text className="text-base font-semibold text-ink">Private feedback</Text>
          <Notice tone="warning">Only you, your current coach, and club executives with special permission can ever see this.</Notice>
          <View className="flex-row gap-2">
            <Chip label="No discomfort" selected={!feedback.hasDiscomfort} onPress={() => setFeedback((f) => ({ ...f, hasDiscomfort: false, discomfortArea: '' }))} />
            <Chip label="I felt discomfort" selected={feedback.hasDiscomfort} onPress={() => setFeedback((f) => ({ ...f, hasDiscomfort: true }))} />
          </View>
          {feedback.hasDiscomfort ? (
            <TextField
              label="Where?"
              value={feedback.discomfortArea}
              onChangeText={(v) => setFeedback((f) => ({ ...f, discomfortArea: v }))}
              placeholder="e.g. Left shoulder"
            />
          ) : null}
          <TextField
            label="Note to your coach (optional)"
            value={feedback.noteToCoach}
            onChangeText={(v) => setFeedback((f) => ({ ...f, noteToCoach: v }))}
            multiline
          />
        </Card>

        <Button label="Submit" loading={submitting} onPress={submit} />
      </ScrollView>
    </SafeAreaView>
  );
}
