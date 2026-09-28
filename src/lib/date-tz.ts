/**
 * Sprint 5 · Task 5.10 — organization-timezone date utilities.
 *
 * Scheduling is anchored to the ORGANIZATION's timezone (organizations.timezone,
 * default Asia/Manila), never the device's: an occurrence's `scheduled_date` is
 * an organization-local calendar day, "today" is the organization's today, and a
 * workout is overdue once that local day has ended. Everything here works on
 * plain `YYYY-MM-DD` strings (the shape Postgres `date` columns arrive in) so no
 * device-timezone arithmetic can leak in; the one place a real instant is
 * converted (`isoDateInZone`) goes through `Intl.DateTimeFormat` with an
 * explicit `timeZone`.
 */
export const DEFAULT_TIMEZONE = 'Asia/Manila';

/** ISO 8601 weekdays, exactly the 1–7 (Monday = 1) numbering the database stores. */
export const WEEKDAYS = [
  { iso: 1, short: 'Mon', long: 'Monday' },
  { iso: 2, short: 'Tue', long: 'Tuesday' },
  { iso: 3, short: 'Wed', long: 'Wednesday' },
  { iso: 4, short: 'Thu', long: 'Thursday' },
  { iso: 5, short: 'Fri', long: 'Friday' },
  { iso: 6, short: 'Sat', long: 'Saturday' },
  { iso: 7, short: 'Sun', long: 'Sunday' },
] as const;

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** True for a real calendar date written YYYY-MM-DD (rejects 2026-02-30, 2026-13-01 …). */
export function isIsoDate(value: string): boolean {
  const m = ISO_DATE.exec(value);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

/** The calendar date (YYYY-MM-DD) an instant falls on in the given IANA timezone. */
export function isoDateInZone(instant: Date, timeZone: string = DEFAULT_TIMEZONE): string {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(instant);
  const get = (type: string) => parts.find((p) => p.type === type)!.value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

/** The organization's calendar "today". */
export const todayIso = (timeZone: string = DEFAULT_TIMEZONE, now: Date = new Date()) => isoDateInZone(now, timeZone);

/** Calendar-day arithmetic on YYYY-MM-DD strings (DST-proof: it never touches a clock time). */
export function addDaysIso(iso: string, days: number): string {
  const m = ISO_DATE.exec(iso);
  if (!m) throw new Error(`Not an ISO date: ${iso}`);
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]) + days));
  return d.toISOString().slice(0, 10);
}

/** ISO weekday (Monday = 1 … Sunday = 7) of a calendar date. */
export function isoDayOfWeek(iso: string): number {
  const m = ISO_DATE.exec(iso);
  if (!m) throw new Error(`Not an ISO date: ${iso}`);
  const js = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))).getUTCDay(); // 0 = Sunday
  return js === 0 ? 7 : js;
}

/** The rolling scheduling horizon: `[today, today + 13]` — 14 calendar days, inclusive (F-S5-P14). */
export const HORIZON_DAYS = 14;
export const horizonDates = (today: string): string[] => Array.from({ length: HORIZON_DAYS }, (_, i) => addDaysIso(today, i));

/** Sorted, de-duplicated ISO weekdays — the same normalization the RPC applies server-side. */
export function normalizeDays(days: readonly number[]): number[] {
  return Array.from(new Set(days.filter((d) => Number.isInteger(d) && d >= 1 && d <= 7))).sort((a, b) => a - b);
}

/** "Mon · Wed · Fri", "Every day", "Weekdays" or "Weekends". */
export function daysOfWeekSummary(days: readonly number[]): string {
  const n = normalizeDays(days);
  const key = n.join('');
  if (key === '1234567') return 'Every day';
  if (key === '12345') return 'Weekdays';
  if (key === '67') return 'Weekends';
  return n.map((d) => WEEKDAYS[d - 1].short).join(' · ');
}

/** Human date for a calendar day, e.g. "Mon, Sep 29". Rendered from UTC noon so the device timezone can't shift the day. */
export function formatCalendarDate(iso: string): string {
  const m = ISO_DATE.exec(iso);
  if (!m) return iso;
  return new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12)).toLocaleDateString('en-US', {
    timeZone: 'UTC',
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  });
}

export type RelativeDay = 'overdue' | 'today' | 'tomorrow' | 'upcoming';

/** Where an occurrence's scheduled_date sits relative to the organization's today. */
export function relativeDay(scheduledDate: string, today: string): RelativeDay {
  if (scheduledDate < today) return 'overdue';
  if (scheduledDate === today) return 'today';
  if (scheduledDate === addDaysIso(today, 1)) return 'tomorrow';
  return 'upcoming';
}

/** Badge text: "Overdue", "Today", "Tomorrow", otherwise the date. */
export function relativeDayLabel(scheduledDate: string, today: string): string {
  const r = relativeDay(scheduledDate, today);
  return r === 'overdue' ? 'Overdue' : r === 'today' ? 'Today' : r === 'tomorrow' ? 'Tomorrow' : formatCalendarDate(scheduledDate);
}
