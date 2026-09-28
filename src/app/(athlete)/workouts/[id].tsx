import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { AssignWorkoutModal } from '@/components/AssignWorkoutModal';
import { Button, Card, CenteredSpinner, Notice, TextField } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { labelFor, summarizeSet } from '@/features/workouts/workout-builder';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 3.13: routine detail. Shows the latest version's full prescription
 * (blocks → items → sets) and the actions the current member's role and
 * relationship to the routine make available; the server independently
 * re-validates every one on the RPC.
 */
export default function WorkoutDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { profile, access } = useAuth();
  const queryClient = useQueryClient();
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const [editing, setEditing] = useState(false);
  const [assigning, setAssigning] = useState(false);
  const [editName, setEditName] = useState('');
  const [editDescription, setEditDescription] = useState('');

  const templateKey = ['workout-template', id] as const;
  const query = useQuery({
    queryKey: templateKey,
    enabled: !!id,
    queryFn: async () => {
      const { data: template, error: templateError } = await supabase.from('workout_templates').select('*').eq('id', id).single();
      if (templateError) throw templateError;
      const { data: versions, error: versionsError } = await supabase
        .from('workout_versions')
        .select('id, version_number, notes, is_sealed, created_at')
        .eq('template_id', id)
        .order('version_number', { ascending: false });
      if (versionsError) throw versionsError;
      const latest = versions?.[0];
      let hierarchy: { block: any; items: { item: any; exercise: any; sets: any[] }[] }[] = [];
      if (latest) {
        const { data: blocks, error: blocksError } = await supabase
          .from('workout_blocks')
          .select('*')
          .eq('workout_version_id', latest.id)
          .order('order_in_workout');
        if (blocksError) throw blocksError;
        hierarchy = await Promise.all(
          (blocks ?? []).map(async (block) => {
            const { data: items } = await supabase.from('workout_items').select('*, exercises(name)').eq('block_id', block.id).order('order_in_block');
            const withSets = await Promise.all(
              (items ?? []).map(async (item) => {
                const { data: sets } = await supabase.from('workout_item_sets').select('*').eq('workout_item_id', item.id).order('set_number');
                return { item, exercise: item.exercises, sets: sets ?? [] };
              }),
            );
            return { block, items: withSets };
          }),
        );
      }
      return { template, versions: versions ?? [], latest, hierarchy };
    },
  });

  const isCreator = query.data?.template.created_by === profile?.id;
  const canManageOrg = hasPermission(access, 'workouts:manage_org');
  const canPublishOrg = hasPermission(access, 'workouts:publish_org');
  const canMutate = useMemo(() => {
    if (!query.data) return false;
    const t = query.data.template;
    if (t.visibility === 'private') return isCreator;
    return (isCreator && canPublishOrg) || canManageOrg;
  }, [query.data, isCreator, canPublishOrg, canManageOrg]);

  const invalidate = () => queryClient.invalidateQueries({ queryKey: templateKey });

  const clone = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('clone_workout_template', { p_template_id: id });
      if (error) throw error;
      return data as { template_id: string };
    },
    onSuccess: (data) => router.push({ pathname: '/workouts/[id]', params: { id: data.template_id } }),
    onError: (error) => setMessage({ tone: 'danger', text: describeError(error) }),
  });

  const toggleVisibility = useMutation({
    mutationFn: async () => {
      const next = query.data!.template.visibility === 'private' ? 'organization' : 'private';
      const { error } = await supabase.rpc('set_template_visibility', { p_template_id: id, p_visibility: next });
      if (error) throw error;
    },
    onSuccess: () => setMessage({ tone: 'success', text: 'Visibility updated.' }),
    onError: (error) =>
      setMessage({
        tone: 'danger',
        text: describeError(error, { '22023': 'Every exercise in every version must be approved before publishing to the club.' }),
      }),
    onSettled: invalidate,
  });

  const toggleArchived = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('set_workout_template_archived', {
        p_template_id: id,
        p_is_archived: !query.data!.template.is_archived,
      });
      if (error) throw error;
    },
    onSuccess: () => setMessage({ tone: 'success', text: query.data?.template.is_archived ? 'Routine unarchived.' : 'Routine archived.' }),
    onError: (error) => setMessage({ tone: 'danger', text: describeError(error) }),
    onSettled: invalidate,
  });

  const saveMetadata = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('update_workout_template_metadata', {
        p_template_id: id,
        p_name: editName.trim(),
        p_description: editDescription.trim(),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setEditing(false);
      setMessage({ tone: 'success', text: 'Details updated.' });
    },
    onError: (error) => setMessage({ tone: 'danger', text: describeError(error) }),
    onSettled: invalidate,
  });

  if (query.isPending) return <CenteredSpinner label="Loading routine…" />;
  if (query.isError || !query.data) return <Notice tone="danger">{describeError(query.error)}</Notice>;

  const { template, versions, latest, hierarchy } = query.data;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <ScrollView contentContainerClassName="w-full max-w-[640px] self-center gap-3 p-4">
        {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}

        <Card className="gap-2">
          {editing ? (
            <View className="gap-2">
              <TextField label="Name" value={editName} onChangeText={setEditName} />
              <TextField label="Description" value={editDescription} onChangeText={setEditDescription} />
              <View className="flex-row gap-2">
                <Button label="Save" onPress={() => saveMetadata.mutate()} loading={saveMetadata.isPending} />
                <Button label="Cancel" variant="ghost" onPress={() => setEditing(false)} />
              </View>
            </View>
          ) : (
            <>
              <Text className="text-display text-ink">{template.name}</Text>
              {template.description ? <Text className="text-ink-muted">{template.description}</Text> : null}
              <Text className="text-sm text-ink-faint">
                {template.visibility === 'organization' ? 'Club template' : 'Private routine'}
                {template.is_archived ? ' · Archived' : ''} · Version {latest?.version_number ?? '—'}
              </Text>
            </>
          )}
        </Card>

        {latest ? (
          <Button
            label="Start workout"
            onPress={() => router.push({ pathname: '/workout/active', params: { versionId: latest.id } })}
          />
        ) : null}

        {latest && hasPermission(access, 'workout:assign') ? (
          <Button label="Assign to athletes" variant="secondary" onPress={() => setAssigning(true)} />
        ) : null}

        {canMutate && !editing ? (
          <View className="flex-row flex-wrap gap-2">
            <Button
              label="Edit details"
              variant="secondary"
              onPress={() => {
                setEditName(template.name);
                setEditDescription(template.description ?? '');
                setEditing(true);
              }}
            />
            <Button
              label="Publish new version"
              variant="secondary"
              onPress={() => router.push({ pathname: '/workouts/version', params: { templateId: template.id } })}
            />
            <Button
              label={template.visibility === 'private' ? 'Publish to club' : 'Make private'}
              variant="secondary"
              onPress={() => toggleVisibility.mutate()}
              loading={toggleVisibility.isPending}
            />
            <Button
              label={template.is_archived ? 'Unarchive' : 'Archive'}
              variant="ghost"
              onPress={() => toggleArchived.mutate()}
              loading={toggleArchived.isPending}
            />
          </View>
        ) : null}
        <Button label="Clone to my library" variant="secondary" onPress={() => clone.mutate()} loading={clone.isPending} />

        {hierarchy.map(({ block, items }, bi) => (
          <Card key={block.id} className="gap-2">
            <Text className="text-title text-ink">
              {bi + 1}. {block.title}
            </Text>
            <Text className="text-xs uppercase tracking-wide text-ink-faint">
              {labelFor(block.block_type)}
              {block.block_type === 'amrap' ? ` · ${block.amrap_duration_seconds}s` : ''}
              {block.block_type === 'circuit' ? ` · ${block.circuit_rounds} rounds` : ''}
            </Text>
            {items.map(({ item, exercise, sets }) => (
              <View key={item.id} className="gap-1 border-t border-surface-border pt-2">
                <Text className="font-semibold text-ink">
                  {exercise?.name ?? 'Exercise'} · {labelFor(item.measurement_mode)}
                </Text>
                {sets.map((s: any) => (
                  <Text key={s.id} className="text-sm text-ink-muted">
                    Set {s.set_number}: {summarizeSet(item.measurement_mode, s)}
                    {s.target_rest_seconds !== null ? ` · rest ${s.target_rest_seconds}s` : ''}
                    {s.target_rpe !== null ? ` · RPE ${s.target_rpe}` : ''}
                    {s.notes ? ` · ${s.notes}` : ''}
                  </Text>
                ))}
              </View>
            ))}
          </Card>
        ))}

        {versions.length > 1 ? (
          <Card className="gap-1">
            <Text className="text-sm font-medium uppercase tracking-wide text-ink-muted">Version history</Text>
            {versions.map((v) => (
              <Text key={v.id} className="text-sm text-ink-muted">
                V{v.version_number}
                {v.id === latest?.id ? ' (current)' : ''}
                {v.notes ? ` — ${v.notes}` : ''}
              </Text>
            ))}
          </Card>
        ) : null}
      </ScrollView>
      {assigning ? <AssignWorkoutModal visible templateId={template.id} onClose={() => setAssigning(false)} /> : null}
    </SafeAreaView>
  );
}
