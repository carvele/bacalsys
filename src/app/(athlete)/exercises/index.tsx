import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { CustomExerciseModal } from '@/components/CustomExerciseModal';
import { Button, Card, CenteredSpinner, Chip, Notice, TextField } from '@/components/ui';
import { useAuth } from '@/features/auth/use-auth';
import {
  CATEGORIES,
  filterExercises,
  labelFor,
  STATUS_LABEL,
  type Category,
  type Exercise,
} from '@/features/exercises/exercise-form';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

export const exercisesKey = ['exercises'] as const;

/**
 * Task 2.9: exercise catalog & search. RLS returns exactly what this member may
 * see: approved official exercises plus their own drafts / pending / rejected
 * submissions (and nothing at all if they are not an active member).
 */
export default function ExerciseCatalogScreen() {
  const { profile } = useAuth();
  const queryClient = useQueryClient();
  const [query, setQuery] = useState('');
  const [category, setCategory] = useState<Category | null>(null);
  const [mineOnly, setMineOnly] = useState(false);
  const [creating, setCreating] = useState(false);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const userId = profile?.id;

  const catalog = useQuery({
    queryKey: exercisesKey,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('exercises')
        .select('*')
        .order('category')
        .order('name');
      if (error) throw error;
      return data;
    },
  });

  const submit = useMutation({
    mutationFn: async (exercise: Exercise) => {
      const { data, error } = await supabase.rpc('submit_custom_exercise', { p_exercise_id: exercise.id });
      if (error) throw error;
      return data;
    },
    onSuccess: (exercise) =>
      setMessage({ tone: 'success', text: `“${exercise.name}” was submitted for review.` }),
    onError: (error) =>
      setMessage({ tone: 'danger', text: describeError(error, { '55000': 'Only private drafts can be submitted.' }) }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: exercisesKey }),
  });

  const rows = useMemo(() => {
    const all = catalog.data ?? [];
    return filterExercises(mineOnly ? all.filter((e) => e.created_by === userId) : all, query, category);
  }, [catalog.data, mineOnly, userId, query, category]);

  if (catalog.isPending) return <CenteredSpinner label="Loading exercises…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={rows}
        keyExtractor={(e) => e.id}
        keyboardShouldPersistTaps="handled"
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        refreshControl={
          <RefreshControl refreshing={catalog.isRefetching} onRefresh={() => catalog.refetch()} tintColor="#F97316" />
        }
        ListHeaderComponent={
          <View className="gap-3">
            {catalog.isError ? <Notice tone="danger">{describeError(catalog.error)}</Notice> : null}
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
            {userId ? <Button label="New custom exercise" onPress={() => setCreating(true)} /> : null}
            <TextField label="Search" value={query} onChangeText={setQuery} placeholder="Exercise name" autoCorrect={false} />
            <View className="flex-row flex-wrap gap-2">
              <Chip label="All" selected={category === null} onPress={() => setCategory(null)} />
              {CATEGORIES.map((c) => (
                <Chip key={c} label={labelFor(c)} selected={category === c} onPress={() => setCategory(category === c ? null : c)} />
              ))}
              <Chip label="Mine" selected={mineOnly} onPress={() => setMineOnly((v) => !v)} />
            </View>
          </View>
        }
        ListEmptyComponent={
          catalog.isError ? null : (
            <Card>
              <Text className="text-center text-ink-muted">No exercises match your filters.</Text>
            </Card>
          )
        }
        renderItem={({ item }) => (
          <ExerciseCard
            exercise={item}
            isMine={item.created_by === userId}
            submitting={submit.isPending && submit.variables?.id === item.id}
            onSubmit={() => {
              setMessage(null);
              submit.mutate(item);
            }}
          />
        )}
      />
      {userId ? (
        <CustomExerciseModal
          visible={creating}
          userId={userId}
          onClose={() => setCreating(false)}
          onCreated={(exercise) => {
            setCreating(false);
            setMessage({ tone: 'success', text: `“${exercise.name}” saved as a private draft.` });
            queryClient.invalidateQueries({ queryKey: exercisesKey });
          }}
        />
      ) : null}
    </SafeAreaView>
  );
}

function ExerciseCard({
  exercise,
  isMine,
  submitting,
  onSubmit,
}: {
  exercise: Exercise;
  isMine: boolean;
  submitting: boolean;
  onSubmit: () => void;
}) {
  const official = exercise.status === 'approved';
  return (
    <Card className="gap-2">
      <View className="flex-row items-start justify-between gap-2">
        <Text className="flex-1 text-title text-ink">{exercise.name}</Text>
        {official && !exercise.created_by ? null : (
          <View className={`rounded-full px-2.5 py-0.5 ${exercise.status === 'rejected' ? 'bg-danger-soft' : 'bg-brand-soft'}`}>
            <Text className={`text-xs font-semibold ${exercise.status === 'rejected' ? 'text-danger' : 'text-brand'}`}>
              {official ? 'Community' : STATUS_LABEL[exercise.status]}
            </Text>
          </View>
        )}
      </View>
      <Text className="text-sm text-ink-muted">
        {labelFor(exercise.category)} · {exercise.measurement_types.map(labelFor).join(', ')} ·{' '}
        {exercise.equipment_needed.map(labelFor).join(', ')}
      </Text>
      {exercise.description ? <Text className="text-ink-muted">{exercise.description}</Text> : null}
      {isMine && exercise.status === 'rejected' && exercise.rejection_reason ? (
        <Notice tone="danger">{`Not approved: ${exercise.rejection_reason}`}</Notice>
      ) : null}
      {isMine && exercise.status === 'pending_approval' ? (
        <Text className="text-sm text-ink-faint">Waiting for a coach or officer to review it.</Text>
      ) : null}
      {isMine && exercise.status === 'private' ? (
        <Button label="Submit for review" variant="secondary" onPress={onSubmit} loading={submitting} />
      ) : null}
    </Card>
  );
}
