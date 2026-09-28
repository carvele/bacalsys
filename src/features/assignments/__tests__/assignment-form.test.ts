import {
  buildCreateAssignmentArgs,
  emptyAssignDraft,
  filterAthletes,
  isAssignDraftValid,
  toggleAllVisible,
  toggleAthlete,
  validateAssignDraft,
  NOTES_MAX,
  type AssignDraft,
} from '../assignment-form';

const TODAY = '2026-09-28';
const base = (over: Partial<AssignDraft> = {}): AssignDraft => ({ ...emptyAssignDraft(TODAY, ['a1']), ...over });

describe('validateAssignDraft', () => {
  it('a default single-date draft with one athlete is valid', () => {
    expect(isAssignDraftValid(validateAssignDraft(base(), TODAY))).toBe(true);
  });
  it('needs at least one athlete', () => {
    expect(validateAssignDraft(base({ athleteIds: [] }), TODAY).athletes).toBeDefined();
  });
  it('single date: must be a real date, today or later', () => {
    expect(validateAssignDraft(base({ targetDate: 'tomorrow' }), TODAY).targetDate).toMatch(/YYYY-MM-DD/);
    expect(validateAssignDraft(base({ targetDate: '2026-09-27' }), TODAY).targetDate).toMatch(/today or a future/);
    expect(validateAssignDraft(base({ targetDate: TODAY }), TODAY).targetDate).toBeUndefined();
  });
  it('recurring: needs weekdays, a valid start, and an end that is not before the start', () => {
    const rec = (over: Partial<AssignDraft>) => base({ mode: 'recurring', days: [1, 3, 5], ...over });
    expect(isAssignDraftValid(validateAssignDraft(rec({}), TODAY))).toBe(true);
    expect(validateAssignDraft(rec({ days: [] }), TODAY).days).toBeDefined();
    expect(validateAssignDraft(rec({ days: [0, 9] }), TODAY).days).toBeDefined();
    expect(validateAssignDraft(rec({ startDate: 'x' }), TODAY).startDate).toBeDefined();
    expect(validateAssignDraft(rec({ endDate: '2026-09-27' }), TODAY).endDate).toMatch(/before the start/);
    expect(validateAssignDraft(rec({ endDate: 'soon' }), TODAY).endDate).toMatch(/YYYY-MM-DD/);
    expect(validateAssignDraft(rec({ endDate: '' }), TODAY).endDate).toBeUndefined(); // open-ended
  });
  it('a past start date is allowed for a recurring schedule (only the horizon is generated)', () => {
    expect(validateAssignDraft(base({ mode: 'recurring', days: [2], startDate: '2026-01-01' }), TODAY).startDate).toBeUndefined();
  });
  it('caps notes at 2000 characters', () => {
    expect(validateAssignDraft(base({ notes: 'x'.repeat(NOTES_MAX) }), TODAY).notes).toBeUndefined();
    expect(validateAssignDraft(base({ notes: 'x'.repeat(NOTES_MAX + 1) }), TODAY).notes).toBeDefined();
  });
});

describe('buildCreateAssignmentArgs', () => {
  const ctx = { templateId: 't1', timezone: 'Asia/Manila', idempotencyKey: 'key-1' };
  it('single date: sends the date, no rule, not recurring', () => {
    expect(buildCreateAssignmentArgs(base({ athleteIds: ['a1', 'a2', 'a1'], targetDate: '2026-10-01', notes: '  form first  ' }), ctx)).toEqual({
      p_workout_template_id: 't1',
      p_workout_version_id: null,
      p_target_athlete_ids: ['a1', 'a2'],
      p_target_date: '2026-10-01',
      p_is_recurring: false,
      p_recurrence_rule: null,
      p_notes: 'form first',
      p_idempotency_key: 'key-1',
    });
  });
  it('recurring: sends NO target date and a normalized rule carrying the organization timezone', () => {
    const args = buildCreateAssignmentArgs(base({ mode: 'recurring', days: [5, 1, 3, 3], startDate: '2026-09-28', endDate: '', versionId: 'v2' }), ctx);
    expect(args.p_target_date).toBeNull();
    expect(args.p_is_recurring).toBe(true);
    expect(args.p_workout_version_id).toBe('v2');
    expect(args.p_recurrence_rule).toEqual({ days_of_week: [1, 3, 5], start_date: '2026-09-28', end_date: null, timezone: 'Asia/Manila' });
    expect(args.p_notes).toBeNull(); // blank notes are omitted
  });
});

describe('athlete selection', () => {
  const options = [
    { id: 'a1', name: 'Ana Reyes' },
    { id: 'a2', name: 'Ben Cruz' },
    { id: 'a3', name: 'Ana Lim' },
  ];
  it('filters by case-insensitive substring', () => {
    expect(filterAthletes(options, 'ANA').map((o) => o.id)).toEqual(['a1', 'a3']);
    expect(filterAthletes(options, '  ')).toHaveLength(3);
    expect(filterAthletes(options, 'zzz')).toEqual([]);
  });
  it('toggles single athletes', () => {
    expect(toggleAthlete([], 'a1')).toEqual(['a1']);
    expect(toggleAthlete(['a1', 'a2'], 'a1')).toEqual(['a2']);
  });
  it('"Select all" acts on the VISIBLE athletes only and toggles off when all are selected', () => {
    const visible = filterAthletes(options, 'ana');
    expect(toggleAllVisible(['a2'], visible)).toEqual(['a2', 'a1', 'a3']);
    expect(toggleAllVisible(['a2', 'a1', 'a3'], visible)).toEqual(['a2']);
    expect(toggleAllVisible(['a2'], [])).toEqual(['a2']);
  });
});
