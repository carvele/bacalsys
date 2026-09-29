import { Pressable, Text, View } from 'react-native';

import { rungTargetLabel, type RungTier } from '@/features/skills/ladder';

/** Sprint 6 · Task 6.13 — one rung in a skill ladder's vertical accordion. */
export function SkillLadderRung({
  rankOrder,
  name,
  description,
  targetHoldSeconds,
  targetReps,
  tier,
  onPress,
  onEdit,
}: {
  rankOrder: number;
  name: string;
  description: string | null;
  targetHoldSeconds: number | null;
  targetReps: number | null;
  tier: RungTier;
  onPress?: () => void;
  onEdit?: () => void;
}) {
  const badge =
    tier === 'verified'
      ? { text: 'Verified', style: 'bg-success-soft text-success' }
      : tier === 'training'
        ? { text: 'Training', style: 'bg-brand-soft text-brand' }
        : null;

  return (
    <Pressable
      accessibilityRole={onPress ? 'button' : undefined}
      onPress={onPress}
      className={`flex-row gap-3 rounded-control border p-3 ${tier === 'verified' ? 'border-success' : tier === 'training' ? 'border-brand' : 'border-surface-border'}`}
    >
      <View className="h-7 w-7 items-center justify-center rounded-full bg-surface-sunken">
        <Text className="text-sm font-bold text-ink">{rankOrder}</Text>
      </View>
      <View className="flex-1 gap-0.5">
        <View className="flex-row items-center gap-2">
          <Text className="flex-1 font-semibold text-ink">{name}</Text>
          {badge ? <Text className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${badge.style}`}>{badge.text}</Text> : null}
        </View>
        <Text className="text-sm text-ink-muted">{rungTargetLabel({ targetHoldSeconds, targetReps })}</Text>
        {description ? <Text className="text-xs text-ink-faint">{description}</Text> : null}
      </View>
      {onEdit ? (
        <Pressable accessibilityRole="button" accessibilityLabel={`Edit ${name}`} hitSlop={8} onPress={onEdit} className="justify-center px-1">
          <Text className="text-sm font-semibold text-brand">Edit</Text>
        </Pressable>
      ) : null}
    </Pressable>
  );
}
