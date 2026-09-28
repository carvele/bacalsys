import {
  DEFAULT_TIMEZONE,
  addDaysIso,
  daysOfWeekSummary,
  formatCalendarDate,
  horizonDates,
  isIsoDate,
  isoDateInZone,
  isoDayOfWeek,
  normalizeDays,
  relativeDay,
  relativeDayLabel,
  todayIso,
} from '../date-tz';

describe('isIsoDate', () => {
  it('accepts real calendar dates only', () => {
    expect(isIsoDate('2026-09-28')).toBe(true);
    expect(isIsoDate('2028-02-29')).toBe(true); // leap day
    expect(isIsoDate('2026-02-29')).toBe(false);
    expect(isIsoDate('2026-13-01')).toBe(false);
    expect(isIsoDate('2026-9-28')).toBe(false);
    expect(isIsoDate('28/09/2026')).toBe(false);
    expect(isIsoDate('')).toBe(false);
  });
});

describe('isoDateInZone (the organization-local calendar day)', () => {
  // One real instant, several different local calendar days.
  const instant = new Date('2026-09-28T20:00:00Z');
  it('resolves the SAME instant to different local dates', () => {
    expect(isoDateInZone(instant, 'UTC')).toBe('2026-09-28');
    expect(isoDateInZone(instant, 'Asia/Manila')).toBe('2026-09-29'); // UTC+8 -> 04:00 next day
    expect(isoDateInZone(instant, 'Pacific/Pago_Pago')).toBe('2026-09-28'); // UTC-11 -> 09:00 same day
    expect(isoDateInZone(instant, 'Pacific/Kiritimati')).toBe('2026-09-29'); // UTC+14
  });
  it('defaults to the club timezone and todayIso follows it', () => {
    expect(DEFAULT_TIMEZONE).toBe('Asia/Manila');
    expect(todayIso(undefined, instant)).toBe('2026-09-29');
    expect(todayIso('UTC', instant)).toBe('2026-09-28');
  });
  it('handles the day boundary at local midnight exactly', () => {
    expect(isoDateInZone(new Date('2026-09-28T15:59:59Z'), 'Asia/Manila')).toBe('2026-09-28');
    expect(isoDateInZone(new Date('2026-09-28T16:00:00Z'), 'Asia/Manila')).toBe('2026-09-29');
  });
  it('is DST-aware (New York spring-forward day 2026-03-08)', () => {
    expect(isoDateInZone(new Date('2026-03-08T04:59:59Z'), 'America/New_York')).toBe('2026-03-07');
    expect(isoDateInZone(new Date('2026-03-08T05:00:00Z'), 'America/New_York')).toBe('2026-03-08');
  });
});

describe('calendar arithmetic', () => {
  it('adds days across month, year and leap-day boundaries', () => {
    expect(addDaysIso('2026-09-28', 1)).toBe('2026-09-29');
    expect(addDaysIso('2026-09-30', 1)).toBe('2026-10-01');
    expect(addDaysIso('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDaysIso('2028-02-28', 1)).toBe('2028-02-29');
    expect(addDaysIso('2026-03-01', -1)).toBe('2026-02-28');
    expect(() => addDaysIso('nope', 1)).toThrow();
  });
  it('is not affected by a DST change (it never touches a clock time)', () => {
    expect(addDaysIso('2026-03-07', 1)).toBe('2026-03-08');
    expect(addDaysIso('2026-03-08', 1)).toBe('2026-03-09');
    expect(addDaysIso('2026-10-31', 2)).toBe('2026-11-02');
  });
  it('maps calendar dates to ISO weekdays (Monday = 1 ... Sunday = 7)', () => {
    expect(isoDayOfWeek('2026-09-28')).toBe(1); // Monday
    expect(isoDayOfWeek('2026-09-30')).toBe(3); // Wednesday
    expect(isoDayOfWeek('2026-10-02')).toBe(5); // Friday
    expect(isoDayOfWeek('2026-10-04')).toBe(7); // Sunday
  });
  it('builds the rolling horizon: exactly 14 consecutive days from today (F-S5-P14)', () => {
    const h = horizonDates('2026-09-28');
    expect(h).toHaveLength(14);
    expect(h[0]).toBe('2026-09-28');
    expect(h[13]).toBe('2026-10-11');
    expect(h).not.toContain('2026-10-12');
  });
});

describe('weekday helpers', () => {
  it('normalizes to the sorted distinct set and drops out-of-range values', () => {
    expect(normalizeDays([5, 1, 3, 3, 1])).toEqual([1, 3, 5]);
    expect(normalizeDays([0, 8, 2, 2.5, -1, 7])).toEqual([2, 7]);
    expect(normalizeDays([])).toEqual([]);
  });
  it('summarizes weekday sets', () => {
    expect(daysOfWeekSummary([5, 1, 3])).toBe('Mon · Wed · Fri');
    expect(daysOfWeekSummary([1, 2, 3, 4, 5, 6, 7])).toBe('Every day');
    expect(daysOfWeekSummary([1, 2, 3, 4, 5])).toBe('Weekdays');
    expect(daysOfWeekSummary([7, 6])).toBe('Weekends');
    expect(daysOfWeekSummary([2])).toBe('Tue');
  });
});

describe('relative day badges', () => {
  const today = '2026-09-28';
  it('classifies overdue / today / tomorrow / upcoming against the ORG today', () => {
    expect(relativeDay('2026-09-27', today)).toBe('overdue');
    expect(relativeDay('2026-09-28', today)).toBe('today');
    expect(relativeDay('2026-09-29', today)).toBe('tomorrow');
    expect(relativeDay('2026-10-05', today)).toBe('upcoming');
  });
  it('labels them for display', () => {
    expect(relativeDayLabel('2026-09-01', today)).toBe('Overdue');
    expect(relativeDayLabel('2026-09-28', today)).toBe('Today');
    expect(relativeDayLabel('2026-09-29', today)).toBe('Tomorrow');
    expect(relativeDayLabel('2026-10-05', today)).toBe('Mon, Oct 5');
  });
  it('formats a calendar date independent of the device timezone', () => {
    expect(formatCalendarDate('2026-09-28')).toBe('Mon, Sep 28');
    expect(formatCalendarDate('garbage')).toBe('garbage');
  });
});
