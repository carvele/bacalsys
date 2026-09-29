import { ladderCurrentRung, ladderHighestVerified, rungTargetLabel, rungTier } from '../ladder';
import type { SkillAchievementView, SkillLadder } from '@/lib/skills';

const achievement = (overrides: Partial<SkillAchievementView> = {}): SkillAchievementView => ({
  id: 'ach-1',
  progressionId: 'rung-1',
  status: 'active',
  verifiedAt: '2026-09-01',
  verifiedBy: 'coach-1',
  revokedAt: null,
  revocationReason: null,
  ...overrides,
});

describe('rungTargetLabel', () => {
  it('reads a hold target, a rep target, or a dash for neither', () => {
    expect(rungTargetLabel({ targetHoldSeconds: 18, targetReps: null })).toBe('18s hold');
    expect(rungTargetLabel({ targetHoldSeconds: null, targetReps: 8 })).toBe('8 reps');
    expect(rungTargetLabel({ targetHoldSeconds: null, targetReps: 1 })).toBe('1 rep');
    expect(rungTargetLabel({ targetHoldSeconds: null, targetReps: null })).toBe('—');
  });
});

describe('rungTier', () => {
  it('an active achievement always reads "verified", even if it is also the current trained rung', () => {
    expect(rungTier('rung-1', 'rung-1', achievement())).toBe('verified');
  });
  it('a revoked achievement does NOT count as verified', () => {
    expect(rungTier('rung-1', undefined, achievement({ status: 'revoked' }))).toBe('none');
  });
  it('the current trained rung with no achievement reads "training"', () => {
    expect(rungTier('rung-2', 'rung-2', undefined)).toBe('training');
  });
  it('anything else reads "none"', () => {
    expect(rungTier('rung-3', 'rung-2', undefined)).toBe('none');
  });
});

const ladder: SkillLadder = {
  id: 'skill-planche',
  name: 'Planche',
  slug: 'planche',
  category: 'push',
  description: null,
  rungs: [
    { id: 'r1', rankOrder: 1, name: 'Tuck Planche', description: null, targetHoldSeconds: 15, targetReps: null },
    { id: 'r2', rankOrder: 2, name: 'Advanced Tuck Planche', description: null, targetHoldSeconds: 12, targetReps: null },
    { id: 'r3', rankOrder: 3, name: 'Straddle Planche', description: null, targetHoldSeconds: 10, targetReps: null },
  ],
};

describe('ladderHighestVerified', () => {
  it('picks the highest-ranked ACTIVE achievement on the ladder', () => {
    const achievements = new Map([
      ['r1', achievement({ progressionId: 'r1' })],
      ['r2', achievement({ progressionId: 'r2' })],
    ]);
    expect(ladderHighestVerified(ladder, achievements)).toEqual({ rankOrder: 2, name: 'Advanced Tuck Planche' });
  });
  it('ignores revoked rows and returns null when nothing is active', () => {
    const achievements = new Map([['r2', achievement({ progressionId: 'r2', status: 'revoked' })]]);
    expect(ladderHighestVerified(ladder, achievements)).toBeNull();
    expect(ladderHighestVerified(ladder, new Map())).toBeNull();
  });
});

describe('ladderCurrentRung', () => {
  it('finds the athlete’s trained rung on this ladder', () => {
    const status = new Map([['skill-planche', 'r2']]);
    expect(ladderCurrentRung(ladder, status)).toEqual({ rankOrder: 2, name: 'Advanced Tuck Planche' });
  });
  it('is null when the athlete has no status on this skill, or it points at an unknown rung', () => {
    expect(ladderCurrentRung(ladder, new Map())).toBeNull();
    expect(ladderCurrentRung(ladder, new Map([['skill-planche', 'nonexistent']]))).toBeNull();
  });
});
