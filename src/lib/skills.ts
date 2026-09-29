import { useQuery } from '@tanstack/react-query';

import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import type { AchievementStatus, AttemptStatus, SkillCategory } from '@/types/skills';

type Functions = Database['public']['Functions'];
/** The generated RPC argument types (each types every argument non-null; the RPCs accept null for the optional ones). */
type SetSkillStatusArgs = Functions['set_athlete_skill_status']['Args'];
type LogSkillAttemptArgs = Functions['log_skill_attempt']['Args'];
type ReviewSkillAttemptArgs = Functions['review_skill_attempt']['Args'];
type VerifySkillAchievementArgs = Functions['verify_skill_achievement']['Args'];
type RevokeSkillAchievementArgs = Functions['revoke_skill_achievement']['Args'];
type UpdateSkillProgressionArgs = Functions['update_skill_progression']['Args'];

interface RawPendingAttempt {
  id: string;
  progression_id: string;
  attempt_date: string;
  actual_hold_seconds: number | null;
  actual_reps: number | null;
  video_url: string | null;
  status: string;
  reviewed_at: string | null;
  review_feedback: string | null;
  athlete_id: string;
  athlete: { full_name: string } | null;
  progression: { name: string; skill: { name: string } | null } | null;
}

/**
 * Sprint 6 · Task 6.10 — TanStack Query read hooks and RPC mutation wrappers for
 * the calisthenics skills workflow (Feature 8). Reads use `useQuery`, filtered
 * to whatever RLS already allows; writes are thin async wrappers over the
 * mutating RPCs (same shape as `VersionAdoptionPanel`'s `migrate_assignment_version`
 * call) so screens supply their own idempotency key and submitting state rather
 * than sharing one across unrelated actions.
 */

export interface SkillLadder {
  id: string;
  name: string;
  slug: string;
  category: SkillCategory;
  description: string | null;
  rungs: {
    id: string;
    rankOrder: number;
    name: string;
    description: string | null;
    targetHoldSeconds: number | null;
    targetReps: number | null;
  }[];
}

/** Every skill ladder visible to the caller (their organization's, per RLS), rungs in rank order. */
export function useSkillCatalog() {
  return useQuery({
    queryKey: ['skill-catalog'],
    staleTime: 5 * 60 * 1000,
    queryFn: async (): Promise<SkillLadder[]> => {
      const { data, error } = await supabase
        .from('skills')
        .select(
          'id, name, slug, category, description, skill_progressions(id, rank_order, name, description, target_hold_seconds, target_reps)',
        )
        .order('name');
      if (error) throw error;
      return (data ?? []).map((s) => ({
        id: s.id,
        name: s.name,
        slug: s.slug,
        category: s.category as SkillCategory,
        description: s.description,
        rungs: (s.skill_progressions ?? [])
          .map((r) => ({
            id: r.id,
            rankOrder: r.rank_order,
            name: r.name,
            description: r.description,
            targetHoldSeconds: r.target_hold_seconds,
            targetReps: r.target_reps,
          }))
          .sort((a, b) => a.rankOrder - b.rankOrder),
      }));
    },
  });
}

/** The athlete's Tier-1 (trained) status: skill_id → current rung id. RLS scopes which athlete's rows return. */
export function useAthleteSkillStatus(athleteId: string | undefined) {
  return useQuery({
    queryKey: ['athlete-skill-status', athleteId],
    enabled: !!athleteId,
    queryFn: async (): Promise<Map<string, string>> => {
      const { data, error } = await supabase
        .from('athlete_skill_status')
        .select('skill_id, current_progression_id')
        .eq('athlete_id', athleteId!);
      if (error) throw error;
      return new Map((data ?? []).map((r) => [r.skill_id, r.current_progression_id]));
    },
  });
}

export interface SkillAchievementView {
  id: string;
  progressionId: string;
  status: AchievementStatus;
  verifiedAt: string;
  verifiedBy: string;
  revokedAt: string | null;
  revocationReason: string | null;
}

/** The athlete's Tier-3 (verified) milestones, club-visible per RLS. Keyed by rung id for the ladder badge. */
export function useAthleteSkillAchievements(athleteId: string | undefined) {
  return useQuery({
    queryKey: ['athlete-skill-achievements', athleteId],
    enabled: !!athleteId,
    queryFn: async (): Promise<Map<string, SkillAchievementView>> => {
      const { data, error } = await supabase
        .from('skill_achievements')
        .select('id, progression_id, status, verified_at, verified_by, revoked_at, revocation_reason')
        .eq('athlete_id', athleteId!);
      if (error) throw error;
      return new Map(
        (data ?? []).map((r) => [
          r.progression_id,
          {
            id: r.id,
            progressionId: r.progression_id,
            status: r.status as AchievementStatus,
            verifiedAt: r.verified_at,
            verifiedBy: r.verified_by,
            revokedAt: r.revoked_at,
            revocationReason: r.revocation_reason,
          },
        ]),
      );
    },
  });
}

export interface SkillAttemptView {
  id: string;
  progressionId: string;
  attemptDate: string;
  actualHoldSeconds: number | null;
  actualReps: number | null;
  videoUrl: string | null;
  status: AttemptStatus;
  reviewedAt: string | null;
  reviewFeedback: string | null;
}

/** The athlete's own Tier-2 attempts on one rung, newest first (Log Attempt modal history). */
export function useSkillAttempts(athleteId: string | undefined, progressionId: string | undefined) {
  return useQuery({
    queryKey: ['skill-attempts', athleteId, progressionId],
    enabled: !!athleteId && !!progressionId,
    queryFn: async (): Promise<SkillAttemptView[]> => {
      const { data, error } = await supabase
        .from('skill_attempts')
        .select('id, progression_id, attempt_date, actual_hold_seconds, actual_reps, video_url, status, reviewed_at, review_feedback')
        .eq('athlete_id', athleteId!)
        .eq('progression_id', progressionId!)
        .order('attempt_date', { ascending: false })
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []).map((r) => ({
        id: r.id,
        progressionId: r.progression_id,
        attemptDate: r.attempt_date,
        actualHoldSeconds: r.actual_hold_seconds,
        actualReps: r.actual_reps,
        videoUrl: r.video_url,
        status: r.status as AttemptStatus,
        reviewedAt: r.reviewed_at,
        reviewFeedback: r.review_feedback,
      }));
    },
  });
}

export interface PendingAttemptView extends SkillAttemptView {
  athleteId: string;
  athleteName: string;
  skillName: string;
  progressionName: string;
}

/**
 * The coach/officer triage queue: every `pending_review` attempt the caller may
 * act on (RLS/`can_verify_skill` already scopes this to assigned athletes for a
 * Coach, or the whole organization for VP/President), oldest first.
 */
export function usePendingSkillAttempts(enabled = true) {
  return useQuery({
    queryKey: ['pending-skill-attempts'],
    enabled,
    queryFn: async (): Promise<PendingAttemptView[]> => {
      const { data, error } = await supabase
        .from('skill_attempts')
        .select(
          'id, progression_id, attempt_date, actual_hold_seconds, actual_reps, video_url, status, reviewed_at, review_feedback, athlete_id, ' +
            'athlete:profiles!skill_attempts_athlete_id_fkey(full_name), progression:skill_progressions(name, skill:skills(name))',
        )
        .eq('status', 'pending_review')
        .order('created_at', { ascending: true });
      if (error) throw error;
      return ((data ?? []) as unknown as RawPendingAttempt[]).map((r) => ({
        id: r.id,
        progressionId: r.progression_id,
        attemptDate: r.attempt_date,
        actualHoldSeconds: r.actual_hold_seconds,
        actualReps: r.actual_reps,
        videoUrl: r.video_url,
        status: r.status as AttemptStatus,
        reviewedAt: r.reviewed_at,
        reviewFeedback: r.review_feedback,
        athleteId: r.athlete_id,
        athleteName: r.athlete?.full_name?.trim() || 'Unnamed member',
        skillName: r.progression?.skill?.name ?? 'Skill',
        progressionName: r.progression?.name ?? 'Rung',
      }));
    },
  });
}

export interface VerifiedAchievementView {
  id: string;
  athleteId: string;
  athleteName: string;
  skillName: string;
  progressionName: string;
  verifiedAt: string;
}

interface RawVerifiedAchievement {
  id: string;
  athlete_id: string;
  verified_at: string;
  athlete: { full_name: string } | null;
  progression: { name: string; skill: { name: string } | null } | null;
}

/**
 * The caller's own recent verifications (`verified_by = auth.uid()`), active
 * only — the pool the Revoke action in the verification queue works from.
 */
export function useMyVerifiedAchievements(callerId: string | undefined) {
  return useQuery({
    queryKey: ['my-verified-achievements', callerId],
    enabled: !!callerId,
    queryFn: async (): Promise<VerifiedAchievementView[]> => {
      const { data, error } = await supabase
        .from('skill_achievements')
        .select(
          'id, athlete_id, verified_at, athlete:profiles!skill_achievements_athlete_id_fkey(full_name), ' +
            'progression:skill_progressions(name, skill:skills(name))',
        )
        .eq('verified_by', callerId!)
        .eq('status', 'active')
        .order('verified_at', { ascending: false })
        .limit(20);
      if (error) throw error;
      return ((data ?? []) as unknown as RawVerifiedAchievement[]).map((r) => ({
        id: r.id,
        athleteId: r.athlete_id,
        athleteName: r.athlete?.full_name?.trim() || 'Unnamed member',
        skillName: r.progression?.skill?.name ?? 'Skill',
        progressionName: r.progression?.name ?? 'Rung',
        verifiedAt: r.verified_at,
      }));
    },
  });
}

// -- Mutations (thin RPC wrappers; the caller supplies its own idempotency key) --------------------

export async function setAthleteSkillStatus(args: { athleteId: string; skillId: string; progressionId: string; idempotencyKey: string }) {
  return supabase.rpc('set_athlete_skill_status', {
    p_athlete_id: args.athleteId,
    p_skill_id: args.skillId,
    p_progression_id: args.progressionId,
    p_idempotency_key: args.idempotencyKey,
  } as unknown as SetSkillStatusArgs);
}

export async function logSkillAttempt(args: {
  progressionId: string;
  attemptDate: string | null;
  actualHoldSeconds: number | null;
  actualReps: number | null;
  videoUrl: string | null;
  idempotencyKey: string;
}) {
  const rpcArgs: LogSkillAttemptArgs = {
    p_progression_id: args.progressionId,
    p_attempt_date: args.attemptDate,
    p_actual_hold_seconds: args.actualHoldSeconds,
    p_actual_reps: args.actualReps,
    p_video_url: args.videoUrl,
    p_idempotency_key: args.idempotencyKey,
  } as unknown as LogSkillAttemptArgs;
  return supabase.rpc('log_skill_attempt', rpcArgs);
}

export async function reviewSkillAttempt(args: { attemptId: string; approved: boolean; feedback: string | null; idempotencyKey: string }) {
  const rpcArgs: ReviewSkillAttemptArgs = {
    p_attempt_id: args.attemptId,
    p_approved: args.approved,
    p_feedback: args.feedback,
    p_idempotency_key: args.idempotencyKey,
  } as unknown as ReviewSkillAttemptArgs;
  return supabase.rpc('review_skill_attempt', rpcArgs);
}

export async function verifySkillAchievement(args: {
  athleteId: string;
  progressionId: string;
  idempotencyKey: string;
  skillAttemptId?: string | null;
}) {
  const rpcArgs: VerifySkillAchievementArgs = {
    p_athlete_id: args.athleteId,
    p_progression_id: args.progressionId,
    p_idempotency_key: args.idempotencyKey,
    p_skill_attempt_id: args.skillAttemptId ?? null,
  } as unknown as VerifySkillAchievementArgs;
  return supabase.rpc('verify_skill_achievement', rpcArgs);
}

export async function revokeSkillAchievement(args: { achievementId: string; reason: string; idempotencyKey: string }) {
  const rpcArgs: RevokeSkillAchievementArgs = {
    p_achievement_id: args.achievementId,
    p_reason: args.reason,
    p_idempotency_key: args.idempotencyKey,
  } as unknown as RevokeSkillAchievementArgs;
  return supabase.rpc('revoke_skill_achievement', rpcArgs);
}

export async function updateSkillProgression(args: {
  progressionId: string;
  name: string;
  description: string | null;
  targetHoldSeconds: number | null;
  targetReps: number | null;
  idempotencyKey: string;
}) {
  const rpcArgs: UpdateSkillProgressionArgs = {
    p_progression_id: args.progressionId,
    p_name: args.name,
    p_description: args.description,
    p_target_hold_seconds: args.targetHoldSeconds,
    p_target_reps: args.targetReps,
    p_idempotency_key: args.idempotencyKey,
  } as unknown as UpdateSkillProgressionArgs;
  return supabase.rpc('update_skill_progression', rpcArgs);
}
