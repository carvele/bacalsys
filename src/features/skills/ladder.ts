import type { SkillAchievementView, SkillLadder } from '@/lib/skills';

/**
 * Sprint 6 · Task 6.13 — pure presentation logic for the Skill Tree screens
 * (Feature 8.1/8.2): what a rung's target reads as, and which of the three
 * tiers (trained / verified / neither) it shows for a given athlete.
 */

/** "18s hold", "8 reps", or "—" for a rung that (invalidly) carries neither. */
export function rungTargetLabel(rung: { targetHoldSeconds: number | null; targetReps: number | null }): string {
  if (rung.targetHoldSeconds !== null) return `${rung.targetHoldSeconds}s hold`;
  if (rung.targetReps !== null) return `${rung.targetReps} rep${rung.targetReps === 1 ? '' : 's'}`;
  return '—';
}

export type RungTier = 'verified' | 'training' | 'none';

/**
 * A rung is `verified` when the athlete has an ACTIVE (not revoked) achievement
 * on it (Tier 3 always outranks Tier 1 in what the badge shows — a verified
 * rung the athlete has since moved past is still their proudest badge on this
 * ladder), `training` when it is their current Tier-1 rung, otherwise `none`.
 */
export function rungTier(
  rungId: string,
  currentProgressionId: string | undefined,
  achievement: SkillAchievementView | undefined,
): RungTier {
  if (achievement?.status === 'active') return 'verified';
  if (rungId === currentProgressionId) return 'training';
  return 'none';
}

/** The ladder's own highest-rank verified rung, for the catalog card's summary badge. */
export function ladderHighestVerified(
  ladder: SkillLadder,
  achievements: Map<string, SkillAchievementView>,
): { rankOrder: number; name: string } | null {
  let best: { rankOrder: number; name: string } | null = null;
  for (const rung of ladder.rungs) {
    const a = achievements.get(rung.id);
    if (a?.status === 'active' && (!best || rung.rankOrder > best.rankOrder)) best = { rankOrder: rung.rankOrder, name: rung.name };
  }
  return best;
}

/** The ladder's own current trained rung (Tier 1), for the catalog card. */
export function ladderCurrentRung(ladder: SkillLadder, statusBySkill: Map<string, string>): { rankOrder: number; name: string } | null {
  const progressionId = statusBySkill.get(ladder.id);
  if (!progressionId) return null;
  const rung = ladder.rungs.find((r) => r.id === progressionId);
  return rung ? { rankOrder: rung.rankOrder, name: rung.name } : null;
}
