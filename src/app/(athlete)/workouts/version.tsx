import { useMutation, useQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';

import { WorkoutBlocksEditor } from '@/components/WorkoutBlocksEditor';
import { Button, CenteredSpinner, Heading, Notice, Screen, TextField } from '@/components/ui';
import { buildBlocksPayload, emptyBlock, validateDraft, type BlockDraft } from '@/features/workouts/workout-builder';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 3.13: the Rule C version-upgrade modal, as a screen. Publishing never
 * edits an existing version: it appends a new sealed version. Which
 * assignments adopt it is a Sprint 5 concern (no assignments exist yet).
 */
export default function PublishWorkoutVersionScreen() {
  const { templateId } = useLocalSearchParams<{ templateId: string }>();
  const [notes, setNotes] = useState('');
  const [blocks, setBlocks] = useState<BlockDraft[]>([emptyBlock()]);
  const [showErrors, setShowErrors] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const template = useQuery({
    queryKey: ['workout-template-visibility', templateId],
    enabled: !!templateId,
    queryFn: async () => {
      const { data, error } = await supabase.from('workout_templates').select('name, visibility').eq('id', templateId).single();
      if (error) throw error;
      return data;
    },
  });

  const errors = validateDraft('placeholder', blocks);

  const publish = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('publish_new_workout_version', {
        p_template_id: templateId,
        p_version_notes: notes.trim(),
        p_blocks: buildBlocksPayload(blocks),
      });
      if (error) throw error;
      return data as { template_id: string };
    },
    onSuccess: (data) => router.replace({ pathname: '/workouts/[id]', params: { id: data.template_id } }),
    onError: (error) => setMessage(describeError(error)),
  });

  const submit = () => {
    if (blocks.length < 1 || errors.blocks) {
      setShowErrors(true);
      return;
    }
    setMessage(null);
    publish.mutate();
  };

  if (template.isPending) return <CenteredSpinner label="Loading routine…" />;

  return (
    <Screen>
      <Heading subtitle={template.data?.name}>Publish a new version</Heading>
      {message ? <Notice tone="danger">{message}</Notice> : null}
      <TextField label="Changelog note" value={notes} onChangeText={setNotes} placeholder="What changed?" />
      <WorkoutBlocksEditor blocks={blocks} onChange={setBlocks} approvedOnly={template.data?.visibility === 'organization'} />
      {showErrors && errors.blocks ? <Notice tone="danger">Fix the highlighted fields before publishing.</Notice> : null}
      <Button label="Publish version" onPress={submit} loading={publish.isPending} />
    </Screen>
  );
}
