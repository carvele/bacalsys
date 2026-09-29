import {
  CALENDAR_STATUSES,
  CALENDAR_STATUS_COLOR,
  adherenceBarPercent,
  adherenceCaption,
  buildCalendarEntries,
  buildMonthGrid,
  daysInMonth,
  formatAdherence,
  formatDuration,
  groupByDay,
  monthEnd,
  monthLabel,
  monthStart,
  resolveDayStatus,
  sessionCalendarStatus,
  shiftMonth,
  volumeShares,
} from '../training-stats';

describe('calendar status precedence (Section 13, invariant 1)', () => {
  it('orders completed > partially_completed > in_progress > upcoming > abandoned > missed', () => {
    expect([...CALENDAR_STATUSES]).toEqual(['completed', 'partially_completed', 'in_progress', 'upcoming', 'abandoned', 'missed']);
  });
  it('a day with several statuses shows the highest-precedence one, whatever the input order', () => {
    expect(resolveDayStatus(['missed', 'abandoned', 'completed'])).toBe('completed');
    expect(resolveDayStatus(['missed', 'upcoming'])).toBe('upcoming');
    expect(resolveDayStatus(['abandoned', 'missed'])).toBe('abandoned');
    expect(resolveDayStatus(['in_progress', 'partially_completed'])).toBe('partially_completed');
    expect(resolveDayStatus(['missed'])).toBe('missed');
    expect(resolveDayStatus([])).toBeNull();
    expect(resolveDayStatus(['nonsense'])).toBeNull();
  });
  it('uses the frozen colours', () => {
    expect(CALENDAR_STATUS_COLOR.completed).toBe('#10B981');
    expect(CALENDAR_STATUS_COLOR.partially_completed).toBe('#F59E0B');
    expect(CALENDAR_STATUS_COLOR.upcoming).toBe('#3B82F6');
    expect(CALENDAR_STATUS_COLOR.in_progress).toBe('#3B82F6');
    expect(CALENDAR_STATUS_COLOR.abandoned).toBe('#6B7280');
    expect(CALENDAR_STATUS_COLOR.missed).toBe('#EF4444');
  });
  it('an abandoned session is "partially completed" only when it recorded sets (status stays explicit)', () => {
    expect(sessionCalendarStatus('abandoned', 0)).toBe('abandoned');
    expect(sessionCalendarStatus('abandoned', 3)).toBe('partially_completed');
    expect(sessionCalendarStatus('completed', 0)).toBe('completed');
    expect(sessionCalendarStatus('in_progress', 0)).toBe('in_progress');
    expect(sessionCalendarStatus('mystery', 5)).toBeNull();
  });
});

describe('buildCalendarEntries', () => {
  const tz = 'Asia/Manila';

  it('folds a linked session into its occurrence (one entry, replay reachable) and keeps spontaneous sessions', () => {
    const entries = buildCalendarEntries({
      timezone: tz,
      occurrences: [{ id: 'o1', scheduled_date: '2026-09-28', status: 'completed', title: 'Push day' }],
      sessions: [
        { id: 's1', started_at: '2026-09-28T02:00:00Z', status: 'completed', assignment_occurrence_id: 'o1', recordedSets: 6 },
        { id: 's2', started_at: '2026-09-27T02:00:00Z', status: 'completed', assignment_occurrence_id: null, recordedSets: 4 },
      ],
    });
    expect(entries.map((e) => [e.date, e.status, e.occurrenceId, e.sessionId])).toEqual([
      ['2026-09-27', 'completed', null, 's2'],
      ['2026-09-28', 'completed', 'o1', 's1'],
    ]);
    expect(entries[1].title).toBe('Push day');
  });

  it('a linked session whose occurrence is not loaded stands alone; an occurrence with no session has no replay', () => {
    const entries = buildCalendarEntries({
      timezone: tz,
      occurrences: [{ id: 'o2', scheduled_date: '2026-09-30', status: 'upcoming' }],
      sessions: [{ id: 's9', started_at: '2026-09-20T02:00:00Z', status: 'abandoned', assignment_occurrence_id: 'elsewhere', recordedSets: 0 }],
    });
    expect(entries.find((e) => e.key === 'o:o2')).toMatchObject({ sessionId: null, status: 'upcoming' });
    expect(entries.find((e) => e.key === 's:s9')).toMatchObject({ status: 'abandoned', date: '2026-09-20' });
  });

  it("dates a session on the ORGANIZATION's calendar, not the device's or UTC's", () => {
    // 2026-03-15 20:00Z is 2026-03-16 04:00 in Manila but 2026-03-15 13:00 in Los Angeles.
    const at = '2026-03-15T20:00:00Z';
    const s = { id: 's', started_at: at, status: 'completed', assignment_occurrence_id: null, recordedSets: 1 };
    expect(buildCalendarEntries({ timezone: 'Asia/Manila', occurrences: [], sessions: [s] })[0].date).toBe('2026-03-16');
    expect(buildCalendarEntries({ timezone: 'America/Los_Angeles', occurrences: [], sessions: [s] })[0].date).toBe('2026-03-15');
  });

  it('drops unknown statuses instead of inventing one', () => {
    const entries = buildCalendarEntries({
      timezone: tz,
      occurrences: [{ id: 'o', scheduled_date: '2026-09-28', status: 'bogus' }],
      sessions: [{ id: 's', started_at: '2026-09-28T02:00:00Z', status: 'bogus', assignment_occurrence_id: null, recordedSets: 0 }],
    });
    expect(entries).toEqual([]);
  });

  it('groups by day; the day dot resolves through the precedence', () => {
    const entries = buildCalendarEntries({
      timezone: tz,
      occurrences: [
        { id: 'a', scheduled_date: '2026-09-28', status: 'missed' },
        { id: 'b', scheduled_date: '2026-09-28', status: 'completed' },
      ],
      sessions: [],
    });
    const day = groupByDay(entries).get('2026-09-28')!;
    expect(day).toHaveLength(2);
    expect(resolveDayStatus(day.map((e) => e.status))).toBe('completed');
  });
});

describe('month arithmetic', () => {
  it('finds month boundaries, lengths and labels (incl. February of a leap year)', () => {
    expect(monthStart('2026-09-28')).toBe('2026-09-01');
    expect(monthEnd('2026-09-05')).toBe('2026-09-30');
    expect(daysInMonth('2028-02-10')).toBe(29);
    expect(daysInMonth('2026-02-10')).toBe(28);
    expect(monthLabel('2026-09-28')).toBe('September 2026');
  });
  it('shifts across year boundaries', () => {
    expect(shiftMonth('2026-12-01', 1)).toBe('2027-01-01');
    expect(shiftMonth('2026-01-15', -1)).toBe('2025-12-01');
    expect(shiftMonth('2026-09-01', 0)).toBe('2026-09-01');
  });
  it('builds a Monday-first grid padded to whole weeks', () => {
    // September 2026 starts on a Tuesday and has 30 days.
    const weeks = buildMonthGrid('2026-09-17');
    expect(weeks.every((w) => w.length === 7)).toBe(true);
    expect(weeks[0]).toEqual([null, '2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04', '2026-09-05', '2026-09-06']);
    expect(weeks[weeks.length - 1].filter(Boolean).slice(-1)[0]).toBe('2026-09-30');
    expect(weeks.flat().filter(Boolean)).toHaveLength(30);
  });
  it('a month starting on Monday has no leading blanks', () => {
    // June 2026 starts on a Monday.
    expect(buildMonthGrid('2026-06-01')[0][0]).toBe('2026-06-01');
  });
});

describe('adherence & volume presentation', () => {
  it('a null adherence rate is "no data" (an em dash and an empty bar), never 0 %', () => {
    expect(formatAdherence(null)).toBe('—');
    expect(adherenceBarPercent(null)).toBe(0);
    expect(formatAdherence(100)).toBe('100.0%');
    expect(formatAdherence(66.7)).toBe('66.7%');
    expect(formatAdherence(0)).toBe('0.0%');
    expect(adherenceBarPercent(250)).toBe(100);
  });
  it('words the caption from the counts', () => {
    expect(adherenceCaption({ scheduledWorkouts: 0, completedWorkouts: 0 })).toMatch(/No scheduled workouts/);
    expect(adherenceCaption({ scheduledWorkouts: 1, completedWorkouts: 1 })).toBe('1 of 1 scheduled workout completed.');
    expect(adherenceCaption({ scheduledWorkouts: 4, completedWorkouts: 2 })).toBe('2 of 4 scheduled workouts completed.');
  });
  it('formats durations', () => {
    expect(formatDuration(0)).toBe('0 s');
    expect(formatDuration(45)).toBe('45 s');
    expect(formatDuration(120)).toBe('2 min');
    expect(formatDuration(150)).toBe('2 min 30 s');
    expect(formatDuration(3900)).toBe('1 h 05 min');
  });
  it('computes each category’s share of completed sets, safely when there are none', () => {
    const shares = volumeShares([
      { category: 'push', sets: 3, reps: 30, durationSeconds: 0 },
      { category: 'core', sets: 1, reps: 0, durationSeconds: 30 },
    ]);
    expect(shares.map((s) => [s.label, s.share])).toEqual([
      ['Push', 0.75],
      ['Core', 0.25],
    ]);
    expect(volumeShares([{ category: 'legs', sets: 0, reps: 0, durationSeconds: 0 }])[0].share).toBe(0);
    expect(volumeShares([])).toEqual([]);
  });
});
