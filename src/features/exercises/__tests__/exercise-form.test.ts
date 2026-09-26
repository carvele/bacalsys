import {
  draftToInsert,
  emptyDraft,
  filterExercises,
  slugify,
  toggleEquipment,
  validateExerciseDraft,
  type ExerciseDraft,
} from '../exercise-form';

const valid: ExerciseDraft = {
  name: 'Weighted Ring Dips',
  category: 'push',
  description: '',
  measurementTypes: ['reps'],
  equipment: ['rings', 'weight_vest'],
};

describe('validateExerciseDraft', () => {
  it('accepts a complete draft', () => {
    expect(validateExerciseDraft(valid)).toEqual({});
  });

  it('flags every missing required field on an empty draft', () => {
    const errors = validateExerciseDraft({ ...emptyDraft(), equipment: [] });
    expect(Object.keys(errors).sort()).toEqual(['category', 'equipment', 'measurementTypes', 'name']);
  });

  it('mirrors the database constraints', () => {
    expect(validateExerciseDraft({ ...valid, name: '   ' }).name).toBeDefined();
    expect(validateExerciseDraft({ ...valid, name: 'x'.repeat(121) }).name).toBeDefined();
    expect(validateExerciseDraft({ ...valid, name: '!!!' }).name).toBeDefined(); // would produce an empty slug
    expect(validateExerciseDraft({ ...valid, description: 'x'.repeat(2001) }).description).toBeDefined();
    expect(validateExerciseDraft({ ...valid, equipment: ['none', 'bar'] }).equipment).toBeDefined();
  });
});

describe('slugify', () => {
  it('matches app_private.exercise_default_slug()', () => {
    expect(slugify('Weighted Ring Dips')).toBe('weighted-ring-dips');
    expect(slugify('  L-sit (tuck) 2 ')).toBe('l-sit-tuck-2');
    expect(slugify('Pull-up!!')).toBe('pull-up');
  });
});

describe('toggleEquipment', () => {
  it('keeps bodyweight exclusive', () => {
    expect(toggleEquipment(['none'], 'rings')).toEqual(['rings']);
    expect(toggleEquipment(['rings', 'bar'], 'none')).toEqual(['none']);
    expect(toggleEquipment(['none'], 'none')).toEqual([]);
    expect(toggleEquipment(['rings'], 'rings')).toEqual([]);
  });
});

describe('draftToInsert', () => {
  it('sends only creator-writable content columns, never workflow columns', () => {
    const row = draftToInsert({ ...valid, name: '  Weighted Ring Dips ', description: '  ' }, 'user-1');
    expect(row).toEqual({
      name: 'Weighted Ring Dips',
      slug: 'weighted-ring-dips',
      category: 'push',
      description: null,
      measurement_types: ['reps'],
      equipment_needed: ['rings', 'weight_vest'],
      created_by: 'user-1',
    });
    expect(Object.keys(row)).not.toEqual(expect.arrayContaining(['status', 'is_official', 'reviewed_by']));
  });
});

describe('filterExercises', () => {
  const rows = [
    { name: 'Pull-up', category: 'pull' },
    { name: 'Push-up', category: 'push' },
    { name: 'Ring Row', category: 'pull' },
  ];
  it('filters by name and category', () => {
    expect(filterExercises(rows, 'up', null).map((r) => r.name)).toEqual(['Pull-up', 'Push-up']);
    expect(filterExercises(rows, '', 'pull').map((r) => r.name)).toEqual(['Pull-up', 'Ring Row']);
    expect(filterExercises(rows, 'ROW', 'pull').map((r) => r.name)).toEqual(['Ring Row']);
  });
});
