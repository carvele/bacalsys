import { useMutation, useQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';

import { VersionAdoptionPanel } from '@/components/VersionAdoptionPanel';
import { WorkoutBlocksEditor } from '@/components/WorkoutBlocksEditor';
import { Button, CenteredSpinner, Heading, Notice, Screen, TextField } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { buildBlocksPayload, emptyBlock, isDraftValid, validateDraft, type BlockDraft } from '@/features/workouts/workout-builder';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

/**
 * Task 3.13: the Rule C version-upgrade modal, as a screen. Publishing never
 * edits an existing version: it appends a new sealed version. Sprint 5 · Task
 * 5.12: once it is published, if the routine has active assignments the author
 * chooses how each one adopts it (template only / future assignments only /
 * selected upcoming workouts) — see VersionAdoptionPanel.
 */
export default function PublishWorkoutVersionScreen() {
  const { templateId } = useLocalSearchParams<{ templateId: string }>();
  const [notes, setNotes] = useState('');
  const [blocks, setBlocks] = useState<BlockDraft[]>([emptyBlock()]);
  const [showErrors, setShowErrors] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [published, setPublished] = useState<string | null>(null); // the new version id, once published
  const { access } = useAuth();
  const canAssign = hasPermission(access, 'workout:assign');
  const goToTemplate = () => router.replace({ pathname: '/workouts/[id]', params: { id: templateId } });

  const template = useQuery({
    queryKey: ['workout-template-visibility', templateId],
    enabled: !!templateId,
    queryFn: async () => {
      const { data, error } = await supabase.from('workout_templates').select('name, visibility').eq('id', templateId).single();
      if (error) throw error;
      return data;
    },
  });

  // validateDraft also checks a name; the version screen has none, so name errors are ignored here.
  const errors = validateDraft('placeholder', blocks);
  const structurallyValid = isDraftValid({ ...errors, name: undefined });

  const publish = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('publish_new_workout_version', {
        p_template_id: templateId,
        p_version_notes: notes.trim(),
        p_blocks: buildBlocksPayload(blocks),
      });
      if (error) throw error;
      return data as { template_id: string; version_id: string };
    },
    onSuccess: (data) => {
      // Members who can assign get the Rule C adoption step; everyone else goes straight back.
      if (canAssign) setPublished(data.version_id);
      else router.replace({ pathname: '/workouts/[id]', params: { id: data.template_id } });
    },
    onError: (error) => setMessage(describeError(error)),
  });

  const submit = () => {
    if (!structurallyValid) {
      setShowErrors(true);
      return;
    }
    setMessage(null);
    publish.mutate();
  };

  if (template.isPending) return <CenteredSpinner label="Loading routine…" />;

  if (published) {
    return (
      <Screen>
        <Heading subtitle={template.data?.name}>New version published</Heading>
        <VersionAdoptionPanel templateId={templateId} newVersionId={published} onDone={goToTemplate} />
      </Screen>
    );
  }

  return (
    <Screen>
      <Heading subtitle={template.data?.name}>Publish a new version</Heading>
      {message ? <Notice tone="danger">{message}</Notice> : null}
      <TextField label="Changelog note" value={notes} onChangeText={setNotes} placeholder="What changed?" />
      <WorkoutBlocksEditor blocks={blocks} onChange={setBlocks} approvedOnly={template.data?.visibility === 'organization'} />
      {showErrors && errors.totalSets ? <Notice tone="danger">{errors.totalSets}</Notice> : null}
      {showErrors && !structurallyValid ? <Notice tone="danger">Fix the highlighted fields before publishing.</Notice> : null}
      <Button label="Publish version" onPress={submit} loading={publish.isPending} />
    </Screen>
  );
}
