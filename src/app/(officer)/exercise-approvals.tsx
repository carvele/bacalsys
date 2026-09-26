import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Redirect } from 'expo-router';
import { useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, CenteredSpinner, Notice, TextField } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { labelFor, type Exercise } from '@/features/exercises/exercise-form';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

const queueKey = ['exercise-review-queue'] as const;

type Decision = { exercise: Exercise; action: 'approve' | 'reject'; reason?: string };

/**
 * Task 2.10: custom exercise review queue for holders of exercises:approve
 * (D4: Coach, VP, President). The queue is whatever the review-queue RLS policy
 * returns; decisions go through public.review_custom_exercise(), which
 * re-checks the permission, the pending state and the rejection reason.
 */
export default function ExerciseApprovalsScreen() {
  const { access } = useAuth();
  const queryClient = useQueryClient();
  const [rejectingId, setRejectingId] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const allowed = hasPermission(access, 'exercises:approve');

  const queue = useQuery({
    queryKey: queueKey,
    enabled: allowed,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('exercises')
        .select('*')
        .eq('status', 'pending_approval')
        .order('created_at');
      if (error) throw error;
      return data;
    },
  });

  const review = useMutation({
    mutationFn: async ({ exercise, action, reason: why }: Decision) => {
      const { data, error } = await supabase.rpc('review_custom_exercise', {
        p_exercise_id: exercise.id,
        p_action: action,
        p_rejection_reason: why,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: (exercise) => {
      setMessage({
        tone: 'success',
        text:
          exercise.status === 'approved'
            ? `“${exercise.name}” is now in the official library.`
            : `“${exercise.name}” was rejected. The creator can see your reason.`,
      });
      setRejectingId(null);
      setReason('');
    },
    onError: (error) =>
      setMessage({
        tone: 'danger',
        text: describeError(error, {
          '55000': 'This exercise was already reviewed.',
          '23505': 'An official exercise with this name already exists. Reject it with a note instead.',
        }),
      }),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: queueKey });
      queryClient.invalidateQueries({ queryKey: ['exercises'] });
    },
  });

  if (!allowed) return <Redirect href="/" />;
  if (queue.isPending) return <CenteredSpinner label="Loading submissions…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={queue.data ?? []}
        keyExtractor={(e) => e.id}
        keyboardShouldPersistTaps="handled"
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        refreshControl={
          <RefreshControl refreshing={queue.isRefetching} onRefresh={() => queue.refetch()} tintColor="#F97316" />
        }
        ListHeaderComponent={
          <View className="gap-3">
            {queue.isError ? <Notice tone="danger">{describeError(queue.error)}</Notice> : null}
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
          </View>
        }
        ListEmptyComponent={
          queue.isError ? null : (
            <Card>
              <Text className="text-center text-ink-muted">No custom exercises are waiting for review.</Text>
            </Card>
          )
        }
        renderItem={({ item }) => {
          const busy = review.isPending && review.variables?.exercise.id === item.id;
          const rejecting = rejectingId === item.id;
          return (
            <Card className="gap-3">
              <View className="gap-1">
                <Text className="text-title text-ink">{item.name}</Text>
                <Text className="text-sm text-ink-muted">
                  {labelFor(item.category)} · {item.measurement_types.map(labelFor).join(', ')} ·{' '}
                  {item.equipment_needed.map(labelFor).join(', ')}
                </Text>
                {item.description ? <Text className="text-ink-muted">{item.description}</Text> : null}
                <Text className="text-sm text-ink-faint">Submitted {new Date(item.created_at).toLocaleDateString()}</Text>
              </View>
              {rejecting ? (
                <View className="gap-2">
                  <TextField
                    label="Reason for the creator"
                    value={reason}
                    onChangeText={setReason}
                    placeholder="e.g. Form cues unclear"
                    maxLength={500}
                    multiline
                  />
                  <View className="flex-row gap-2">
                    <View className="flex-1">
                      <Button label="Cancel" variant="secondary" onPress={() => setRejectingId(null)} disabled={busy} />
                    </View>
                    <View className="flex-1">
                      <Button
                        label="Reject"
                        variant="danger"
                        onPress={() => review.mutate({ exercise: item, action: 'reject', reason })}
                        loading={busy}
                        disabled={reason.trim().length === 0}
                      />
                    </View>
                  </View>
                </View>
              ) : (
                <View className="flex-row gap-2">
                  <View className="flex-1">
                    <Button
                      label="Reject…"
                      variant="secondary"
                      onPress={() => {
                        setMessage(null);
                        setReason('');
                        setRejectingId(item.id);
                      }}
                      disabled={review.isPending}
                    />
                  </View>
                  <View className="flex-1">
                    <Button
                      label="Approve"
                      onPress={() => {
                        setMessage(null);
                        review.mutate({ exercise: item, action: 'approve' });
                      }}
                      loading={busy}
                      disabled={review.isPending && !busy}
                    />
                  </View>
                </View>
              )}
            </Card>
          );
        }}
      />
    </SafeAreaView>
  );
}
