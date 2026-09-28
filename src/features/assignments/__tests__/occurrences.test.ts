import {
  OCCURRENCE_STATUSES,
  canStartOccurrence,
  playerParams,
  showsCompletionMark,
  statusLabel,
  statusTone,
  summarizeByAthlete,
  todaysTraining,
} from '../occurrences';

const TODAY = '2026-09-28';
const row = (id: string, scheduled_date: string, status: string) => ({ id, scheduled_date, status, workout_version_id: `v-${id}` });

describe('status presentation', () => {
  it('has a label and tone for all six states, and passes unknown states through', () => {
    for (const s of OCCURRENCE_STATUSES) {
      expect(statusLabel(s)).not.toBe(s);
      expect(statusTone(s)).toBeDefined();
    }
    expect(statusLabel('weird')).toBe('weird');
    expect(statusTone('weird')).toBe('neutral');
  });
  it('the Start button shows for upcoming / in_progress only; completed & partially_completed show a mark', () => {
    expect(OCCURRENCE_STATUSES.filter(canStartOccurrence)).toEqual(['upcoming', 'in_progress']);
    expect(OCCURRENCE_STATUSES.filter(showsCompletionMark)).toEqual(['completed', 'partially_completed']);
  });
  it('the player deep link carries BOTH the pinned version and the occurrence id (Task 5.13)', () => {
    expect(playerParams({ id: 'occ-1', workoutVersionId: 'ver-9' })).toEqual({ versionId: 'ver-9', occurrenceId: 'occ-1' });
  });
});

describe('todaysTraining (organization-local day)', () => {
  it('keeps todays occurrences, plus an overdue one that is still in progress; drops the rest', () => {
    const rows = [
      row('tomorrow', '2026-09-29', 'upcoming'),
      row('today-done', TODAY, 'completed'),
      row('yesterday-missed', '2026-09-27', 'missed'),
      row('yesterday-inprogress', '2026-09-27', 'in_progress'),
      row('today-up', TODAY, 'upcoming'),
      row('last-week', '2026-09-21', 'upcoming'),
    ];
    expect(todaysTraining(rows, TODAY).map((r) => r.id)).toEqual(['today-done', 'today-up', 'yesterday-inprogress']);
  });
  it('is empty when nothing is scheduled', () => {
    expect(todaysTraining([], TODAY)).toEqual([]);
  });
});

describe('summarizeByAthlete (coach roster)', () => {
  it('counts UPCOMING occurrences per athlete and finds the next date', () => {
    const map = summarizeByAthlete([
      { athlete_id: 'a1', scheduled_date: '2026-10-03', status: 'upcoming' },
      { athlete_id: 'a1', scheduled_date: '2026-09-30', status: 'upcoming' },
      { athlete_id: 'a1', scheduled_date: '2026-09-25', status: 'completed' },
      { athlete_id: 'a2', scheduled_date: '2026-09-29', status: 'missed' },
      { athlete_id: 'a3', scheduled_date: '2026-10-01', status: 'upcoming' },
    ]);
    expect(map.get('a1')).toEqual({ athleteId: 'a1', upcomingCount: 2, nextDate: '2026-09-30' });
    expect(map.get('a3')).toEqual({ athleteId: 'a3', upcomingCount: 1, nextDate: '2026-10-01' });
    expect(map.has('a2')).toBe(false); // nothing upcoming
  });
});
