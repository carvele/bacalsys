import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { Modal, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Card, Chip, TextField } from '@/components/ui';
import {
  addBackOffSet,
  addPyramidSets,
  BLOCK_TYPES,
  emptyBlock,
  emptyItem,
  emptySet,
  itemModesFor,
  labelFor,
  validateSet,
  type BlockDraft,
  type BlockType,
  type ItemDraft,
  type SetDraft,
} from '@/features/workouts/workout-builder';
import { supabase } from '@/lib/supabase';

type ExerciseOption = { id: string; name: string; measurement_types: string[] };

/**
 * Task 3.13: the interactive hierarchical builder. Blocks → items → sets are
 * plain arrays the parent screen owns; this component only edits them. Array
 * order is the prescription order (order_in_workout / order_in_block /
 * set_number are derived from position server-side).
 */
export function WorkoutBlocksEditor({
  blocks,
  onChange,
  approvedOnly,
}: {
  blocks: BlockDraft[];
  onChange: (blocks: BlockDraft[]) => void;
  /** true for an organization-visible routine: only approved/official exercises are offered. */
  approvedOnly: boolean;
}) {
  const updateBlock = (i: number, patch: Partial<BlockDraft>) =>
    onChange(blocks.map((b, bi) => (bi === i ? { ...b, ...patch } : b)));
  const removeBlock = (i: number) => onChange(blocks.filter((_, bi) => bi !== i));
  const addBlock = () => onChange([...blocks, emptyBlock()]);

  return (
    <View className="gap-3">
      {blocks.map((block, bi) => (
        <Card key={bi} className="gap-3">
          <View className="flex-row items-center justify-between">
            <Text className="text-title text-ink">Block {bi + 1}</Text>
            {blocks.length > 1 ? <Button label="Remove" variant="ghost" onPress={() => removeBlock(bi)} /> : null}
          </View>
          <TextField label="Title" value={block.title} onChangeText={(title) => updateBlock(bi, { title })} placeholder="e.g. Primary Strength" />
          <View className="gap-1.5">
            <Text className="text-sm font-medium text-ink-muted">Structure</Text>
            <View className="flex-row flex-wrap gap-2">
              {BLOCK_TYPES.map((t) => (
                <Chip key={t} label={labelFor(t)} selected={block.blockType === t} onPress={() => updateBlock(bi, { blockType: t as BlockType })} />
              ))}
            </View>
          </View>
          {block.blockType === 'amrap' ? (
            <TextField
              label="AMRAP duration (seconds, min 30)"
              keyboardType="number-pad"
              value={block.amrapDurationSeconds}
              onChangeText={(amrapDurationSeconds) => updateBlock(bi, { amrapDurationSeconds })}
            />
          ) : null}
          {block.blockType === 'circuit' ? (
            <TextField
              label="Rounds"
              keyboardType="number-pad"
              value={block.circuitRounds}
              onChangeText={(circuitRounds) => updateBlock(bi, { circuitRounds })}
            />
          ) : null}

          <View className="gap-3">
            {block.items.map((item, ii) => (
              <ItemEditor
                key={ii}
                item={item}
                approvedOnly={approvedOnly}
                onChange={(patch) =>
                  updateBlock(bi, { items: block.items.map((it, x) => (x === ii ? { ...it, ...patch } : it)) })
                }
                onRemove={block.items.length > 1 ? () => updateBlock(bi, { items: block.items.filter((_, x) => x !== ii) }) : undefined}
              />
            ))}
            <Button label="Add exercise" variant="secondary" onPress={() => updateBlock(bi, { items: [...block.items, emptyItem()] })} />
          </View>
        </Card>
      ))}
      <Button label="Add block" variant="secondary" onPress={addBlock} />
    </View>
  );
}

function ItemEditor({
  item,
  approvedOnly,
  onChange,
  onRemove,
}: {
  item: ItemDraft;
  approvedOnly: boolean;
  onChange: (patch: Partial<ItemDraft>) => void;
  onRemove?: () => void;
}) {
  const [pickerOpen, setPickerOpen] = useState(false);
  const modes = useMemo(() => (item.exerciseMeasurementTypes ? itemModesFor(item.exerciseMeasurementTypes) : []), [item.exerciseMeasurementTypes]);

  const updateSet = (si: number, patch: Partial<SetDraft>) =>
    onChange({ sets: item.sets.map((s, x) => (x === si ? { ...s, ...patch } : s)) });

  return (
    <Card className="gap-2 bg-surface-sunken">
      <View className="flex-row items-center justify-between gap-2">
        <Button
          label={item.exerciseName || 'Choose exercise'}
          variant="secondary"
          onPress={() => setPickerOpen(true)}
        />
        {onRemove ? <Button label="Remove" variant="ghost" onPress={onRemove} /> : null}
      </View>
      {item.exerciseId ? (
        <View className="flex-row flex-wrap gap-2">
          {modes.map((m) => (
            <Chip key={m} label={labelFor(m)} selected={item.measurementMode === m} onPress={() => onChange({ measurementMode: m })} />
          ))}
        </View>
      ) : null}

      {item.measurementMode ? (
        <View className="gap-2">
          {item.sets.map((s, si) => {
            const error = validateSet(item.measurementMode!, s);
            return (
              <View key={si} className="gap-1.5 rounded-control border border-surface-border bg-surface-raised p-2.5">
                <Text className="text-sm font-semibold text-ink-muted">Set {si + 1}</Text>
                <SetFields mode={item.measurementMode!} set={s} onChange={(patch) => updateSet(si, patch)} />
                {error ? <Text className="text-xs text-danger">{error}</Text> : null}
                {item.sets.length > 1 ? (
                  <Button label="Remove set" variant="ghost" onPress={() => onChange({ sets: item.sets.filter((_, x) => x !== si) })} />
                ) : null}
              </View>
            );
          })}
          <View className="flex-row flex-wrap gap-2">
            <Button label="Add set" variant="secondary" onPress={() => onChange({ sets: [...item.sets, emptySet()] })} />
            <Button
              label="Add pyramid (3 sets)"
              variant="ghost"
              onPress={() => onChange(addPyramidSets(item, 3, Number(item.sets[0]?.targetReps) || 8))}
            />
            <Button label="Add back-off set" variant="ghost" onPress={() => onChange(addBackOffSet(item))} />
          </View>
        </View>
      ) : null}

      <ExercisePickerModal
        visible={pickerOpen}
        approvedOnly={approvedOnly}
        onClose={() => setPickerOpen(false)}
        onPick={(ex) => {
          onChange({ exerciseId: ex.id, exerciseName: ex.name, exerciseMeasurementTypes: ex.measurement_types, measurementMode: null });
          setPickerOpen(false);
        }}
      />
    </Card>
  );
}

function SetFields({ mode, set, onChange }: { mode: string; set: SetDraft; onChange: (patch: Partial<SetDraft>) => void }) {
  const showReps = ['reps', 'added_weight', 'assisted_weight', 'until_failure', 'technique_practice'].includes(mode);
  const showDuration = ['duration', 'holds', 'added_weight', 'assisted_weight', 'until_failure', 'technique_practice'].includes(mode);
  const showDistance = mode === 'distance';
  const showLoad = mode === 'added_weight' || mode === 'assisted_weight';
  return (
    <View className="gap-2">
      <View className="flex-row flex-wrap gap-2">
        {showReps ? (
          <View className="w-24">
            <TextField label="Reps" keyboardType="number-pad" value={set.targetReps} onChangeText={(v) => onChange({ targetReps: v })} />
          </View>
        ) : null}
        {showDuration ? (
          <View className="w-28">
            <TextField label="Seconds" keyboardType="number-pad" value={set.targetDurationSeconds} onChangeText={(v) => onChange({ targetDurationSeconds: v })} />
          </View>
        ) : null}
        {showDistance ? (
          <View className="w-28">
            <TextField label="Meters" keyboardType="decimal-pad" value={set.targetDistanceMeters} onChangeText={(v) => onChange({ targetDistanceMeters: v })} />
          </View>
        ) : null}
        {showLoad ? (
          <View className="w-24">
            <TextField
              label="Load kg"
              keyboardType="decimal-pad"
              value={set.targetLoadKg}
              onChangeText={(v) => onChange({ targetLoadKg: v, loadType: mode === 'added_weight' ? 'added' : 'assisted' })}
            />
          </View>
        ) : null}
        <View className="w-24">
          <TextField label="Rest s" keyboardType="number-pad" value={set.targetRestSeconds} onChangeText={(v) => onChange({ targetRestSeconds: v })} />
        </View>
        <View className="w-20">
          <TextField label="RPE" keyboardType="decimal-pad" value={set.targetRpe} onChangeText={(v) => onChange({ targetRpe: v })} />
        </View>
      </View>
      <TextField label="Notes" value={set.notes} onChangeText={(v) => onChange({ notes: v })} placeholder="Optional" />
    </View>
  );
}

function ExercisePickerModal({
  visible,
  approvedOnly,
  onClose,
  onPick,
}: {
  visible: boolean;
  approvedOnly: boolean;
  onClose: () => void;
  onPick: (ex: ExerciseOption) => void;
}) {
  const [query, setQuery] = useState('');
  const exercises = useQuery({
    queryKey: ['workout-builder-exercises', approvedOnly],
    enabled: visible,
    queryFn: async () => {
      let q = supabase.from('exercises').select('id, name, measurement_types, status, is_official');
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []).filter((e) => !approvedOnly || (e.status === 'approved' && e.is_official)) as ExerciseOption[];
    },
  });
  const rows = (exercises.data ?? []).filter((e) => e.name.toLowerCase().includes(query.trim().toLowerCase()));

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView className="flex-1 bg-surface">
        <View className="w-full max-w-[640px] flex-1 self-center gap-3 p-4">
          <Text className="text-title text-ink">Choose an exercise</Text>
          <TextField label="Search" value={query} onChangeText={setQuery} autoCorrect={false} />
          {rows.map((ex) => (
            <Button key={ex.id} label={ex.name} variant="secondary" onPress={() => onPick(ex)} />
          ))}
          <Button label="Cancel" variant="ghost" onPress={onClose} />
        </View>
      </SafeAreaView>
    </Modal>
  );
}
