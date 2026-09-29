import { useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { FlatList, Modal, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, CenteredSpinner, Notice, TextField } from '@/components/ui';
import { useAuth } from '@/features/auth/use-auth';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import {
  revokeSkillAchievement,
  reviewSkillAttempt,
  useMyVerifiedAchievements,
  usePendingSkillAttempts,
  type PendingAttemptView,
} from '@/lib/skills';

/**
 * Sprint 6 · Task 6.14 — the coach/officer triage queue (Feature 8.3). Pending
 * attempts and the reviewer's own recent verifications are whatever RLS/
 * `can_verify_skill` already scope to the caller (assigned athletes for a
 * Coach, the whole organization for VP/President); approving inserts or
 * upserts the achievement server-side (`review_skill_attempt`), and revoking
 * always requires a non-blank reason (`revoke_skill_achievement`).
 */
export default function SkillVerificationQueueScreen() {
  const { profile } = useAuth();
  const queryClient = useQueryClient();
  const pending = usePendingSkillAttempts();
  const verified = useMyVerifiedAchievements(profile?.id);

  const [reviewing, setReviewing] = useState<PendingAttemptView | null>(null);
  const [feedback, setFeedback] = useState('');
  const [decision, setDecision] = useState<'approved' | 'rejected' | null>(null);
  const [revoking, setRevoking] = useState<{ id: string; label: string } | null>(null);
  const [reason, setReason] = useState('');
  const [showReasonError, setShowReasonError] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: ['pending-skill-attempts'] });
    void queryClient.invalidateQueries({ queryKey: ['my-verified-achievements'] });
  };

  const closeReview = () => {
    setReviewing(null);
    setDecision(null);
    setFeedback('');
  };

  const submitReview = async () => {
    if (!reviewing || !decision) return;
    setSubmitting(true);
    setMessage(null);
    const { error } = await reviewSkillAttempt({
      attemptId: reviewing.id,
      approved: decision === 'approved',
      feedback: feedback.trim() === '' ? null : feedback.trim(),
      idempotencyKey: randomId(),
    });
    setSubmitting(false);
    if (error) {
      setMessage({ tone: 'danger', text: describeError(error, { '42501': 'You are not authorized to review this athlete’s attempts.' }) });
      return;
    }
    setMessage({ tone: 'success', text: decision === 'approved' ? 'Attempt approved.' : 'Attempt rejected.' });
    closeReview();
    invalidate();
  };

  const closeRevoke = () => {
    setRevoking(null);
    setReason('');
    setShowReasonError(false);
  };

  const submitRevoke = async () => {
    if (!revoking) return;
    if (reason.trim().length === 0) {
      setShowReasonError(true);
      return;
    }
    setSubmitting(true);
    setMessage(null);
    const { error } = await revokeSkillAchievement({ achievementId: revoking.id, reason: reason.trim(), idempotencyKey: randomId() });
    setSubmitting(false);
    if (error) {
      setMessage({ tone: 'danger', text: describeError(error) });
      return;
    }
    setMessage({ tone: 'success', text: 'Achievement revoked.' });
    closeRevoke();
    invalidate();
  };

  if (pending.isPending) return <CenteredSpinner label="Loading pending attempts…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={pending.data ?? []}
        keyExtractor={(a) => a.id}
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        ListHeaderComponent={
          <View className="gap-3 pb-1">
            <Text className="text-display text-ink">Skill verification</Text>
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
            {pending.isError ? <Notice tone="danger">{describeError(pending.error)}</Notice> : null}
            <Text className="text-sm font-medium uppercase tracking-wide text-ink-muted">
              Pending ({(pending.data ?? []).length})
            </Text>
          </View>
        }
        ListEmptyComponent={
          !pending.isError ? (
            <Card>
              <Text className="text-center text-ink-muted">No attempts are waiting for review.</Text>
            </Card>
          ) : null
        }
        renderItem={({ item }) => (
          <Card className="gap-1">
            <Text className="text-title text-ink">{item.athleteName}</Text>
            <Text className="text-ink-muted">
              {item.skillName} · {item.progressionName}
            </Text>
            <Text className="text-ink">
              Logged: {item.actualHoldSeconds !== null ? `${item.actualHoldSeconds}s hold` : `${item.actualReps} reps`}
            </Text>
            {item.videoUrl ? <Text className="text-sm text-brand">{item.videoUrl}</Text> : null}
            <Text className="text-xs text-ink-faint">{item.attemptDate}</Text>
            <View className="mt-2 flex-row gap-2">
              <View className="flex-1">
                <Button
                  label="Reject"
                  variant="danger"
                  onPress={() => {
                    setReviewing(item);
                    setDecision('rejected');
                  }}
                />
              </View>
              <View className="flex-1">
                <Button
                  label="Approve"
                  onPress={() => {
                    setReviewing(item);
                    setDecision('approved');
                  }}
                />
              </View>
            </View>
          </Card>
        )}
        ListFooterComponent={
          <View className="gap-2 pt-4">
            <Text className="text-sm font-medium uppercase tracking-wide text-ink-muted">Recently verified by you</Text>
            {verified.isPending ? null : (verified.data ?? []).length === 0 ? (
              <Text className="text-sm text-ink-faint">Nothing to show yet.</Text>
            ) : (
              (verified.data ?? []).map((a) => (
                <Card key={a.id} className="flex-row items-center justify-between gap-2">
                  <View className="flex-1">
                    <Text className="font-semibold text-ink">
                      {a.athleteName} · {a.skillName}
                    </Text>
                    <Text className="text-sm text-ink-muted">{a.progressionName}</Text>
                  </View>
                  <Button
                    label="Revoke"
                    variant="danger"
                    onPress={() => setRevoking({ id: a.id, label: `${a.athleteName} · ${a.progressionName}` })}
                  />
                </Card>
              ))
            )}
          </View>
        }
      />

      <Modal visible={!!reviewing} animationType="slide" transparent onRequestClose={closeReview}>
        <View className="flex-1 justify-end bg-black/40">
          <SafeAreaView className="rounded-t-card bg-surface-raised">
            <View className="w-full max-w-[640px] self-center gap-3 p-4">
              <Text className="text-title text-ink">
                {decision === 'approved' ? 'Approve' : 'Reject'} attempt · {reviewing?.athleteName}
              </Text>
              {reviewing ? (
                <Text className="text-ink-muted">
                  {reviewing.skillName} · {reviewing.progressionName} ·{' '}
                  {reviewing.actualHoldSeconds !== null ? `${reviewing.actualHoldSeconds}s hold` : `${reviewing.actualReps} reps`}
                </Text>
              ) : null}
              <TextField label="Feedback (optional)" value={feedback} onChangeText={setFeedback} multiline numberOfLines={3} />
              <View className="flex-row gap-3 pt-1">
                <View className="flex-1">
                  <Button label="Cancel" variant="secondary" onPress={closeReview} disabled={submitting} />
                </View>
                <View className="flex-1">
                  <Button
                    label={decision === 'approved' ? 'Approve' : 'Reject'}
                    variant={decision === 'approved' ? 'primary' : 'danger'}
                    onPress={submitReview}
                    loading={submitting}
                  />
                </View>
              </View>
            </View>
          </SafeAreaView>
        </View>
      </Modal>

      <Modal visible={!!revoking} animationType="slide" transparent onRequestClose={closeRevoke}>
        <View className="flex-1 justify-end bg-black/40">
          <SafeAreaView className="rounded-t-card bg-surface-raised">
            <View className="w-full max-w-[640px] self-center gap-3 p-4">
              <Text className="text-title text-ink">Revoke · {revoking?.label}</Text>
              <TextField
                label="Reason (required)"
                value={reason}
                onChangeText={setReason}
                multiline
                numberOfLines={3}
                error={showReasonError && reason.trim().length === 0 ? 'A revocation reason is required.' : null}
              />
              <View className="flex-row gap-3 pt-1">
                <View className="flex-1">
                  <Button label="Cancel" variant="secondary" onPress={closeRevoke} disabled={submitting} />
                </View>
                <View className="flex-1">
                  <Button label="Revoke" variant="danger" onPress={submitRevoke} loading={submitting} />
                </View>
              </View>
            </View>
          </SafeAreaView>
        </View>
      </Modal>
    </SafeAreaView>
  );
}
