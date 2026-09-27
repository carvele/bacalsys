import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Modal, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Chip, Notice, TextField } from '@/components/ui';
import { itemModesFor, labelFor, type MeasurementMode } from '@/features/workouts/workout-builder';
import { MODIFICATION_REASONS, type ModificationReason } from '@/features/workouts/session-player';
import { supabase } from '@/lib/supabase';

type ExerciseOption = { id: string; name: string; measurement_types: string[] };

/**
 * Sprint 4 · Task 4.12. Lets the athlete swap a prescribed exercise for
 * another during an active session. F-S4-P14: once the item's first set has
 * been logged, substitution is client-disabled (server independently
 * enforces the same rule with 22000 either way).
 */
export function ExerciseSubstitutionModal({
  visible,
  originalExerciseName,
  hasLoggedSets,
  submitting = false,
  onClose,
  onSubstitute,
}: {
  visible: boolean;
  originalExerciseName: string;
  /** F-S4-P14: true once any session_sets row exists for this item. */
  hasLoggedSets: boolean;
  submitting?: boolean;
  onClose: () => void;
  onSubstitute: (args: {
    replacementExerciseId: string;
    replacementExerciseName: string;
    performedMeasurementMode: MeasurementMode;
    reasonCode: ModificationReason;
  }) => void;
}) {
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<ExerciseOption | null>(null);
  const [mode, setMode] = useState<MeasurementMode | null>(null);
  const [reason, setReason] = useState<ModificationReason | null>(null);

  const exercises = useQuery({
    queryKey: ['substitution-exercises'],
    enabled: visible && !hasLoggedSets,
    queryFn: async () => {
      const { data, error } = await supabase.from('exercises').select('id, name, measurement_types, status, is_official');
      if (error) throw error;
      return (data ?? []).filter((e) => e.status === 'approved' && e.is_official) as ExerciseOption[];
    },
  });
  const rows = (exercises.data ?? []).filter((e) => e.name.toLowerCase().includes(query.trim().toLowerCase()));

  const reset = () => {
    setQuery('');
    setSelected(null);
    setMode(null);
    setReason(null);
  };
  const close = () => {
    reset();
    onClose();
  };

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={close}>
      <SafeAreaView className="flex-1 bg-surface">
        <View className="w-full max-w-[640px] flex-1 self-center gap-3 p-4">
          <Text className="text-title text-ink">Swap {originalExerciseName}</Text>

          {hasLoggedSets ? (
            <Notice tone="warning">
              Substitutions must be made before starting sets for this exercise. Finish this exercise as prescribed,
              or substitute it next time.
            </Notice>
          ) : !selected ? (
            <>
              <TextField label="Search" value={query} onChangeText={setQuery} autoCorrect={false} />
              <View className="gap-2">
                {rows.map((ex) => (
                  <Button key={ex.id} label={ex.name} variant="secondary" onPress={() => setSelected(ex)} />
                ))}
              </View>
            </>
          ) : (
            <View className="gap-4">
              <Text className="text-base text-ink-muted">Replacing with {selected.name}</Text>

              <View className="gap-2">
                <Text className="text-sm font-medium text-ink-muted">How will you measure it?</Text>
                <View className="flex-row flex-wrap gap-2">
                  {itemModesFor(selected.measurement_types).map((m) => (
                    <Chip key={m} label={labelFor(m)} selected={mode === m} onPress={() => setMode(m)} />
                  ))}
                </View>
              </View>

              <View className="gap-2">
                <Text className="text-sm font-medium text-ink-muted">Why are you substituting?</Text>
                <View className="flex-row flex-wrap gap-2">
                  {MODIFICATION_REASONS.map((r) => (
                    <Chip key={r} label={labelFor(r)} selected={reason === r} onPress={() => setReason(r)} />
                  ))}
                </View>
              </View>

              <Button
                label="Confirm swap"
                loading={submitting}
                disabled={!mode || !reason}
                onPress={() => {
                  if (!mode || !reason) return;
                  onSubstitute({
                    replacementExerciseId: selected.id,
                    replacementExerciseName: selected.name,
                    performedMeasurementMode: mode,
                    reasonCode: reason,
                  });
                }}
              />
              <Button label="Choose a different exercise" variant="ghost" onPress={() => setSelected(null)} />
            </View>
          )}

          <Button label="Cancel" variant="ghost" onPress={close} />
        </View>
      </SafeAreaView>
    </Modal>
  );
}
