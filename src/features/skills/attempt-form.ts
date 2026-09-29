/**
 * Sprint 6 · Task 6.13 — the Log Skill Attempt modal's pure form logic
 * (Feature 8.2, F-S6-P09: objective metrics only — hold seconds, reps, an
 * optional video link; never a free-text note). UX only: `log_skill_attempt`
 * re-validates every rule server-side.
 */

export type AttemptMode = 'hold' | 'reps';

/** A rung asks for hold seconds or reps, whichever target it was seeded with. */
export function rungMode(rung: { targetHoldSeconds: number | null; targetReps: number | null }): AttemptMode {
  return rung.targetHoldSeconds !== null ? 'hold' : 'reps';
}

export interface AttemptDraft {
  metric: string;
  videoUrl: string;
}

export const emptyAttemptDraft = (): AttemptDraft => ({ metric: '', videoUrl: '' });

export interface AttemptDraftErrors {
  metric?: string;
  videoUrl?: string;
}

export function validateAttemptDraft(mode: AttemptMode, draft: AttemptDraft): AttemptDraftErrors {
  const errors: AttemptDraftErrors = {};
  const raw = draft.metric.trim();
  const n = Number(raw);
  if (raw === '' || !Number.isFinite(n) || !Number.isInteger(n) || n < 1) {
    errors.metric = mode === 'hold' ? 'Enter a hold time of at least 1 second.' : 'Enter at least 1 repetition.';
  } else if (mode === 'hold' && n > 7200) {
    errors.metric = 'That hold time looks too long.';
  } else if (mode === 'reps' && n > 1000) {
    errors.metric = 'That repetition count looks too high.';
  }

  const video = draft.videoUrl.trim();
  if (video !== '' && !/^https?:\/\//.test(video)) {
    errors.videoUrl = 'Video links must start with http:// or https://.';
  } else if (video.length > 2048) {
    errors.videoUrl = 'That link is too long.';
  }
  return errors;
}

export const isAttemptDraftValid = (errors: AttemptDraftErrors) => Object.keys(errors).length === 0;

export function buildLogAttemptArgs(mode: AttemptMode, draft: AttemptDraft, progressionId: string) {
  const n = Math.trunc(Number(draft.metric.trim()));
  const video = draft.videoUrl.trim();
  return {
    progressionId,
    attemptDate: null, // the server defaults to the organization's today
    actualHoldSeconds: mode === 'hold' ? n : null,
    actualReps: mode === 'reps' ? n : null,
    videoUrl: video === '' ? null : video,
  };
}
