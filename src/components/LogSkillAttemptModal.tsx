import { useState } from 'react';
import { Modal, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Notice, TextField } from '@/components/ui';
import {
  buildLogAttemptArgs,
  emptyAttemptDraft,
  isAttemptDraftValid,
  rungMode,
  validateAttemptDraft,
  type AttemptMode,
} from '@/features/skills/attempt-form';
import { rungTargetLabel } from '@/features/skills/ladder';
import { describeError } from '@/lib/errors';
import { logSkillAttempt } from '@/lib/skills';
import { randomId } from '@/lib/random-id';

/**
 * Sprint 6 · Task 6.13 — log an attempt on a rung (Feature 8.2, F-S6-P09):
 * objective metrics only, no free-text note. The rung's own target (hold vs.
 * reps) decides which single metric field is asked for.
 */
export function LogSkillAttemptModal({
  visible,
  rung,
  onClose,
  onLogged,
}: {
  visible: boolean;
  rung: { id: string; name: string; targetHoldSeconds: number | null; targetReps: number | null };
  onClose: () => void;
  onLogged: () => void;
}) {
  const mode: AttemptMode = rungMode(rung);
  const [draft, setDraft] = useState(emptyAttemptDraft);
  const [showErrors, setShowErrors] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);

  const errors = validateAttemptDraft(mode, draft);
  const valid = isAttemptDraftValid(errors);

  const close = () => {
    setDraft(emptyAttemptDraft());
    setShowErrors(false);
    setMessage(null);
    onClose();
  };

  const submit = async () => {
    if (!valid) {
      setShowErrors(true);
      return;
    }
    setSubmitting(true);
    setMessage(null);
    const { error } = await logSkillAttempt({ ...buildLogAttemptArgs(mode, draft, rung.id), idempotencyKey: randomId() });
    setSubmitting(false);
    if (error) {
      setMessage({ tone: 'danger', text: describeError(error) });
      return;
    }
    setDraft(emptyAttemptDraft());
    setShowErrors(false);
    onLogged();
  };

  return (
    <Modal visible={visible} animationType="slide" transparent onRequestClose={close}>
      <View className="flex-1 justify-end bg-black/40">
        <SafeAreaView className="rounded-t-card bg-surface-raised">
          <View className="w-full max-w-[640px] self-center gap-3 p-4">
            <Text className="text-title text-ink">Log attempt · {rung.name}</Text>
            <Text className="text-sm text-ink-muted">Target: {rungTargetLabel(rung)}</Text>

            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}

            <TextField
              label={mode === 'hold' ? 'Hold time (seconds)' : 'Repetitions'}
              value={draft.metric}
              onChangeText={(v) => setDraft((d) => ({ ...d, metric: v }))}
              keyboardType="number-pad"
              error={showErrors ? errors.metric : null}
            />
            <TextField
              label="Video link (optional)"
              value={draft.videoUrl}
              onChangeText={(v) => setDraft((d) => ({ ...d, videoUrl: v }))}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              placeholder="https://…"
              error={showErrors ? errors.videoUrl : null}
            />

            <View className="flex-row gap-3 pt-1">
              <View className="flex-1">
                <Button label="Cancel" variant="secondary" onPress={close} disabled={submitting} />
              </View>
              <View className="flex-1">
                <Button label="Submit" onPress={submit} loading={submitting} />
              </View>
            </View>
          </View>
        </SafeAreaView>
      </View>
    </Modal>
  );
}
