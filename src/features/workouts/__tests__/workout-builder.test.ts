import {
  addBackOffSet,
  addPyramidSets,
  buildBlocksPayload,
  emptyBlock,
  emptyItem,
  emptySet,
  isDraftValid,
  summarizeSet,
  validateDraft,
  validateSet,
  type BlockDraft,
} from '../workout-builder';

const setWith = (overrides: Partial<ReturnType<typeof emptySet>>) => ({ ...emptySet(), ...overrides });

describe('validateSet (mode-aware rules, Section 10)', () => {
  it('reps: requires target_reps and nothing else', () => {
    expect(validateSet('reps', setWith({ targetReps: '8' }))).toBeNull();
    expect(validateSet('reps', emptySet())).toMatch(/rep target/);
    expect(validateSet('reps', setWith({ targetReps: '8', targetDurationSeconds: '10' }))).toMatch(/only a rep target/);
  });

  it('duration/holds: requires target_duration_seconds only', () => {
    expect(validateSet('duration', setWith({ targetDurationSeconds: '30' }))).toBeNull();
    expect(validateSet('holds', setWith({ targetDurationSeconds: '20' }))).toBeNull();
    expect(validateSet('holds', emptySet())).toMatch(/duration target/);
    expect(validateSet('holds', setWith({ targetDurationSeconds: '20', targetReps: '5' }))).toMatch(/only a duration target/);
  });

  it('distance: requires target_distance_meters, forbids reps/load', () => {
    expect(validateSet('distance', setWith({ targetDistanceMeters: '400' }))).toBeNull();
    expect(validateSet('distance', emptySet())).toMatch(/distance target/);
    expect(validateSet('distance', setWith({ targetDistanceMeters: '400', targetReps: '5' }))).toMatch(/no reps or load/);
  });

  it('added_weight: requires a positive added load plus reps or duration', () => {
    expect(validateSet('added_weight', setWith({ targetReps: '5', targetLoadKg: '10', loadType: 'added' }))).toBeNull();
    expect(validateSet('added_weight', setWith({ targetReps: '5', targetLoadKg: '10', loadType: 'assisted' }))).toMatch(/load type to added/);
    expect(validateSet('added_weight', setWith({ targetLoadKg: '10', loadType: 'added' }))).toMatch(/reps or a duration/);
    expect(validateSet('added_weight', setWith({ targetReps: '5', targetLoadKg: '0', loadType: 'added' }))).toMatch(/load type to added/);
  });

  it('assisted_weight: requires a positive assisted load plus reps or duration', () => {
    expect(validateSet('assisted_weight', setWith({ targetReps: '6', targetLoadKg: '20', loadType: 'assisted' }))).toBeNull();
    expect(validateSet('assisted_weight', setWith({ targetReps: '6', targetLoadKg: '20', loadType: 'added' }))).toMatch(/load type to assisted/);
  });

  it('until_failure: everything optional except distance', () => {
    expect(validateSet('until_failure', emptySet())).toBeNull();
    expect(validateSet('until_failure', setWith({ targetDistanceMeters: '10' }))).toMatch(/no distance/);
  });

  it('technique_practice: needs reps, duration, or notes; never distance/load', () => {
    expect(validateSet('technique_practice', setWith({ notes: 'slow tempo pistols' }))).toBeNull();
    expect(validateSet('technique_practice', emptySet())).toMatch(/Add reps/);
    expect(validateSet('technique_practice', setWith({ targetLoadKg: '5', loadType: 'added' }))).toMatch(/no distance or load/);
  });

  it('range checks mirror the workout_item_sets CHECK constraints', () => {
    expect(validateSet('reps', setWith({ targetReps: '1001' }))).toMatch(/between 1 and 1000/);
    expect(validateSet('duration', setWith({ targetDurationSeconds: '7201' }))).toMatch(/7200 seconds/);
    expect(validateSet('reps', setWith({ targetReps: '5', targetRpe: '11' }))).toMatch(/between 1 and 10/);
    expect(validateSet('reps', setWith({ targetReps: '5', targetRestSeconds: '1801' }))).toMatch(/1800 seconds/);
  });
});

describe('validateDraft', () => {
  const validBlock = (): BlockDraft => ({
    ...emptyBlock(),
    title: 'Primary Strength',
    items: [{ ...emptyItem(), exerciseId: 'ex-1', measurementMode: 'reps', sets: [setWith({ targetReps: '8' })] }],
  });

  it('rejects a blank name', () => {
    expect(validateDraft('   ', [validBlock()]).name).toMatch(/name/);
  });

  it('accepts a well-formed single-block draft', () => {
    expect(isDraftValid(validateDraft('Pull Day', [validBlock()]))).toBe(true);
  });

  it('requires an AMRAP duration of at least 30 seconds', () => {
    const block: BlockDraft = { ...validBlock(), blockType: 'amrap', amrapDurationSeconds: '10' };
    const errors = validateDraft('AMRAP Day', [block]);
    expect(errors.blocks?.[0]?.structure).toMatch(/30 seconds/);
  });

  it('requires at least 1 circuit round', () => {
    const block: BlockDraft = { ...validBlock(), blockType: 'circuit', circuitRounds: '' };
    const errors = validateDraft('Circuit Day', [block]);
    expect(errors.blocks?.[0]?.structure).toMatch(/1 round/);
  });

  it('flags a missing exercise or measurement mode per item', () => {
    const block: BlockDraft = { ...validBlock(), items: [emptyItem()] };
    const errors = validateDraft('Day', [block]);
    expect(errors.blocks?.[0]?.items?.[0]?.exercise).toMatch(/exercise/);
    expect(errors.blocks?.[0]?.items?.[0]?.mode).toMatch(/mode/);
  });

  it('flags an invalid set within a valid item', () => {
    const block = validBlock();
    block.items[0].sets = [setWith({})];
    const errors = validateDraft('Day', [block]);
    expect(errors.blocks?.[0]?.items?.[0]?.sets?.[0]).toMatch(/rep target/);
  });

  it('rejects zero blocks', () => {
    expect(validateDraft('Day', []).blocks?.[0]?.structure).toMatch(/1 and 20 blocks/);
  });

  // F-S3-03 / F-S3-04 (reviewer gate rework): payload limits and compound-block
  // cardinality, mirroring app_private.build_workout_version exactly.
  const itemWithSets = (n: number) => ({
    ...emptyItem(),
    exerciseId: 'ex-1',
    measurementMode: 'reps' as const,
    sets: Array.from({ length: n }, () => setWith({ targetReps: '5' })),
  });

  it('rejects more than 15 items in a block (F-S3-03)', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', items: Array.from({ length: 16 }, () => itemWithSets(1)) };
    expect(validateDraft('Day', [block]).blocks?.[0]?.structure).toMatch(/1 and 15 exercises/);
  });

  it('accepts exactly 15 items in a block', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', items: Array.from({ length: 15 }, () => itemWithSets(1)) };
    expect(isDraftValid(validateDraft('Day', [block]))).toBe(true);
  });

  it('rejects more than 30 sets on one item (F-S3-03)', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', items: [itemWithSets(31)] };
    expect(validateDraft('Day', [block]).blocks?.[0]?.items?.[0]?.mode).toMatch(/1 and 30 sets/);
  });

  it('accepts exactly 30 sets on one item', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', items: [itemWithSets(30)] };
    expect(isDraftValid(validateDraft('Day', [block]))).toBe(true);
  });

  it('rejects more than 150 sets across the whole routine (F-S3-03)', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', items: [itemWithSets(30), itemWithSets(30), itemWithSets(30), itemWithSets(30), itemWithSets(30), itemWithSets(1)] };
    expect(validateDraft('Day', [block]).totalSets).toMatch(/150 sets/);
  });

  it('accepts exactly 150 sets across the whole routine', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', items: [itemWithSets(30), itemWithSets(30), itemWithSets(30), itemWithSets(30), itemWithSets(30)] };
    expect(isDraftValid(validateDraft('Day', [block]))).toBe(true);
  });

  it('rejects a 1-item superset (F-S3-04)', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', blockType: 'superset', items: [itemWithSets(1)] };
    expect(validateDraft('Day', [block]).blocks?.[0]?.structure).toMatch(/superset block needs at least 2 exercises/);
  });

  it('rejects a 1-item circuit (F-S3-04)', () => {
    const block: BlockDraft = { ...emptyBlock(), title: 'x', blockType: 'circuit', circuitRounds: '3', items: [itemWithSets(1)] };
    expect(validateDraft('Day', [block]).blocks?.[0]?.structure).toMatch(/circuit block needs at least 2 exercises/);
  });

  it('accepts a 2-item superset and a 2-item circuit', () => {
    const superset: BlockDraft = { ...emptyBlock(), title: 'x', blockType: 'superset', items: [itemWithSets(1), itemWithSets(1)] };
    const circuit: BlockDraft = { ...emptyBlock(), title: 'y', blockType: 'circuit', circuitRounds: '3', items: [itemWithSets(1), itemWithSets(1)] };
    expect(isDraftValid(validateDraft('Day', [superset]))).toBe(true);
    expect(isDraftValid(validateDraft('Day', [circuit]))).toBe(true);
  });

  it('a 1-item standard_set or amrap block is still fine (no compound-cardinality rule for them)', () => {
    const standard: BlockDraft = { ...emptyBlock(), title: 'x', blockType: 'standard_set', items: [itemWithSets(1)] };
    const amrap: BlockDraft = { ...emptyBlock(), title: 'y', blockType: 'amrap', amrapDurationSeconds: '60', items: [itemWithSets(1)] };
    expect(isDraftValid(validateDraft('Day', [standard]))).toBe(true);
    expect(isDraftValid(validateDraft('Day', [amrap]))).toBe(true);
  });
});

describe('addPyramidSets / addBackOffSet', () => {
  it('appends a descending pyramid', () => {
    const item = { ...emptyItem(), sets: [] };
    const withPyramid = addPyramidSets(item, 3, 8);
    expect(withPyramid.sets.map((s) => s.targetReps)).toEqual(['8', '7', '6']);
  });

  it('appends a back-off set derived from the last set', () => {
    const item = { ...emptyItem(), sets: [setWith({ targetReps: '5', targetLoadKg: '20', loadType: 'added', targetRestSeconds: '120' })] };
    const withBackOff = addBackOffSet(item);
    const backOff = withBackOff.sets[withBackOff.sets.length - 1];
    expect(backOff.notes).toBe('back-off set');
    expect(Number(backOff.targetLoadKg)).toBeLessThan(20);
    expect(Number(backOff.targetReps)).toBeGreaterThan(5);
  });
});

describe('buildBlocksPayload', () => {
  it('derives order from array position and maps drafts to the RPC payload shape', () => {
    const block: BlockDraft = {
      ...emptyBlock(),
      title: 'Primary',
      blockType: 'amrap',
      amrapDurationSeconds: '300',
      items: [
        {
          ...emptyItem(),
          exerciseId: 'ex-1',
          measurementMode: 'added_weight',
          sets: [setWith({ targetReps: '5', targetLoadKg: '10', loadType: 'added' })],
        },
      ],
    };
    const payload = buildBlocksPayload([block]) as any[];
    expect(payload).toEqual([
      {
        title: 'Primary',
        block_type: 'amrap',
        circuit_rounds: null,
        amrap_duration_seconds: 300,
        notes: null,
        items: [
          {
            exercise_id: 'ex-1',
            measurement_mode: 'added_weight',
            notes: null,
            sets: [
              {
                target_reps: 5,
                target_duration_seconds: null,
                target_distance_meters: null,
                target_load_kg: 10,
                load_type: 'added',
                target_rest_seconds: null,
                target_rpe: null,
                notes: null,
              },
            ],
          },
        ],
      },
    ]);
  });

  it('clears circuit_rounds/amrap_duration_seconds for other block types', () => {
    const block: BlockDraft = { ...emptyBlock(), blockType: 'standard_set', circuitRounds: '3', amrapDurationSeconds: '300' };
    const payload = buildBlocksPayload([block]) as any[];
    expect(payload[0].circuit_rounds).toBeNull();
    expect(payload[0].amrap_duration_seconds).toBeNull();
  });
});

describe('summarizeSet', () => {
  it('joins the present target fields', () => {
    expect(summarizeSet('added_weight', {
      target_reps: 5, target_duration_seconds: null, target_distance_meters: null, target_load_kg: 10, load_type: 'added',
    })).toBe('5 reps · +10kg');
    expect(summarizeSet('assisted_weight', {
      target_reps: 6, target_duration_seconds: null, target_distance_meters: null, target_load_kg: 20, load_type: 'assisted',
    })).toBe('6 reps · −20kg');
  });

  it('falls back to the mode label when no targets are present', () => {
    expect(summarizeSet('until_failure', {
      target_reps: null, target_duration_seconds: null, target_distance_meters: null, target_load_kg: null, load_type: null,
    })).toBe('Until failure');
  });
});
