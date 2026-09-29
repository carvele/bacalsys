import type { AttemptMode } from '@/features/skills/attempt-form';

/**
 * Sprint 6 · Task 6.13 — the Edit Criteria modal's pure form logic
 * (Feature 8.1, F-S6-P07). A rung keeps whichever metric it was seeded with
 * (hold or reps); the editor changes the name, description and that one
 * numeric target, never adds the other kind.
 */

export interface ProgressionDraft {
  name: string;
  description: string;
  target: string;
}

export const progressionDraftFrom = (rung: { name: string; description: string | null; targetHoldSeconds: number | null; targetReps: number | null }): ProgressionDraft => ({
  name: rung.name,
  description: rung.description ?? '',
  target: String(rung.targetHoldSeconds ?? rung.targetReps ?? ''),
});

export interface ProgressionDraftErrors {
  name?: string;
  description?: string;
  target?: string;
}

export function validateProgressionDraft(mode: AttemptMode, draft: ProgressionDraft): ProgressionDraftErrors {
  const errors: ProgressionDraftErrors = {};
  if (draft.name.trim().length === 0) errors.name = 'Name is required.';
  else if (draft.name.trim().length > 120) errors.name = 'Keep the name under 120 characters.';

  if (draft.description.trim().length > 2000) errors.description = 'Keep the description under 2000 characters.';

  const n = Number(draft.target.trim());
  if (draft.target.trim() === '' || !Number.isFinite(n) || !Number.isInteger(n) || n < 1) {
    errors.target = mode === 'hold' ? 'Enter a hold time of at least 1 second.' : 'Enter at least 1 repetition.';
  }
  return errors;
}

export const isProgressionDraftValid = (errors: ProgressionDraftErrors) => Object.keys(errors).length === 0;

export function buildUpdateProgressionArgs(mode: AttemptMode, draft: ProgressionDraft, progressionId: string) {
  const n = Math.trunc(Number(draft.target.trim()));
  const description = draft.description.trim();
  return {
    progressionId,
    name: draft.name.trim(),
    description: description === '' ? null : description,
    targetHoldSeconds: mode === 'hold' ? n : null,
    targetReps: mode === 'reps' ? n : null,
  };
}
