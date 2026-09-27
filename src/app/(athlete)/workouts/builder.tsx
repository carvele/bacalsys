import { useMutation } from '@tanstack/react-query';
import { router } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';

import { WorkoutBlocksEditor } from '@/components/WorkoutBlocksEditor';
import { Button, Chip, Heading, Notice, Screen, TextField } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { buildBlocksPayload, emptyBlock, isDraftValid, validateDraft, type BlockDraft } from '@/features/workouts/workout-builder';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 3.13: create a workout routine (Feature 4.1). The RPC atomically
 * inserts template → version 1 → blocks → items → sets and seals the version;
 * validation here is a client-side mirror only, the server is authoritative.
 */
export default function WorkoutBuilderScreen() {
  const { access } = useAuth();
  const canPublishOrg = hasPermission(access, 'workouts:publish_org');

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [visibility, setVisibility] = useState<'private' | 'organization'>('private');
  const [blocks, setBlocks] = useState<BlockDraft[]>([emptyBlock()]);
  const [showErrors, setShowErrors] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const errors = validateDraft(name, blocks);

  const create = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('create_workout_template', {
        p_name: name.trim(),
        p_description: description.trim(),
        p_visibility: visibility,
        p_blocks: buildBlocksPayload(blocks),
      });
      if (error) throw error;
      return data as { template_id: string };
    },
    onSuccess: (data) => router.replace({ pathname: '/workouts/[id]', params: { id: data.template_id } }),
    onError: (error) => setMessage(describeError(error)),
  });

  const submit = () => {
    if (!isDraftValid(errors)) {
      setShowErrors(true);
      return;
    }
    setMessage(null);
    create.mutate();
  };

  return (
    <Screen>
      <Heading subtitle="Blocks, exercises, and set-by-set targets">New routine</Heading>
      <View className="gap-4">
        {message ? <Notice tone="danger">{message}</Notice> : null}
        <TextField label="Name" value={name} onChangeText={setName} error={showErrors ? errors.name : null} />
        {showErrors && errors.totalSets ? <Notice tone="danger">{errors.totalSets}</Notice> : null}
        <TextField label="Description" value={description} onChangeText={setDescription} placeholder="Optional" />
        <View className="gap-1.5">
          <Text className="text-sm font-medium text-ink-muted">Visibility</Text>
          <View className="flex-row gap-2">
            <Chip label="Private (my library)" selected={visibility === 'private'} onPress={() => setVisibility('private')} />
            {canPublishOrg ? (
              <Chip label="Club template" selected={visibility === 'organization'} onPress={() => setVisibility('organization')} />
            ) : null}
          </View>
          {visibility === 'organization' ? (
            <Text className="text-xs text-ink-faint">Only approved library exercises may be used in a club template.</Text>
          ) : null}
        </View>

        <WorkoutBlocksEditor blocks={blocks} onChange={setBlocks} approvedOnly={visibility === 'organization'} />

        <Button label="Save routine" onPress={submit} loading={create.isPending} />
      </View>
    </Screen>
  );
}
