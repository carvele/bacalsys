import { useQuery } from '@tanstack/react-query';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { FlatList, Pressable, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, CenteredSpinner, Chip, Notice } from '@/components/ui';
import { useAuth } from '@/features/auth/use-auth';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

type TemplateRow = {
  id: string;
  name: string;
  description: string | null;
  visibility: string;
  is_archived: boolean;
  created_by: string;
  updated_at: string;
};

const templatesKey = ['workout-templates'] as const;

/**
 * Task 3.13: routine catalog. RLS returns exactly what this member may see —
 * own private routines (any safety state) plus organization templates in
 * their organization; a private routine authored by someone else is included
 * only when it is currently safe to view (two-tier RLS).
 */
export default function WorkoutCatalogScreen() {
  const { profile } = useAuth();
  const userId = profile?.id;
  const [tab, setTab] = useState<'mine' | 'club'>('mine');

  const templates = useQuery({
    queryKey: templatesKey,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('workout_templates')
        .select('id, name, description, visibility, is_archived, created_by, updated_at')
        .order('updated_at', { ascending: false });
      if (error) throw error;
      return data as TemplateRow[];
    },
  });

  const rows = useMemo(() => {
    const all = templates.data ?? [];
    return tab === 'mine' ? all.filter((t) => t.created_by === userId) : all.filter((t) => t.visibility === 'organization');
  }, [templates.data, tab, userId]);

  if (templates.isPending) return <CenteredSpinner label="Loading routines…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={rows}
        keyExtractor={(t) => t.id}
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        refreshControl={<RefreshControl refreshing={templates.isRefetching} onRefresh={() => templates.refetch()} tintColor="#F97316" />}
        ListHeaderComponent={
          <View className="gap-3">
            {templates.isError ? <Notice tone="danger">{describeError(templates.error)}</Notice> : null}
            <View className="flex-row gap-2">
              <Chip label="My routines" selected={tab === 'mine'} onPress={() => setTab('mine')} />
              <Chip label="Club templates" selected={tab === 'club'} onPress={() => setTab('club')} />
            </View>
            <Button label="New routine" onPress={() => router.push('/workouts/builder')} />
          </View>
        }
        ListEmptyComponent={
          templates.isError ? null : (
            <Card>
              <Text className="text-center text-ink-muted">
                {tab === 'mine' ? 'You have not created a routine yet.' : 'No club templates yet.'}
              </Text>
            </Card>
          )
        }
        renderItem={({ item }) => (
          <Pressable onPress={() => router.push({ pathname: '/workouts/[id]', params: { id: item.id } })}>
            <Card className="gap-1">
              <View className="flex-row items-center justify-between gap-2">
                <Text className="flex-1 text-title text-ink">{item.name}</Text>
                <View className={`rounded-full px-2.5 py-0.5 ${item.visibility === 'organization' ? 'bg-brand-soft' : 'bg-surface-sunken'}`}>
                  <Text className={`text-xs font-semibold ${item.visibility === 'organization' ? 'text-brand' : 'text-ink-muted'}`}>
                    {item.visibility === 'organization' ? 'Club' : 'Private'}
                  </Text>
                </View>
              </View>
              {item.description ? <Text className="text-ink-muted">{item.description}</Text> : null}
              {item.is_archived ? <Text className="text-xs text-ink-faint">Archived</Text> : null}
            </Card>
          </Pressable>
        )}
      />
    </SafeAreaView>
  );
}
