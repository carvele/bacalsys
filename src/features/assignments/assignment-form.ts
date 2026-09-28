import { isIsoDate, normalizeDays } from '@/lib/date-tz';
import type { Database } from '@/types/database';

/** The generated RPC argument type (it types every argument non-null; the RPC accepts null for the optional ones). */
export type CreateAssignmentRpcArgs = Database['public']['Functions']['create_workout_assignment']['Args'];

/**
 * Sprint 5 · Task 5.11 — the AssignWorkoutModal's pure logic. UX only:
 * public.create_workout_assignment() re-validates every rule (workout:assign,
 * per-athlete scope, sealed/viewable version, schedule shape, timezone match)
 * on the server; this module only keeps obviously-invalid submissions from
 * leaving the device and shapes the RPC arguments.
 */
export type AssignMode = 'single' | 'recurring';

export interface AssignDraft {
  athleteIds: string[];
  mode: AssignMode;
  /** Single-date assignments: the organization-local calendar day. */
  targetDate: string;
  /** Recurring assignments: ISO weekdays 1–7. */
  days: number[];
  startDate: string;
  /** Empty string = open-ended. */
  endDate: string;
  notes: string;
  /** null = the template's latest sealed version (the server default). */
  versionId: string | null;
}

export const NOTES_MAX = 2000;

export function emptyAssignDraft(today: string, athleteIds: string[] = []): AssignDraft {
  return { athleteIds, mode: 'single', targetDate: today, days: [], startDate: today, endDate: '', notes: '', versionId: null };
}

export type AssignErrors = Partial<Record<'athletes' | 'targetDate' | 'days' | 'startDate' | 'endDate' | 'notes', string>>;

export function validateAssignDraft(draft: AssignDraft, today: string): AssignErrors {
  const errors: AssignErrors = {};
  if (draft.athleteIds.length === 0) errors.athletes = 'Pick at least one athlete.';
  if (draft.notes.length > NOTES_MAX) errors.notes = `Notes can be at most ${NOTES_MAX} characters.`;

  if (draft.mode === 'single') {
    if (!isIsoDate(draft.targetDate)) errors.targetDate = 'Enter the date as YYYY-MM-DD.';
    else if (draft.targetDate < today) errors.targetDate = 'Pick today or a future date.';
  } else {
    if (normalizeDays(draft.days).length === 0) errors.days = 'Pick at least one weekday.';
    if (!isIsoDate(draft.startDate)) errors.startDate = 'Enter the start date as YYYY-MM-DD.';
    if (draft.endDate.trim() !== '') {
      if (!isIsoDate(draft.endDate)) errors.endDate = 'Enter the end date as YYYY-MM-DD, or leave it empty.';
      else if (isIsoDate(draft.startDate) && draft.endDate < draft.startDate) errors.endDate = 'The end date cannot be before the start date.';
    }
  }
  return errors;
}

export const isAssignDraftValid = (errors: AssignErrors) => Object.keys(errors).length === 0;

/** The exact argument object for `supabase.rpc('create_workout_assignment', …)`. */
export function buildCreateAssignmentArgs(
  draft: AssignDraft,
  ctx: { templateId: string; timezone: string; idempotencyKey: string },
): CreateAssignmentRpcArgs {
  const recurring = draft.mode === 'recurring';
  return {
    p_workout_template_id: ctx.templateId,
    p_workout_version_id: draft.versionId,
    p_target_athlete_ids: Array.from(new Set(draft.athleteIds)),
    p_target_date: recurring ? null : draft.targetDate,
    p_is_recurring: recurring,
    p_recurrence_rule: recurring
      ? {
          days_of_week: normalizeDays(draft.days),
          start_date: draft.startDate,
          end_date: draft.endDate.trim() === '' ? null : draft.endDate,
          timezone: ctx.timezone,
        }
      : null,
    p_notes: draft.notes.trim() === '' ? null : draft.notes.trim(),
    p_idempotency_key: ctx.idempotencyKey,
  } as unknown as CreateAssignmentRpcArgs;
}

export interface AthleteOption {
  id: string;
  name: string;
}

/** Roster search (case-insensitive substring), mirroring searchRoster in coach-roster.ts. */
export function filterAthletes(options: AthleteOption[], query: string): AthleteOption[] {
  const q = query.trim().toLowerCase();
  return q ? options.filter((o) => o.name.toLowerCase().includes(q)) : options;
}

/** Toggle one athlete in the selection, preserving order. */
export const toggleAthlete = (selected: string[], id: string) =>
  selected.includes(id) ? selected.filter((s) => s !== id) : [...selected, id];

/** "Select all" acts on the visible (filtered) options only, and toggles off if they are all already selected. */
export function toggleAllVisible(selected: string[], visible: AthleteOption[]): string[] {
  const ids = visible.map((v) => v.id);
  const allSelected = ids.length > 0 && ids.every((id) => selected.includes(id));
  return allSelected ? selected.filter((s) => !ids.includes(s)) : Array.from(new Set([...selected, ...ids]));
}
