import { router, useLocalSearchParams } from 'expo-router';
import { FlatList, Pressable, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Card, CenteredSpinner, Notice } from '@/components/ui';
import { ladderCurrentRung, ladderHighestVerified } from '@/features/skills/ladder';
import { useAuth } from '@/features/auth/use-auth';
import { describeError } from '@/lib/errors';
import { useAthleteSkillAchievements, useAthleteSkillStatus, useSkillCatalog } from '@/lib/skills';
import { skillCategoryLabel } from '@/types/skills';

/**
 * Sprint 6 · Task 6.13 — the Skill Tree catalog (Feature 8.1/8.2). Shows the
 * caller's own trained/verified status by default; `?athleteId=UUID` lets a
 * coach or officer drill into an athlete they can see (RLS on
 * athlete_skill_status / skill_achievements decides what actually comes back).
 */
export default function SkillCatalogScreen() {
  const { athleteId: paramAthleteId } = useLocalSearchParams<{ athleteId?: string }>();
  const { profile } = useAuth();
  const athleteId = paramAthleteId || profile?.id;
  const viewingOther = !!paramAthleteId && paramAthleteId !== profile?.id;

  const catalog = useSkillCatalog();
  const status = useAthleteSkillStatus(athleteId);
  const achievements = useAthleteSkillAchievements(athleteId);

  const openSkill = (skillId: string) =>
    router.push({ pathname: '/skills/[id]', params: { id: skillId, ...(paramAthleteId ? { athleteId: paramAthleteId } : {}) } });

  if (catalog.isPending || status.isPending || achievements.isPending) return <CenteredSpinner label="Loading skill trees…" />;

  return (
    <SafeAreaView edges={['bottom']} className="flex-1 bg-surface">
      <FlatList
        data={catalog.data ?? []}
        keyExtractor={(s) => s.id}
        contentContainerClassName="w-full max-w-[640px] self-center gap-3 px-4 py-4"
        ListHeaderComponent={
          <View className="gap-3 pb-1">
            {catalog.isError ? <Notice tone="danger">{describeError(catalog.error)}</Notice> : null}
            {status.isError ? <Notice tone="danger">{describeError(status.error)}</Notice> : null}
            {viewingOther ? <Text className="text-sm text-ink-muted">Viewing this athlete&apos;s skill trees.</Text> : null}
          </View>
        }
        ListEmptyComponent={
          !catalog.isError ? (
            <Card>
              <Text className="text-center text-ink-muted">No skill trees have been set up yet.</Text>
            </Card>
          ) : null
        }
        renderItem={({ item }) => {
          const current = ladderCurrentRung(item, status.data ?? new Map());
          const verified = ladderHighestVerified(item, achievements.data ?? new Map());
          return (
            <Pressable accessibilityRole="button" accessibilityLabel={item.name} onPress={() => openSkill(item.id)}>
              <Card className="gap-1">
                <View className="flex-row items-center justify-between">
                  <Text className="text-title text-ink">{item.name}</Text>
                  <Text className="text-xs uppercase tracking-wide text-ink-faint">{skillCategoryLabel(item.category)}</Text>
                </View>
                <Text className="text-sm text-ink-muted">
                  {item.rungs.length} rung{item.rungs.length === 1 ? '' : 's'}
                </Text>
                {verified ? <Text className="text-sm font-semibold text-success">Verified: {verified.name}</Text> : null}
                {!verified && current ? <Text className="text-sm font-semibold text-brand">Training: {current.name}</Text> : null}
                {!verified && !current ? <Text className="text-sm text-ink-faint">Not started</Text> : null}
              </Card>
            </Pressable>
          );
        }}
      />
    </SafeAreaView>
  );
}
