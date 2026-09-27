import type { Json } from '@/types/database';

/**
 * Sprint 3 · Task 3.13. Client-side mirror of the `workout_item_sets` /
 * `workout_blocks` constraints and of `app_private.validate_workout_set` /
 * `build_workout_version`, so the builder gives field-level errors before a
 * round trip. The database stays authoritative: every rule here is re-checked
 * server-side inside `create_workout_template` / `publish_new_workout_version`.
 */
export const BLOCK_TYPES = ['standard_set', 'superset', 'circuit', 'amrap'] as const;
export type BlockType = (typeof BLOCK_TYPES)[number];

export const MEASUREMENT_MODES = [
  'reps',
  'duration',
  'holds',
  'distance',
  'until_failure',
  'added_weight',
  'assisted_weight',
  'technique_practice',
] as const;
export type MeasurementMode = (typeof MEASUREMENT_MODES)[number];

export const LOAD_TYPES = ['bodyweight', 'added', 'assisted'] as const;
export type LoadType = (typeof LOAD_TYPES)[number];

const LABELS: Record<string, string> = {
  standard_set: 'Standard set',
  superset: 'Superset',
  circuit: 'Circuit',
  amrap: 'AMRAP',
  reps: 'Reps',
  duration: 'Duration',
  holds: 'Hold',
  distance: 'Distance',
  until_failure: 'Until failure',
  added_weight: 'Added weight',
  assisted_weight: 'Assisted',
  technique_practice: 'Technique practice',
  bodyweight: 'Bodyweight',
  added: 'Added',
  assisted: 'Assisted',
};
export const labelFor = (value: string) => LABELS[value] ?? value.charAt(0).toUpperCase() + value.slice(1);

/** Measurement modes that an exercise's `measurement_types` (which also includes `'amrap'`) can offer as an item mode. */
export const itemModesFor = (measurementTypes: string[]): MeasurementMode[] =>
  MEASUREMENT_MODES.filter((m) => measurementTypes.includes(m));

export interface SetDraft {
  targetReps: string;
  targetDurationSeconds: string;
  targetDistanceMeters: string;
  targetLoadKg: string;
  loadType: LoadType | null;
  targetRestSeconds: string;
  targetRpe: string;
  notes: string;
}

export interface ItemDraft {
  exerciseId: string;
  exerciseName: string;
  /** The chosen exercise's `measurement_types`, so the picker can offer only its supported item modes. */
  exerciseMeasurementTypes: string[];
  measurementMode: MeasurementMode | null;
  notes: string;
  sets: SetDraft[];
}

export interface BlockDraft {
  title: string;
  blockType: BlockType;
  circuitRounds: string;
  amrapDurationSeconds: string;
  notes: string;
  items: ItemDraft[];
}

export const emptySet = (): SetDraft => ({
  targetReps: '',
  targetDurationSeconds: '',
  targetDistanceMeters: '',
  targetLoadKg: '',
  loadType: null,
  targetRestSeconds: '',
  targetRpe: '',
  notes: '',
});

export const emptyItem = (): ItemDraft => ({
  exerciseId: '',
  exerciseName: '',
  exerciseMeasurementTypes: [],
  measurementMode: null,
  notes: '',
  sets: [emptySet()],
});

export const emptyBlock = (): BlockDraft => ({
  title: '',
  blockType: 'standard_set',
  circuitRounds: '',
  amrapDurationSeconds: '',
  notes: '',
  items: [emptyItem()],
});

/** Appends a descending pyramid (e.g. 3 sets, reps stepping down) to an item. */
export function addPyramidSets(item: ItemDraft, steps: number, startReps: number): ItemDraft {
  const added: SetDraft[] = Array.from({ length: Math.max(1, steps) }, (_, i) => ({
    ...emptySet(),
    targetReps: String(Math.max(1, startReps - i)),
  }));
  return { ...item, sets: [...item.sets, ...added] };
}

/** Appends one back-off set: same mode, a lighter/easier target than the last set. */
export function addBackOffSet(item: ItemDraft): ItemDraft {
  const last = item.sets[item.sets.length - 1] ?? emptySet();
  const backOff: SetDraft = {
    ...emptySet(),
    targetReps: last.targetReps ? String(Math.max(1, Math.round(Number(last.targetReps) * 1.5))) : '',
    targetDurationSeconds: last.targetDurationSeconds,
    loadType: last.loadType,
    targetLoadKg: last.targetLoadKg ? String(Math.max(0, Math.round(Number(last.targetLoadKg) * 0.7))) : '',
    targetRestSeconds: last.targetRestSeconds,
    notes: 'back-off set',
  };
  return { ...item, sets: [...item.sets, backOff] };
}

export interface DraftErrors {
  name?: string;
  blocks?: Record<number, { title?: string; structure?: string; items?: Record<number, { exercise?: string; mode?: string; sets?: Record<number, string> }> }>;
}

const toNumber = (s: string) => (s.trim() === '' ? null : Number(s));

/** Mirrors app_private.validate_workout_set: mode-aware field requirements. */
export function validateSet(mode: MeasurementMode, s: SetDraft): string | null {
  const reps = toNumber(s.targetReps);
  const duration = toNumber(s.targetDurationSeconds);
  const distance = toNumber(s.targetDistanceMeters);
  const load = toNumber(s.targetLoadKg);

  if (reps !== null && (reps < 1 || reps > 1000)) return 'Reps must be between 1 and 1000.';
  if (duration !== null && (duration < 1 || duration > 7200)) return 'Duration must be between 1 and 7200 seconds.';
  if (distance !== null && (distance <= 0 || distance > 100000)) return 'Distance must be greater than 0 and at most 100000 m.';
  if (load !== null && (load < 0 || load > 500)) return 'Load must be between 0 and 500 kg.';
  const rest = toNumber(s.targetRestSeconds);
  if (rest !== null && (rest < 0 || rest > 1800)) return 'Rest must be between 0 and 1800 seconds.';
  const rpe = toNumber(s.targetRpe);
  if (rpe !== null && (rpe < 1 || rpe > 10)) return 'RPE must be between 1 and 10.';

  switch (mode) {
    case 'reps':
      if (reps === null) return 'Enter a rep target.';
      if (duration !== null || distance !== null || load !== null) return 'A reps set takes only a rep target.';
      return null;
    case 'duration':
    case 'holds':
      if (duration === null) return 'Enter a duration target.';
      if (reps !== null || distance !== null || load !== null) return 'This set takes only a duration target.';
      return null;
    case 'distance':
      if (distance === null) return 'Enter a distance target.';
      if (reps !== null || load !== null) return 'A distance set takes no reps or load.';
      return null;
    case 'added_weight':
      if (load === null || load <= 0 || s.loadType !== 'added') return 'Enter a load greater than 0 and set load type to added.';
      if (reps === null && duration === null) return 'Enter reps or a duration alongside the load.';
      if (distance !== null) return 'An added-weight set takes no distance.';
      return null;
    case 'assisted_weight':
      if (load === null || load <= 0 || s.loadType !== 'assisted') return 'Enter a load greater than 0 and set load type to assisted.';
      if (reps === null && duration === null) return 'Enter reps or a duration alongside the assistance.';
      if (distance !== null) return 'An assisted set takes no distance.';
      return null;
    case 'until_failure':
      if (distance !== null) return 'An until-failure set takes no distance.';
      return null;
    case 'technique_practice':
      if (distance !== null || load !== null) return 'A technique set takes no distance or load.';
      if (reps === null && duration === null && !s.notes.trim()) return 'Add reps, a duration, or a note describing the drill.';
      return null;
    default:
      return 'Unknown measurement mode.';
  }
}

export function validateDraft(name: string, blocks: BlockDraft[]): DraftErrors {
  const errors: DraftErrors = {};
  const trimmedName = name.trim();
  if (!trimmedName) errors.name = 'Give the routine a name.';
  else if (trimmedName.length > 100) errors.name = 'Keep the name under 100 characters.';

  if (blocks.length < 1 || blocks.length > 20) {
    errors.blocks = { 0: { structure: 'A routine needs between 1 and 20 blocks.' } };
    return errors;
  }

  const blockErrors: DraftErrors['blocks'] = {};
  blocks.forEach((b, bi) => {
    const be: { title?: string; structure?: string; items?: Record<number, { exercise?: string; mode?: string; sets?: Record<number, string> }> } = {};
    if (!b.title.trim()) be.title = 'Give the block a title.';
    if (b.blockType === 'amrap' && (toNumber(b.amrapDurationSeconds) ?? 0) < 30) {
      be.structure = 'An AMRAP block needs a duration of at least 30 seconds.';
    }
    if (b.blockType === 'circuit' && (toNumber(b.circuitRounds) ?? 0) < 1) {
      be.structure = 'A circuit block needs at least 1 round.';
    }
    if (b.items.length < 1 || b.items.length > 30) {
      be.structure = 'A block needs between 1 and 30 exercises.';
    }

    const itemErrors: Record<number, { exercise?: string; mode?: string; sets?: Record<number, string> }> = {};
    b.items.forEach((it, ii) => {
      const ie: { exercise?: string; mode?: string; sets?: Record<number, string> } = {};
      if (!it.exerciseId) ie.exercise = 'Choose an exercise.';
      if (!it.measurementMode) ie.mode = 'Choose a measurement mode.';
      if (it.sets.length < 1 || it.sets.length > 50) ie.mode = 'A movement needs between 1 and 50 sets.';
      if (it.measurementMode) {
        const setErrors: Record<number, string> = {};
        it.sets.forEach((s, si) => {
          const err = validateSet(it.measurementMode!, s);
          if (err) setErrors[si] = err;
        });
        if (Object.keys(setErrors).length) ie.sets = setErrors;
      }
      if (Object.keys(ie).length) itemErrors[ii] = ie;
    });
    if (Object.keys(itemErrors).length) be.items = itemErrors;

    if (Object.keys(be).length) blockErrors[bi] = be;
  });
  if (Object.keys(blockErrors).length) errors.blocks = blockErrors;

  return errors;
}

export const isDraftValid = (errors: DraftErrors) => !errors.name && !errors.blocks;

/** Builds the `p_blocks` jsonb payload the RPCs expect. Array order becomes order_in_workout / order_in_block / set_number. */
export function buildBlocksPayload(blocks: BlockDraft[]): Json {
  return blocks.map((b) => ({
    title: b.title.trim(),
    block_type: b.blockType,
    circuit_rounds: b.blockType === 'circuit' ? toNumber(b.circuitRounds) : null,
    amrap_duration_seconds: b.blockType === 'amrap' ? toNumber(b.amrapDurationSeconds) : null,
    notes: b.notes.trim() || null,
    items: b.items.map((it) => ({
      exercise_id: it.exerciseId,
      measurement_mode: it.measurementMode,
      notes: it.notes.trim() || null,
      sets: it.sets.map((s) => ({
        target_reps: toNumber(s.targetReps),
        target_duration_seconds: toNumber(s.targetDurationSeconds),
        target_distance_meters: toNumber(s.targetDistanceMeters),
        target_load_kg: toNumber(s.targetLoadKg),
        load_type: s.loadType,
        target_rest_seconds: toNumber(s.targetRestSeconds),
        target_rpe: toNumber(s.targetRpe),
        notes: s.notes.trim() || null,
      })),
    })),
  })) as unknown as Json;
}

/** One-line prescribed-target summary for a set, used by the catalog/detail screens. */
export function summarizeSet(mode: string, s: {
  target_reps: number | null;
  target_duration_seconds: number | null;
  target_distance_meters: number | null;
  target_load_kg: number | null;
  load_type: string | null;
}): string {
  const parts: string[] = [];
  if (s.target_reps !== null) parts.push(`${s.target_reps} reps`);
  if (s.target_duration_seconds !== null) parts.push(`${s.target_duration_seconds}s`);
  if (s.target_distance_meters !== null) parts.push(`${s.target_distance_meters}m`);
  if (s.target_load_kg !== null) parts.push(`${s.load_type === 'assisted' ? '−' : '+'}${s.target_load_kg}kg`);
  return parts.length ? parts.join(' · ') : labelFor(mode);
}
