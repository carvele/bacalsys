import { useState } from 'react';
import { Modal, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Notice, TextField } from '@/components/ui';
import { rungMode } from '@/features/skills/attempt-form';
import {
  buildUpdateProgressionArgs,
  isProgressionDraftValid,
  progressionDraftFrom,
  validateProgressionDraft,
  type ProgressionDraft,
} from '@/features/skills/progression-form';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { updateSkillProgression } from '@/lib/skills';

/**
 * Sprint 6 · Task 6.13 — edit a rung's criteria (Feature 8.1, F-S6-P07). Gated
 * by `skills:manage` on the caller — the screen only renders the "Edit" action
 * for members who hold it; `update_skill_progression` re-checks it either way
 * and writes an immutable audit event with the old and new values.
 */
export function EditSkillProgressionModal({
  visible,
  rung,
  onClose,
  onUpdated,
}: {
  visible: boolean;
  rung: { id: string; name: string; description: string | null; targetHoldSeconds: number | null; targetReps: number | null } | null;
  onClose: () => void;
  onUpdated: () => void;
}) {
  const mode = rung ? rungMode(rung) : 'reps';
  const [draft, setDraft] = useState<ProgressionDraft>(() => progressionDraftFrom(rung ?? { name: '', description: null, targetHoldSeconds: null, targetReps: null }));
  const [showErrors, setShowErrors] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const [openedFor, setOpenedFor] = useState<string | null>(null);

  // Re-seed the draft whenever a different rung opens (no effect needed: the
  // modal is remounted per rung id would be an option, but this keeps state
  // reset without an extra key prop on every call site).
  if (rung && rung.id !== openedFor) {
    setOpenedFor(rung.id);
    setDraft(progressionDraftFrom(rung));
    setShowErrors(false);
    setMessage(null);
  }

  const errors = rung ? validateProgressionDraft(mode, draft) : {};
  const valid = isProgressionDraftValid(errors);

  const close = () => {
    setMessage(null);
    setShowErrors(false);
    onClose();
  };

  const submit = async () => {
    if (!rung) return;
    if (!valid) {
      setShowErrors(true);
      return;
    }
    setSubmitting(true);
    setMessage(null);
    const { error } = await updateSkillProgression({ ...buildUpdateProgressionArgs(mode, draft, rung.id), idempotencyKey: randomId() });
    setSubmitting(false);
    if (error) {
      setMessage({
        tone: 'danger',
        text: describeError(error, { '42501': 'Only a Coach, Vice President or President can edit skill criteria.' }),
      });
      return;
    }
    onUpdated();
  };

  return (
    <Modal visible={visible} animationType="slide" transparent onRequestClose={close}>
      <View className="flex-1 justify-end bg-black/40">
        <SafeAreaView className="rounded-t-card bg-surface-raised">
          <View className="w-full max-w-[640px] self-center gap-3 p-4">
            <Text className="text-title text-ink">Edit criteria</Text>
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
            <TextField label="Name" value={draft.name} onChangeText={(v) => setDraft((d) => ({ ...d, name: v }))} error={showErrors ? errors.name : null} />
            <TextField
              label="Description"
              value={draft.description}
              onChangeText={(v) => setDraft((d) => ({ ...d, description: v }))}
              multiline
              numberOfLines={3}
              error={showErrors ? errors.description : null}
            />
            <TextField
              label={mode === 'hold' ? 'Target hold time (seconds)' : 'Target repetitions'}
              value={draft.target}
              onChangeText={(v) => setDraft((d) => ({ ...d, target: v }))}
              keyboardType="number-pad"
              error={showErrors ? errors.target : null}
            />
            <View className="flex-row gap-3 pt-1">
              <View className="flex-1">
                <Button label="Cancel" variant="secondary" onPress={close} disabled={submitting} />
              </View>
              <View className="flex-1">
                <Button label="Save" onPress={submit} loading={submitting} />
              </View>
            </View>
          </View>
        </SafeAreaView>
      </View>
    </Modal>
  );
}
