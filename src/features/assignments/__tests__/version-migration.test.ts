import {
  MIGRATION_CHOICES,
  MIGRATION_CHOICE_COPY,
  buildMigrateArgs,
  migratableOccurrences,
  toggleId,
  validateMigration,
} from '../version-migration';

describe('Rule C migration choices (F-S5-P10)', () => {
  it('offers exactly the three mutually exclusive choices, each with copy', () => {
    expect([...MIGRATION_CHOICES]).toEqual(['template_only', 'future_assignments_only', 'selected_upcoming_assignments']);
    for (const c of MIGRATION_CHOICES) expect(MIGRATION_CHOICE_COPY[c].title.length).toBeGreaterThan(0);
  });
  it('only UPCOMING occurrences are ever migratable', () => {
    const rows = [
      { id: 'o1', status: 'upcoming' },
      { id: 'o2', status: 'in_progress' },
      { id: 'o3', status: 'completed' },
      { id: 'o4', status: 'missed' },
      { id: 'o5', status: 'partially_completed' },
      { id: 'o6', status: 'abandoned' },
      { id: 'o7', status: 'upcoming' },
    ];
    expect(migratableOccurrences(rows).map((r) => r.id)).toEqual(['o1', 'o7']);
  });
  it('the selected choice needs at least one tick; the others need none', () => {
    expect(validateMigration('selected_upcoming_assignments', []).selection).toBeDefined();
    expect(validateMigration('selected_upcoming_assignments', ['o1'])).toEqual({});
    expect(validateMigration('template_only', [])).toEqual({});
    expect(validateMigration('future_assignments_only', [])).toEqual({});
  });
  it('sends occurrence ids ONLY with the selected choice (the server rejects them otherwise)', () => {
    const common = { assignmentId: 'asg', newVersionId: 'v2', idempotencyKey: 'k' };
    expect(buildMigrateArgs({ ...common, choice: 'template_only', selectedOccurrenceIds: ['o1'] }).p_selected_occurrence_ids).toBeNull();
    expect(buildMigrateArgs({ ...common, choice: 'future_assignments_only', selectedOccurrenceIds: ['o1'] }).p_selected_occurrence_ids).toBeNull();
    expect(buildMigrateArgs({ ...common, choice: 'selected_upcoming_assignments', selectedOccurrenceIds: ['o1', 'o2', 'o1'] })).toEqual({
      p_assignment_id: 'asg',
      p_new_version_id: 'v2',
      p_migration_choice: 'selected_upcoming_assignments',
      p_selected_occurrence_ids: ['o1', 'o2'],
      p_idempotency_key: 'k',
    });
  });
  it('toggles ids', () => {
    expect(toggleId(['a'], 'b')).toEqual(['a', 'b']);
    expect(toggleId(['a', 'b'], 'a')).toEqual(['b']);
  });
});
