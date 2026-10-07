import type { ReplayItem, ReplaySet, ReplaySubstitution, SessionReplay } from '@/types/skills';

/**
 * Sprint 6 · Task 6.12 — presentation logic for the Session Replay screen: how a
 * prescribed set and the actual set performed against it read, which badge a set
 * carries, and how substitution reasons are worded. Pure and Jest-tested.
 */

const trim = (n: number) => (Number.isInteger(n) ? String(n) : String(Number(n.toFixed(2))));

export function formatLoad(kg: number | null, type: string | null): string | null {
  if (kg === null || kg <= 0) return type === 'bodyweight' ? 'bodyweight' : null;
  if (type === 'assisted') return `${trim(kg)} kg assist`;
  return `+${trim(kg)} kg`;
}

function describe(parts: {
  reps: number | null;
  durationSeconds: number | null;
  distanceMeters: number | null;
  loadKg: number | null;
  loadType: string | null;
  rpe: number | null;
}): string {
  const out: string[] = [];
  if (parts.reps !== null) out.push(`${parts.reps} rep${parts.reps === 1 ? '' : 's'}`);
  if (parts.durationSeconds !== null) out.push(`${parts.durationSeconds} s`);
  if (parts.distanceMeters !== null) out.push(`${trim(parts.distanceMeters)} m`);
  const load = formatLoad(parts.loadKg, parts.loadType);
  if (load) out.push(load);
  if (parts.rpe !== null) out.push(`RPE ${trim(parts.rpe)}`);
  return out.join(' · ');
}

/** The prescription for a set ("—" for an athlete-added extra set, which has none). */
export function formatTarget(set: ReplaySet): string {
  if (set.isExtra) return '—';
  return (
    describe({
      reps: set.targetReps,
      durationSeconds: set.targetDurationSeconds,
      distanceMeters: set.targetDistanceMeters,
      loadKg: set.targetLoadKg,
      loadType: set.targetLoadType,
      rpe: set.targetRpe,
    }) || 'As prescribed'
  );
}

/** What the athlete actually did ("—" when nothing was logged for the set). */
export function formatActual(set: ReplaySet): string {
  if (set.sessionSetId === null) return '—';
  return (
    describe({
      reps: set.actualReps,
      durationSeconds: set.actualDurationSeconds,
      distanceMeters: set.actualDistanceMeters,
      loadKg: set.actualLoadKg,
      loadType: set.actualLoadType,
      rpe: set.rpe,
    }) || (set.isCompleted ? 'Done' : 'Not completed')
  );
}

export type SetBadge = 'done' | 'extra' | 'skipped' | 'pending';

/**
 * Extra sets are always labelled extra. A prescribed set that was not completed
 * is "skipped" once the session has ended, but merely "pending" while the session
 * is still in progress (the athlete may still do it).
 */
export function setBadge(set: ReplaySet, sessionStatus: string): SetBadge {
  if (set.isExtra) return 'extra';
  if (set.isSkipped) return sessionStatus === 'in_progress' ? 'pending' : 'skipped';
  return 'done';
}

export const SET_BADGE_LABEL: Record<SetBadge, string> = { done: 'Done', extra: 'Extra set', skipped: 'Skipped', pending: 'Pending' };

const SUBSTITUTION_REASON: Record<string, string> = {
  equipment_unavailable: 'Equipment unavailable',
  pain_discomfort: 'Pain or discomfort',
  too_difficult: 'Too difficult',
  too_easy: 'Too easy',
  injury_limitation: 'Injury limitation',
  personal_adjustment: 'Personal adjustment',
  other: 'Other',
};
export const substitutionReasonLabel = (code: string) => SUBSTITUTION_REASON[code] ?? code;

/** Reasons only the athlete, their current coach and VP/President may read (Rule E). */
export const isMedicalReason = (code: string) => code === 'pain_discomfort' || code === 'injury_limitation';

/** The substitution recorded against a prescribed item, if the viewer may see it. */
export const substitutionFor = (replay: SessionReplay, item: ReplayItem): ReplaySubstitution | undefined =>
  replay.substitutions.find((s) => s.originalWorkoutItemId === item.workoutItemId);

const ABANDON_REASON: Record<string, string> = {
  time_constraint: 'Ran out of time',
  equipment_issue: 'Equipment issue',
  general_fatigue: 'General fatigue',
  personal_emergency: 'Personal emergency',
  facility_closed: 'Facility closed',
  other: 'Other',
};

export function sessionOutcome(session: SessionReplay['session']): string {
  if (session.status === 'completed') return 'Completed';
  if (session.status === 'in_progress') return 'In progress';
  if (session.status === 'abandoned') {
    const why = session.abandonmentReasonCode ? ABANDON_REASON[session.abandonmentReasonCode] ?? session.abandonmentReasonCode : null;
    return why ? `Ended early — ${why}` : 'Ended early';
  }
  return session.status;
}

/** Totals for the replay header: prescribed sets vs completed sets vs extras. */
export function replayTotals(items: readonly ReplayItem[]) {
  let prescribed = 0;
  let completed = 0;
  let extra = 0;
  for (const item of items) {
    for (const s of item.sets) {
      if (s.isExtra) {
        if (s.isCompleted) extra += 1;
        continue;
      }
      prescribed += 1;
      if (!s.isSkipped) completed += 1;
    }
  }
  return { prescribed, completed, extra };
}

/**
 * Stable React key for one paired set row. (workoutItemId, setNumber) is NOT unique: an
 * athlete-added extra set and the prescribed set sharing its number both appear
 * (F-S6-E07). A row always carries a prescribed id, a session-set id, or both.
 */
export function replaySetKey(itemId: string, s: ReplaySet): string {
  return `${itemId}:${s.prescribedItemSetId ?? '-'}:${s.sessionSetId ?? '-'}`;
}
