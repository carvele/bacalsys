import type { Tables } from '@/types/database';

export type Exercise = Tables<'exercises'>;

/** Feature 3.1 vocabularies. Mirrors the CHECK constraints on public.exercises. */
export const CATEGORIES = ['push', 'pull', 'legs', 'core', 'skill', 'mobility'] as const;
export const MEASUREMENT_TYPES = [
  'reps',
  'duration',
  'holds',
  'distance',
  'amrap',
  'until_failure',
  'added_weight',
  'assisted_weight',
  'technique_practice',
] as const;
export const EQUIPMENT = ['none', 'bar', 'rings', 'parallettes', 'resistance_bands', 'weight_vest'] as const;

export type Category = (typeof CATEGORIES)[number];
export type MeasurementType = (typeof MEASUREMENT_TYPES)[number];
export type Equipment = (typeof EQUIPMENT)[number];

const LABELS: Record<string, string> = {
  none: 'Bodyweight',
  until_failure: 'Until failure',
  added_weight: 'Added weight',
  assisted_weight: 'Assisted',
  technique_practice: 'Technique',
  resistance_bands: 'Bands',
  weight_vest: 'Weight vest',
  amrap: 'AMRAP',
};
export const labelFor = (value: string) => LABELS[value] ?? value.charAt(0).toUpperCase() + value.slice(1);

export interface ExerciseDraft {
  name: string;
  category: Category | null;
  description: string;
  measurementTypes: MeasurementType[];
  equipment: Equipment[];
}

export const emptyDraft = (): ExerciseDraft => ({
  name: '',
  category: null,
  description: '',
  measurementTypes: [],
  equipment: ['none'],
});

export type DraftErrors = Partial<Record<'name' | 'category' | 'description' | 'measurementTypes' | 'equipment', string>>;

/** Client-side mirror of the table constraints, so members get field-level messages. The database stays authoritative. */
export function validateExerciseDraft(d: ExerciseDraft): DraftErrors {
  const errors: DraftErrors = {};
  const name = d.name.trim();
  if (!name) errors.name = 'Give the exercise a name.';
  else if (name.length > 120) errors.name = 'Keep the name under 120 characters.';
  else if (!slugify(name)) errors.name = 'Use at least one letter or number in the name.';
  if (!d.category) errors.category = 'Choose a category.';
  if (d.description.length > 2000) errors.description = 'Keep the description under 2000 characters.';
  if (d.measurementTypes.length === 0) errors.measurementTypes = 'Choose at least one way to measure it.';
  if (d.equipment.length === 0) errors.equipment = 'Choose the equipment (or Bodyweight).';
  else if (d.equipment.includes('none') && d.equipment.length > 1) errors.equipment = 'Bodyweight cannot be combined with equipment.';
  return errors;
}

/** Same derivation as app_private.exercise_default_slug(). */
export const slugify = (name: string) =>
  name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 140);

export function toggleValue<T>(list: T[], value: T): T[] {
  return list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
}

/** Bodyweight ('none') is exclusive: picking it clears equipment, picking equipment clears it. */
export function toggleEquipment(list: Equipment[], value: Equipment): Equipment[] {
  if (value === 'none') return list.includes('none') ? [] : ['none'];
  return toggleValue(
    list.filter((v) => v !== 'none'),
    value,
  );
}

export function draftToInsert(d: ExerciseDraft, userId: string) {
  const name = d.name.trim();
  return {
    name,
    slug: slugify(name),
    category: d.category as Category,
    description: d.description.trim() || null,
    measurement_types: d.measurementTypes,
    equipment_needed: d.equipment,
    created_by: userId,
  };
}

/** Catalog filter: case-insensitive name match plus optional category. */
export function filterExercises<T extends Pick<Exercise, 'name' | 'category'>>(
  rows: T[],
  query: string,
  category: Category | null,
): T[] {
  const q = query.trim().toLowerCase();
  return rows.filter((r) => (!category || r.category === category) && (!q || r.name.toLowerCase().includes(q)));
}

export const STATUS_LABEL: Record<string, string> = {
  private: 'Private draft',
  pending_approval: 'Pending review',
  approved: 'Official',
  rejected: 'Rejected',
};
