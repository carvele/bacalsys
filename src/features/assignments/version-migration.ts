/**
 * Sprint 5 · Task 5.12 — Rule C, the assignment-version migration choice.
 * Three mutually exclusive outcomes when a template gains a new sealed version
 * (F-S5-P10). UX only: public.migrate_assignment_version() enforces them.
 */
import type { Database } from '@/types/database';

export type MigrateRpcArgs = Database['public']['Functions']['migrate_assignment_version']['Args'];

export const MIGRATION_CHOICES = ['template_only', 'future_assignments_only', 'selected_upcoming_assignments'] as const;
export type MigrationChoice = (typeof MIGRATION_CHOICES)[number];

export const MIGRATION_CHOICE_COPY: Record<MigrationChoice, { title: string; detail: string }> = {
  template_only: {
    title: 'Template only',
    detail: 'Existing assignments and every scheduled occurrence stay on their current version.',
  },
  future_assignments_only: {
    title: 'Future assignments only',
    detail: 'Occurrences generated from now on use the new version. Already-scheduled ones stay as they are.',
  },
  selected_upcoming_assignments: {
    title: 'Selected upcoming workouts',
    detail: 'Move only the upcoming workouts you tick to the new version. The assignment default stays put.',
  },
};

export interface UpcomingOccurrence {
  id: string;
  scheduledDate: string;
  athleteName: string;
  status: string;
}

/** Only `upcoming` occurrences can ever be migrated; in-progress and finished ones are never offered. */
export const migratableOccurrences = <T extends { status: string }>(occurrences: T[]) => occurrences.filter((o) => o.status === 'upcoming');

export type MigrationErrors = Partial<Record<'selection', string>>;

export function validateMigration(choice: MigrationChoice, selectedOccurrenceIds: string[]): MigrationErrors {
  if (choice === 'selected_upcoming_assignments' && selectedOccurrenceIds.length === 0) {
    return { selection: 'Tick at least one upcoming workout to move.' };
  }
  return {};
}

/** The exact argument object for `supabase.rpc('migrate_assignment_version', …)`. */
export function buildMigrateArgs(args: {
  assignmentId: string;
  newVersionId: string;
  choice: MigrationChoice;
  selectedOccurrenceIds: string[];
  idempotencyKey: string;
}): MigrateRpcArgs {
  return {
    p_assignment_id: args.assignmentId,
    p_new_version_id: args.newVersionId,
    p_migration_choice: args.choice,
    // Only the selected-occurrences choice carries ids; the server rejects them for the other two.
    p_selected_occurrence_ids: args.choice === 'selected_upcoming_assignments' ? Array.from(new Set(args.selectedOccurrenceIds)) : null,
    p_idempotency_key: args.idempotencyKey,
  } as unknown as MigrateRpcArgs;
}

export const toggleId = (selected: string[], id: string) => (selected.includes(id) ? selected.filter((s) => s !== id) : [...selected, id]);
