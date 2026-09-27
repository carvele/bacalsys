import { onlineManager, useQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ExerciseSubstitutionModal } from '@/components/ExerciseSubstitutionModal';
import { Button, Card, CenteredSpinner, Chip, Notice, TextField } from '@/components/ui';
import {
  emptyActualSet,
  summarizeActual,
  validateActualSet,
  buildSetPayload,
  type ActualSetDraft,
} from '@/features/workouts/session-player';
import { beginOnlineSession } from '@/features/workouts/session-start';
import { useWorkoutSessionStore } from '@/features/workouts/session-store';
import { labelFor, summarizeSet, type MeasurementMode } from '@/features/workouts/workout-builder';
import { useRestTimer } from '@/hooks/useRestTimer';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { supabase } from '@/lib/supabase';
import { offlineOutboxService } from '@/services/sync/outbox-sync';
import type { Json } from '@/types/database';

/**
 * Sprint 4 · Task 4.13 — Interactive Workout Player.
 *
 * Every action here checks connectivity itself: online, it calls the
 * granular RPC directly; offline, it durably journals the SAME logical
 * mutation through the outbox instead — the domain rule (F-S4-P14, mode
 * validation, idempotency) is identical either way, since both paths call
 * the same server functions eventually.
 */
export default function ActiveWorkoutScreen() {
  const { versionId } = useLocalSearchParams<{ versionId: string }>();
  const activeSession = useWorkoutSessionStore((s) => s.active);
  const begin = useWorkoutSessionStore((s) => s.begin);
  const setSessionId = useWorkoutSessionStore((s) => s.setSessionId);
  const addSubstitution = useWorkoutSessionStore((s) => s.addSubstitution);
  const addLoggedSet = useWorkoutSessionStore((s) => s.addLoggedSet);

  const [error, setError] = useState<string | null>(null);
  const [submittingSet, setSubmittingSet] = useState<string | null>(null); // workoutItemId currently submitting
  const [substitutingItemId, setSubstitutingItemId] = useState<string | null>(null);
  const [substituting, setSubstituting] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [draft, setDraft] = useState<ActualSetDraft>(emptyActualSet());
  const restTimer = useRestTimer();

  const hierarchyKey = ['workout-version-hierarchy', versionId] as const;
  const hierarchy = useQuery({
    queryKey: hierarchyKey,
    enabled: !!versionId,
    queryFn: async () => {
      const { data: blocks, error: blocksError } = await supabase
        .from('workout_blocks')
        .select('*')
        .eq('workout_version_id', versionId)
        .order('order_in_workout');
      if (blocksError) throw blocksError;
      const withItems = await Promise.all(
        (blocks ?? []).map(async (block) => {
          const { data: items, error: itemsError } = await supabase
            .from('workout_items')
            .select('*, exercises(id, name, measurement_types)')
            .eq('block_id', block.id)
            .order('order_in_block');
          if (itemsError) throw itemsError;
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

  // Flattens blocks -> items into one linear sequence for the step-by-step player.
  const steps = useMemo(
    () => (hierarchy.data ?? []).flatMap((b) => b.items.map((it) => ({ block: b.block, ...it }))),
    [hierarchy.data],
  );

  // Begin (or resume) the session once the hierarchy is known. `activeSession`
  // itself (a Zustand store, not React state) is the loading signal below —
  // no separate "starting" state, so nothing here calls a React setState
  // synchronously inside the effect body (react-hooks/set-state-in-effect).
  useEffect(() => {
    if (!versionId || hierarchy.isLoading || activeSession) return;
    let cancelled = false;
    (async () => {
      const correlationId = begin(versionId);
      const idempotencyKey = randomId();
      if (onlineManager.isOnline()) {
        const { data, error: startError } = await supabase.rpc('start_workout_session', {
          p_workout_version_id: versionId,
          p_idempotency_key: idempotencyKey,
        });
        if (cancelled) return;
        if (startError) {
          setError(describeError(startError));
        } else {
          const result = data as { session_id: string; exercise_mapping: Record<string, string> };
          // F-S4-02 (narrow re-review): ordering/fail-closed invariant lives
          // in session-start.ts, tested independently of this screen's other
          // concerns — see beginOnlineSession's own doc comment.
          await beginOnlineSession(
            { sessionId: result.session_id, exerciseMapping: result.exercise_mapping ?? {} },
            {
              persistHandshake: (h) => offlineOutboxService.persistHandshake(correlationId, h),
              onReady: (h) => {
                if (!cancelled) setSessionId(h.sessionId, h.exerciseMapping);
              },
              onError: (err) => {
                if (!cancelled) setError(describeError(err));
              },
            },
          );
        }
      } else {
        await offlineOutboxService.enqueueGranular({
          id: correlationId,
          sessionCorrelationId: correlationId,
          mutationType: 'START_SESSION',
          entityId: versionId,
          payload: { workout_version_id: versionId },
        });
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [versionId, hierarchy.isLoading, activeSession]);

  // Online: wait for the session_id to come back before allowing any action
  // (a set/substitution logged too early would wrongly fall through to the
  // offline outbox). Offline: the session is usable as soon as begin() ran.
  const isAwaitingStart = !activeSession || (onlineManager.isOnline() && activeSession.sessionId === null);

  if (!versionId) return <CenteredSpinner label="Loading…" />;
  if (hierarchy.isLoading || isAwaitingStart) return <CenteredSpinner label="Starting your workout…" />;
  if (hierarchy.isError) {
    return (
      <SafeAreaView className="flex-1 items-center justify-center bg-surface p-6">
        <Notice tone="danger">{describeError(hierarchy.error)}</Notice>
      </SafeAreaView>
    );
  }
  if (steps.length === 0) {
    return (
      <SafeAreaView className="flex-1 items-center justify-center bg-surface p-6">
        <Notice tone="danger">This routine has no exercises.</Notice>
      </SafeAreaView>
    );
  }

  const step = steps[Math.min(currentIndex, steps.length - 1)];
  const substitution = activeSession.substitutions[step.item.id];
  const effectiveName = substitution?.replacementExerciseName ?? step.exercise?.name ?? 'Exercise';
  const effectiveMode = (substitution?.performedMeasurementMode ?? step.item.measurement_mode) as MeasurementMode;
  const logged = activeSession.loggedSets[step.item.id] ?? [];
  const hasLoggedSets = logged.length > 0;
  const isLast = currentIndex === steps.length - 1;

  const dispatchSubstitution = async (args: { replacementExerciseId: string; performedMeasurementMode: MeasurementMode; reasonCode: string; replacementExerciseName: string }) => {
    setSubstituting(true);
    setError(null);
    const idempotencyKey = randomId();
    if (onlineManager.isOnline() && activeSession.sessionId) {
      const { error: subError } = await supabase.rpc('record_exercise_substitution', {
        p_session_id: activeSession.sessionId,
        p_original_workout_item_id: step.item.id,
        p_replacement_exercise_id: args.replacementExerciseId,
        p_performed_measurement_mode: args.performedMeasurementMode,
        p_reason_code: args.reasonCode,
        p_idempotency_key: idempotencyKey,
      });
      if (subError) {
        setError(describeError(subError, { '22000': 'You cannot substitute this exercise after logging a set for it.' }));
        setSubstituting(false);
        return;
      }
    } else {
      await offlineOutboxService.enqueueGranular({
        id: idempotencyKey,
        sessionCorrelationId: activeSession.sessionCorrelationId,
        mutationType: 'SUBSTITUTE_EXERCISE',
        entityId: step.item.id,
        payload: {
          original_workout_item_id: step.item.id,
          replacement_exercise_id: args.replacementExerciseId,
          performed_measurement_mode: args.performedMeasurementMode,
          reason_code: args.reasonCode,
        },
      });
    }
    addSubstitution({
      originalWorkoutItemId: step.item.id,
      replacementExerciseId: args.replacementExerciseId,
      replacementExerciseName: args.replacementExerciseName,
      performedMeasurementMode: args.performedMeasurementMode,
      reasonCode: args.reasonCode,
    });
    setSubstituting(false);
    setSubstitutingItemId(null);
  };

  const dispatchSet = async (prescribedSetId: string | null, setNumber: number, restSeconds: number) => {
    const validationError = validateActualSet(effectiveMode, draft);
    if (validationError) {
      setError(validationError);
      return;
    }
    setSubmittingSet(step.item.id);
    setError(null);
    const setData = buildSetPayload(setNumber, prescribedSetId, draft);
    const idempotencyKey = randomId();
    if (onlineManager.isOnline() && activeSession.sessionId) {
      const sessionExerciseId = activeSession.exerciseMapping[step.item.id];
      const { error: setError_ } = await supabase.rpc('record_session_set', {
        p_session_id: activeSession.sessionId,
        p_session_exercise_id: sessionExerciseId,
        p_set_data: setData as unknown as Json,
        p_idempotency_key: idempotencyKey,
      });
      if (setError_) {
        setError(describeError(setError_));
        setSubmittingSet(null);
        return;
      }
    } else {
      await offlineOutboxService.enqueueGranular({
        id: idempotencyKey,
        sessionCorrelationId: activeSession.sessionCorrelationId,
        mutationType: 'RECORD_SET',
        entityId: step.item.id,
        payload: { workout_item_id: step.item.id, set_data: setData as unknown as Json },
      });
    }
    addLoggedSet({ workoutItemId: step.item.id, setNumber, prescribedItemSetId: prescribedSetId, draft });
    setDraft(emptyActualSet());
    setSubmittingSet(null);
    if (!(isLast && logged.length + 1 >= step.sets.length)) {
      void restTimer.start(restSeconds);
    }
  };

  const nextPrescribed = step.sets[logged.length];
  const restSecondsDefault = nextPrescribed?.target_rest_seconds ?? 60;

  return (
    <SafeAreaView className="flex-1 bg-surface">
      <ScrollView contentContainerClassName="w-full max-w-[480px] flex-1 self-center gap-4 p-4">
        <Text className="text-sm text-ink-muted">
          {step.block.title} · {labelFor(step.block.block_type)} · Exercise {currentIndex + 1} of {steps.length}
        </Text>
        <Text className="text-display text-ink">{effectiveName}</Text>
        {substitution ? <Notice tone="warning">Substituted for {step.exercise?.name} ({labelFor(substitution.reasonCode)})</Notice> : null}
        {error ? <Notice tone="danger">{error}</Notice> : null}

        {restTimer.isActive ? (
          <Card className="items-center gap-1 bg-brand-soft">
            <Text className="text-sm font-medium text-ink-muted">Resting</Text>
            <Text className="text-display text-ink">{restTimer.remainingSeconds}s</Text>
            <Button label="Skip rest" variant="ghost" onPress={restTimer.skip} />
          </Card>
        ) : null}

        <Card className="gap-3">
          <Text className="text-base font-semibold text-ink">Sets</Text>
          {step.sets.map((s: any, i: number) => {
            const done = logged[i];
            return (
              <View key={s.id} className="flex-row items-center justify-between rounded-control border border-surface-border p-2">
                <Text className="text-ink-muted">
                  Set {i + 1} · target {summarizeSet(effectiveMode, s)}
                </Text>
                {done ? (
                  <Text className="text-success">{summarizeActual(effectiveMode, done.draft)}</Text>
                ) : (
                  <Text className="text-ink-muted">Not logged</Text>
                )}
              </View>
            );
          })}
          {logged.length > step.sets.length - 1 && logged.slice(step.sets.length).map((extra, i) => (
            <View key={`extra-${i}`} className="flex-row items-center justify-between rounded-control border border-surface-border p-2">
              <Text className="text-ink-muted">Extra set {step.sets.length + i + 1}</Text>
              <Text className="text-success">{summarizeActual(effectiveMode, extra.draft)}</Text>
            </View>
          ))}

          <ActualSetFields mode={effectiveMode} draft={draft} onChange={(patch) => setDraft((d) => ({ ...d, ...patch }))} />
          <Button
            label={nextPrescribed ? `Log set ${logged.length + 1}` : `Log extra set ${logged.length + 1}`}
            loading={submittingSet === step.item.id}
            onPress={() => dispatchSet(nextPrescribed?.id ?? null, logged.length + 1, restSecondsDefault)}
          />
        </Card>

        <Button
          label="Swap this exercise"
          variant="secondary"
          disabled={hasLoggedSets}
          onPress={() => setSubstitutingItemId(step.item.id)}
        />

        <View className="flex-row gap-3">
          {currentIndex > 0 ? (
            <View className="flex-1">
              <Button label="Previous" variant="secondary" onPress={() => setCurrentIndex((i) => Math.max(0, i - 1))} />
            </View>
          ) : null}
          {!isLast ? (
            <View className="flex-1">
              <Button label="Next exercise" onPress={() => setCurrentIndex((i) => Math.min(steps.length - 1, i + 1))} />
            </View>
          ) : null}
        </View>

        <Button
          label="Finish workout"
          variant={isLast ? 'primary' : 'ghost'}
          onPress={() => router.push({ pathname: '/workout/summary' })}
        />
      </ScrollView>

      <ExerciseSubstitutionModal
        visible={substitutingItemId === step.item.id}
        originalExerciseName={step.exercise?.name ?? 'this exercise'}
        hasLoggedSets={hasLoggedSets}
        submitting={substituting}
        onClose={() => setSubstitutingItemId(null)}
        onSubstitute={(args) => void dispatchSubstitution(args)}
      />
    </SafeAreaView>
  );
}

function ActualSetFields({
  mode,
  draft,
  onChange,
}: {
  mode: MeasurementMode;
  draft: ActualSetDraft;
  onChange: (patch: Partial<ActualSetDraft>) => void;
}) {
  const showReps = ['reps', 'added_weight', 'assisted_weight', 'until_failure', 'technique_practice'].includes(mode);
  const showDuration = ['duration', 'holds', 'added_weight', 'assisted_weight', 'until_failure', 'technique_practice'].includes(mode);
  const showDistance = mode === 'distance';
  const showLoad = mode === 'added_weight' || mode === 'assisted_weight';
  return (
    <View className="gap-2">
      <View className="flex-row flex-wrap gap-2">
        {showReps ? (
          <View className="w-24">
            <TextField label="Reps" keyboardType="number-pad" value={draft.actualReps} onChangeText={(v) => onChange({ actualReps: v })} />
          </View>
        ) : null}
        {showDuration ? (
          <View className="w-28">
            <TextField label="Seconds" keyboardType="number-pad" value={draft.actualDurationSeconds} onChangeText={(v) => onChange({ actualDurationSeconds: v })} />
          </View>
        ) : null}
        {showDistance ? (
          <View className="w-28">
            <TextField label="Meters" keyboardType="decimal-pad" value={draft.actualDistanceMeters} onChangeText={(v) => onChange({ actualDistanceMeters: v })} />
          </View>
        ) : null}
        {showLoad ? (
          <View className="w-24">
            <TextField
              label="Load kg"
              keyboardType="decimal-pad"
              value={draft.actualLoadKg}
              onChangeText={(v) => onChange({ actualLoadKg: v, loadType: mode === 'added_weight' ? 'added' : 'assisted' })}
            />
          </View>
        ) : null}
        <View className="w-20">
          <TextField label="RPE" keyboardType="decimal-pad" value={draft.rpe} onChangeText={(v) => onChange({ rpe: v })} />
        </View>
      </View>
      <View className="flex-row gap-2">
        <Chip label="Completed" selected={draft.isCompleted} onPress={() => onChange({ isCompleted: true })} />
        <Chip label="Not completed" selected={!draft.isCompleted} onPress={() => onChange({ isCompleted: false })} />
      </View>
    </View>
  );
}
