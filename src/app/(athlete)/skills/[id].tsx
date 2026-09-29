import { useQueryClient } from '@tanstack/react-query';
import { useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { FlatList, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { EditSkillProgressionModal } from '@/components/EditSkillProgressionModal';
import { LogSkillAttemptModal } from '@/components/LogSkillAttemptModal';
import { SkillLadderRung } from '@/components/SkillLadderRung';
import { Button, CenteredSpinner, Notice } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { rungTier } from '@/features/skills/ladder';
import { describeError } from '@/lib/errors';
import { randomId } from '@/lib/random-id';
import { setAthleteSkillStatus, useAthleteSkillAchievements, useAthleteSkillStatus, useSkillCatalog } from '@/lib/skills';

/**
 * Sprint 6 · Task 6.13 — a skill ladder's rungs (Feature 8.1/8.2): trained /
 * verified badges, "Train this rung" (Tier 1, F-S6-P04), "Log attempt" (Tier 2,
 * self only — `log_skill_attempt` always attributes to the caller), and, for
 * authorized coaches/officers, criteria editing (Feature 8.1, F-S6-P07).
 */
export default function SkillDetailScreen() {
  const { id, athleteId: paramAthleteId } = useLocalSearchParams<{ id: string; athleteId?: string }>();
  const { profile, access } = useAuth();
  const queryClient = useQueryClient();
  const athleteId = paramAthleteId || profile?.id;
  const isSelf = !paramAthleteId || paramAthleteId === profile?.id;
  const canManage = hasPermission(access, 'skills:manage');

  const catalog = useSkillCatalog();
  const status = useAthleteSkillStatus(athleteId);
  const achievements = useAthleteSkillAchievements(athleteId);

  const [expandedRungId, setExpandedRungId] = useState<string | null>(null);
  const [settingRungId, setSettingRungId] = useState<string | null>(null);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const [loggingRung, setLoggingRung] = useState<{ id: string; name: string; targetHoldSeconds: number | null; targetReps: number | null } | null>(null);
  const [editingRung, setEditingRung] = useState<{ id: string; name: string; description: string | null; targetHoldSeconds: number | null; targetReps: number | null } | null>(null);

  const skill = catalog.data?.find((s) => s.id === id);

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: ['athlete-skill-status', athleteId] });
    void queryClient.invalidateQueries({ queryKey: ['athlete-skill-achievements', athleteId] });
    void queryClient.invalidateQueries({ queryKey: ['skill-catalog'] });
  };

  const setTrained = async (rungId: string) => {
    if (!skill || !athleteId) return;
    setSettingRungId(rungId);
    setMessage(null);
    const { error } = await setAthleteSkillStatus({ athleteId, skillId: skill.id, progressionId: rungId, idempotencyKey: randomId() });
    setSettingRungId(null);
    if (error) {
      setMessage({
        tone: 'danger',
        text: describeError(error, { '42501': 'Only the athlete, their current coach, or an officer can set the trained rung.' }),
      });
      return;
    }
    setMessage({ tone: 'success', text: 'Updated.' });
    invalidate();
  };

  if (catalog.isPending || status.isPending || achievements.isPending) return <CenteredSpinner label="Loading…" />;

  if (catalog.isError) {
    return (
      <SafeAreaView edges={['bottom']} className="flex-1 bg-surface p-4">
        <Notice tone="danger">{describeError(catalog.error)}</Notice>
      </SafeAreaView>
    );
  }
  if (!skill) {
    return (
      <SafeAreaView edges={['bottom']} className="flex-1 bg-surface p-4">
        <Notice tone="danger">This skill could not be found.</Notice>
      </SafeAreaView>
    );
  }

  const currentProgressionId = status.data?.get(skill.id);

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={skill.rungs}
        keyExtractor={(r) => r.id}
        contentContainerClassName="w-full max-w-[640px] self-center gap-2 px-4 py-4"
        ListHeaderComponent={
          <View className="gap-3 pb-2">
            <Text className="text-display text-ink">{skill.name}</Text>
            {skill.description ? <Text className="text-ink-muted">{skill.description}</Text> : null}
            {message ? <Notice tone={message.tone}>{message.text}</Notice> : null}
            {status.isError ? <Notice tone="danger">{describeError(status.error)}</Notice> : null}
          </View>
        }
        renderItem={({ item: rung }) => {
          const tier = rungTier(rung.id, currentProgressionId, achievements.data?.get(rung.id));
          const expanded = expandedRungId === rung.id;
          return (
            <View className="gap-2">
              <SkillLadderRung
                rankOrder={rung.rankOrder}
                name={rung.name}
                description={rung.description}
                targetHoldSeconds={rung.targetHoldSeconds}
                targetReps={rung.targetReps}
                tier={tier}
                onPress={() => setExpandedRungId(expanded ? null : rung.id)}
                onEdit={canManage ? () => setEditingRung(rung) : undefined}
              />
              {expanded ? (
                <View className="flex-row gap-2 pl-10">
                  {rung.id !== currentProgressionId ? (
                    <View className="flex-1">
                      <Button label="Train this rung" variant="secondary" loading={settingRungId === rung.id} onPress={() => setTrained(rung.id)} />
                    </View>
                  ) : null}
                  {isSelf ? (
                    <View className="flex-1">
                      <Button label="Log attempt" onPress={() => setLoggingRung(rung)} />
                    </View>
                  ) : null}
                </View>
              ) : null}
            </View>
          );
        }}
      />
      <LogSkillAttemptModal
        visible={!!loggingRung}
        rung={loggingRung ?? { id: '', name: '', targetHoldSeconds: null, targetReps: null }}
        onClose={() => setLoggingRung(null)}
        onLogged={() => {
          setLoggingRung(null);
          setMessage({ tone: 'success', text: 'Attempt submitted for review.' });
        }}
      />
      <EditSkillProgressionModal
        visible={!!editingRung}
        rung={editingRung}
        onClose={() => setEditingRung(null)}
        onUpdated={() => {
          setEditingRung(null);
          setMessage({ tone: 'success', text: 'Criteria updated.' });
          void queryClient.invalidateQueries({ queryKey: ['skill-catalog'] });
        }}
      />
    </SafeAreaView>
  );
}
