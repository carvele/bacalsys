import { useMutation } from '@tanstack/react-query';
import { useState } from 'react';
import { KeyboardAvoidingView, Modal, Platform, ScrollView, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Chip, Notice, TextField } from '@/components/ui';
import {
  CATEGORIES,
  draftToInsert,
  EQUIPMENT,
  emptyDraft,
  labelFor,
  MEASUREMENT_TYPES,
  toggleEquipment,
  toggleValue,
  validateExerciseDraft,
  type DraftErrors,
  type Exercise,
} from '@/features/exercises/exercise-form';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 2.10: create a private custom exercise (Feature 3.2). The insert sends
 * content columns only; the database fixes status = 'private' and
 * is_official = false (column grants + RLS WITH CHECK).
 */
export function CustomExerciseModal({
  visible,
  userId,
  onClose,
  onCreated,
}: {
  visible: boolean;
  userId: string;
  onClose: () => void;
  onCreated: (exercise: Exercise) => void;
}) {
  const [draft, setDraft] = useState(emptyDraft);
  const [errors, setErrors] = useState<DraftErrors>({});

  const create = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.from('exercises').insert(draftToInsert(draft, userId)).select().single();
      if (error) throw error;
      return data;
    },
    onSuccess: (exercise) => {
      setDraft(emptyDraft());
      setErrors({});
      onCreated(exercise);
    },
  });

  const save = () => {
    const found = validateExerciseDraft(draft);
    setErrors(found);
    if (Object.keys(found).length === 0) create.mutate();
  };

  const close = () => {
    create.reset();
    onClose();
  };

  return (
    <Modal visible={visible} animationType="slide" presentationStyle="pageSheet" onRequestClose={close}>
      <SafeAreaView className="flex-1 bg-surface">
        <KeyboardAvoidingView className="flex-1" behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ScrollView contentContainerClassName="w-full max-w-[560px] self-center gap-4 px-4 py-6" keyboardShouldPersistTaps="handled">
            <Text accessibilityRole="header" className="text-display text-ink">
              New custom exercise
            </Text>
            <Text className="text-ink-muted">
              Only you can see it until you submit it for review. Once approved it joins the official library.
            </Text>

            {create.isError ? (
              <Notice tone="danger">
                {describeError(create.error, { '23505': 'You already have a custom exercise with this name.' })}
              </Notice>
            ) : null}

            <TextField
              label="Name"
              value={draft.name}
              onChangeText={(name) => setDraft((d) => ({ ...d, name }))}
              placeholder="e.g. Weighted Ring Dips"
              maxLength={120}
              error={errors.name}
            />

            <Field label="Category" error={errors.category}>
              {CATEGORIES.map((c) => (
                <Chip key={c} label={labelFor(c)} selected={draft.category === c} onPress={() => setDraft((d) => ({ ...d, category: c }))} />
              ))}
            </Field>

            <Field label="Measured by" error={errors.measurementTypes}>
              {MEASUREMENT_TYPES.map((m) => (
                <Chip
                  key={m}
                  label={labelFor(m)}
                  selected={draft.measurementTypes.includes(m)}
                  onPress={() => setDraft((d) => ({ ...d, measurementTypes: toggleValue(d.measurementTypes, m) }))}
                />
              ))}
            </Field>

            <Field label="Equipment" error={errors.equipment}>
              {EQUIPMENT.map((e) => (
                <Chip
                  key={e}
                  label={labelFor(e)}
                  selected={draft.equipment.includes(e)}
                  onPress={() => setDraft((d) => ({ ...d, equipment: toggleEquipment(d.equipment, e) }))}
                />
              ))}
            </Field>

            <TextField
              label="Description (optional)"
              value={draft.description}
              onChangeText={(description) => setDraft((d) => ({ ...d, description }))}
              placeholder="Form cues, progressions, safety notes"
              multiline
              maxLength={2000}
              error={errors.description}
            />

            <View className="flex-row gap-2">
              <View className="flex-1">
                <Button label="Cancel" variant="secondary" onPress={close} disabled={create.isPending} />
              </View>
              <View className="flex-1">
                <Button label="Save draft" onPress={save} loading={create.isPending} />
              </View>
            </View>
          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </Modal>
  );
}

function Field({ label, error, children }: { label: string; error?: string; children: React.ReactNode }) {
  return (
    <View className="gap-1.5">
      <Text className="text-sm font-medium text-ink-muted">{label}</Text>
      <View className="flex-row flex-wrap gap-2">{children}</View>
      {error ? <Text className="text-sm text-danger">{error}</Text> : null}
    </View>
  );
}
