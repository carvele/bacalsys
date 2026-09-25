import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, CenteredSpinner, Notice } from '@/components/ui';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

const pendingKey = ['pending-members'] as const;

type PendingMember = {
  id: string;
  full_name: string;
  email: string;
  branch_name: string | null;
  created_at: string;
};

/**
 * Task 1.12: President / VP review queue. Reads through
 * public.list_pending_members() and approves through public.approve_member(),
 * which atomically activates the profile and records the Athlete position.
 * Both RPCs re-check members:approve server-side.
 */
export default function MemberApprovalsScreen() {
  const queryClient = useQueryClient();
  const [confirmingId, setConfirmingId] = useState<string | null>(null);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);

  const pending = useQuery({
    queryKey: pendingKey,
    queryFn: async (): Promise<PendingMember[]> => {
      const { data, error } = await supabase.rpc('list_pending_members');
      if (error) throw error;
      return data;
    },
  });

  const approve = useMutation({
    mutationFn: async (member: PendingMember) => {
      const { error } = await supabase.rpc('approve_member', { p_profile_id: member.id });
      if (error) throw error;
      return member;
    },
    onSuccess: (member) => {
      setMessage({ tone: 'success', text: `${member.full_name || member.email} approved as Athlete.` });
    },
    onError: (error) => setMessage({ tone: 'danger', text: describeError(error) }),
    onSettled: () => {
      setConfirmingId(null);
      queryClient.invalidateQueries({ queryKey: pendingKey });
    },
  });

  if (pending.isPending) return <CenteredSpinner label="Loading applications…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={pending.data ?? []}
        keyExtractor={(m) => m.id}
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        refreshControl={
          <RefreshControl refreshing={pending.isRefetching} onRefresh={() => pending.refetch()} tintColor="#F97316" />
        }
        ListHeaderComponent={
          <View className="gap-3">
            {pending.isError ? <Notice tone="danger">{describeError(pending.error)}</Notice> : null}
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
          </View>
        }
        ListEmptyComponent={
          pending.isError ? null : (
            <Card>
              <Text className="text-center text-ink-muted">No applications waiting for review.</Text>
            </Card>
          )
        }
        renderItem={({ item }) => {
          const confirming = confirmingId === item.id;
          const busy = approve.isPending && approve.variables?.id === item.id;
          return (
            <Card className="gap-3">
              <View className="gap-0.5">
                <Text className="text-title text-ink">{item.full_name || 'Unnamed applicant'}</Text>
                <Text className="text-ink-muted">{item.email}</Text>
                <Text className="text-sm text-ink-faint">
                  Applied {new Date(item.created_at).toLocaleDateString()}
                  {item.branch_name ? ` · ${item.branch_name}` : ''}
                </Text>
              </View>
              {confirming ? (
                <View className="gap-2">
                  <Text className="text-ink">Approve and assign the Athlete position?</Text>
                  <View className="flex-row gap-2">
                    <View className="flex-1">
                      <Button label="Cancel" variant="secondary" onPress={() => setConfirmingId(null)} disabled={busy} />
                    </View>
                    <View className="flex-1">
                      <Button label="Confirm" onPress={() => approve.mutate(item)} loading={busy} />
                    </View>
                  </View>
                </View>
              ) : (
                <Button
                  label="Approve as Athlete"
                  onPress={() => {
                    setMessage(null);
                    setConfirmingId(item.id);
                  }}
                  disabled={approve.isPending}
                />
              )}
            </Card>
          );
        }}
      />
    </SafeAreaView>
  );
}
