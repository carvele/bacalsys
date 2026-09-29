import { Text, View } from 'react-native';

import { Card } from '@/components/ui';
import {
  SET_BADGE_LABEL,
  formatActual,
  formatTarget,
  isMedicalReason,
  setBadge,
  substitutionFor,
  substitutionReasonLabel,
} from '@/features/history/replay';
import type { SessionReplay } from '@/types/skills';

/**
 * Sprint 6 · Task 6.12 — the Prescribed vs. Actual comparison table at the heart
 * of the Session Replay screen. One card per workout item, its logged sets
 * listed target-beside-actual with a status badge, and — when the item was
 * substituted — the lineage from the original prescribed exercise to whatever
 * was actually performed, with the substitution's reason.
 */

const BADGE_STYLE: Record<string, string> = {
  done: 'bg-success-soft text-success',
  extra: 'bg-brand-soft text-brand',
  skipped: 'bg-surface-sunken text-ink-faint',
  pending: 'bg-warning-soft text-warning',
};

export function SessionReplayTable({ replay }: { replay: SessionReplay }) {
  return (
    <View className="gap-3">
      {replay.items.map((item) => {
        const substitution = item.isSubstituted ? substitutionFor(replay, item) : undefined;
        const medical = substitution ? isMedicalReason(substitution.reasonCode) : false;
        return (
          <Card key={item.workoutItemId} className="gap-2">
            <Text className="text-title text-ink">{item.prescribedExerciseName}</Text>
            {item.isSubstituted ? (
              <View className="rounded-control bg-surface-sunken px-3 py-2">
                <Text className="text-sm text-ink-muted">
                  Substituted with <Text className="font-semibold text-ink">{item.performedExerciseName ?? 'another exercise'}</Text>
                </Text>
                {substitution ? (
                  <Text className={`text-sm ${medical ? 'font-semibold text-danger' : 'text-ink-faint'}`}>
                    Reason: {substitutionReasonLabel(substitution.reasonCode)}
                  </Text>
                ) : null}
              </View>
            ) : null}

            <View className="gap-1.5">
              <View className="flex-row gap-2 px-1">
                <Text className="w-8 text-xs font-medium uppercase text-ink-faint">Set</Text>
                <Text className="flex-1 text-xs font-medium uppercase text-ink-faint">Target</Text>
                <Text className="flex-1 text-xs font-medium uppercase text-ink-faint">Actual</Text>
                <Text className="w-16 text-right text-xs font-medium uppercase text-ink-faint">Status</Text>
              </View>
              {item.sets.map((set) => {
                const badge = setBadge(set, replay.session.status);
                return (
                  <View key={`${item.workoutItemId}-${set.setNumber}`} className="flex-row items-center gap-2 rounded-control bg-surface-sunken px-2 py-1.5">
                    <Text className="w-8 text-sm text-ink">{set.setNumber}</Text>
                    <Text className="flex-1 text-sm text-ink-muted">{formatTarget(set)}</Text>
                    <Text className="flex-1 text-sm text-ink">{formatActual(set)}</Text>
                    <View className={`w-16 items-end`}>
                      <Text className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${BADGE_STYLE[badge]}`}>{SET_BADGE_LABEL[badge]}</Text>
                    </View>
                  </View>
                );
              })}
              {item.sets.length === 0 ? <Text className="px-1 text-sm text-ink-faint">No sets prescribed.</Text> : null}
            </View>
          </Card>
        );
      })}
    </View>
  );
}
