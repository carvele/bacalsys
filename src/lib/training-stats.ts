import { addDaysIso, isoDateInZone, isoDayOfWeek } from '@/lib/date-tz';
import type { AthleteSummary, CategoryVolume } from '@/types/skills';

/**
 * Sprint 6 · Task 6.10 — pure helpers behind the Training Calendar (Feature 7.1)
 * and the summary cards (Feature 7.2). Nothing here touches a clock, the device
 * timezone or the network: every date is a `YYYY-MM-DD` string in the
 * ORGANIZATION's calendar (the server already resolved it), and the only instant
 * that is converted (a session's `started_at`) goes through `isoDateInZone`.
 */

// -- Calendar status semantics (Section 13, invariant 1) ----------------------------------------

/** Highest precedence first: completed > partially_completed > in_progress > upcoming > abandoned > missed. */
export const CALENDAR_STATUSES = ['completed', 'partially_completed', 'in_progress', 'upcoming', 'abandoned', 'missed'] as const;
export type CalendarStatus = (typeof CALENDAR_STATUSES)[number];

export const CALENDAR_STATUS_COLOR: Record<CalendarStatus, string> = {
  completed: '#10B981',
  partially_completed: '#F59E0B',
  in_progress: '#3B82F6',
  upcoming: '#3B82F6',
  abandoned: '#6B7280',
  missed: '#EF4444',
};

export const CALENDAR_STATUS_LABEL: Record<CalendarStatus, string> = {
  completed: 'Completed',
  partially_completed: 'Partially completed',
  in_progress: 'In progress',
  upcoming: 'Upcoming',
  abandoned: 'Abandoned',
  missed: 'Missed',
};

const isCalendarStatus = (s: string): s is CalendarStatus => (CALENDAR_STATUSES as readonly string[]).includes(s);

/** The one status a day shows when several sessions/occurrences land on it (deterministic precedence). */
export function resolveDayStatus(statuses: readonly string[]): CalendarStatus | null {
  for (const s of CALENDAR_STATUSES) if (statuses.includes(s)) return s;
  return null;
}

/**
 * A session's calendar status. The database status is explicit business state;
 * the only derived distinction is the one the roadmap names: a session that ended
 * early WITH recorded sets is "partially completed", one that ended with none is
 * "abandoned".
 */
export function sessionCalendarStatus(status: string, recordedSets: number): CalendarStatus | null {
  if (status === 'completed') return 'completed';
  if (status === 'in_progress') return 'in_progress';
  if (status === 'abandoned') return recordedSets >= 1 ? 'partially_completed' : 'abandoned';
  return null;
}

export interface CalendarEntry {
  /** Stable React key. */
  key: string;
  /** Organization-local calendar day. */
  date: string;
  status: CalendarStatus;
  title: string;
  occurrenceId: string | null;
  /** The session to open for a replay, when one exists. */
  sessionId: string | null;
}

export interface OccurrenceInput {
  id: string;
  scheduled_date: string;
  status: string;
  title?: string | null;
}

export interface SessionInput {
  id: string;
  started_at: string;
  status: string;
  assignment_occurrence_id: string | null;
  recordedSets: number;
  title?: string | null;
}

/**
 * Merges assigned occurrences and spontaneous sessions into one calendar.
 * A session linked to an occurrence is folded INTO that occurrence's entry (so a
 * completed assigned workout is one green dot, not two, and tapping it opens the
 * replay); a session with no occurrence — or whose occurrence is outside the
 * loaded range / not visible to the viewer — stands alone on its local start day.
 */
export function buildCalendarEntries(input: { occurrences: OccurrenceInput[]; sessions: SessionInput[]; timezone: string }): CalendarEntry[] {
  const sessionByOccurrence = new Map<string, SessionInput>();
  for (const s of input.sessions) {
    if (s.assignment_occurrence_id) sessionByOccurrence.set(s.assignment_occurrence_id, s);
  }
  const occurrenceIds = new Set(input.occurrences.map((o) => o.id));
  const entries: CalendarEntry[] = [];

  for (const o of input.occurrences) {
    if (!isCalendarStatus(o.status)) continue;
    entries.push({
      key: `o:${o.id}`,
      date: o.scheduled_date,
      status: o.status,
      title: o.title || 'Assigned workout',
      occurrenceId: o.id,
      sessionId: sessionByOccurrence.get(o.id)?.id ?? null,
    });
  }
  for (const s of input.sessions) {
    if (s.assignment_occurrence_id && occurrenceIds.has(s.assignment_occurrence_id)) continue;
    const status = sessionCalendarStatus(s.status, s.recordedSets);
    if (!status) continue;
    entries.push({
      key: `s:${s.id}`,
      date: isoDateInZone(new Date(s.started_at), input.timezone),
      status,
      title: s.title || 'Workout',
      occurrenceId: null,
      sessionId: s.id,
    });
  }
  return entries.sort((a, b) => a.date.localeCompare(b.date) || a.key.localeCompare(b.key));
}

export function groupByDay(entries: readonly CalendarEntry[]): Map<string, CalendarEntry[]> {
  const map = new Map<string, CalendarEntry[]>();
  for (const e of entries) map.set(e.date, [...(map.get(e.date) ?? []), e]);
  return map;
}

// -- Month arithmetic (all on YYYY-MM-DD strings) ------------------------------------------------

/** First day of the month containing `iso`. */
export const monthStart = (iso: string) => `${iso.slice(0, 7)}-01`;

export function shiftMonth(monthIso: string, delta: number): string {
  const y = Number(monthIso.slice(0, 4));
  const m = Number(monthIso.slice(5, 7)) - 1 + delta;
  const d = new Date(Date.UTC(y, m, 1));
  return d.toISOString().slice(0, 10);
}

/** Last day of the month containing `iso`. */
export const monthEnd = (iso: string) => addDaysIso(shiftMonth(monthStart(iso), 1), -1);

export const daysInMonth = (iso: string) => Number(monthEnd(iso).slice(8, 10));

const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
export const monthLabel = (iso: string) => `${MONTH_NAMES[Number(iso.slice(5, 7)) - 1]} ${iso.slice(0, 4)}`;

/** Weeks (Monday first) of the month containing `iso`; days outside the month are null. */
export function buildMonthGrid(iso: string): (string | null)[][] {
  const first = monthStart(iso);
  const total = daysInMonth(first);
  const lead = isoDayOfWeek(first) - 1; // Monday = 0
  const cells: (string | null)[] = [
    ...Array<null>(lead).fill(null),
    ...Array.from({ length: total }, (_, i) => addDaysIso(first, i)),
  ];
  while (cells.length % 7 !== 0) cells.push(null);
  const weeks: (string | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
  return weeks;
}

// -- Adherence & volume presentation (Feature 7.2) -----------------------------------------------

/** "50.0%" — or an em dash when nothing was due (a null rate is "no data", never 0 %). */
export const formatAdherence = (rate: number | null) => (rate === null ? '—' : `${rate.toFixed(1)}%`);

/** 0–100 for a progress bar; null-rate → 0 width. */
export const adherenceBarPercent = (rate: number | null) => (rate === null ? 0 : Math.max(0, Math.min(100, rate)));

export function adherenceCaption(s: Pick<AthleteSummary, 'scheduledWorkouts' | 'completedWorkouts'>): string {
  if (s.scheduledWorkouts === 0) return 'No scheduled workouts were due in this window.';
  return `${s.completedWorkouts} of ${s.scheduledWorkouts} scheduled workout${s.scheduledWorkouts === 1 ? '' : 's'} completed.`;
}

export function formatDuration(totalSeconds: number): string {
  const s = Math.max(0, Math.round(totalSeconds));
  if (s < 60) return `${s} s`;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const rest = s % 60;
  if (h > 0) return `${h} h ${String(m).padStart(2, '0')} min`;
  return rest === 0 ? `${m} min` : `${m} min ${rest} s`;
}

const CATEGORY_LABEL: Record<string, string> = {
  push: 'Push',
  pull: 'Pull',
  legs: 'Legs',
  core: 'Core',
  skill: 'Skill',
  mobility: 'Mobility',
};
export const exerciseCategoryLabel = (c: string) => CATEGORY_LABEL[c] ?? c;

export interface VolumeShare extends CategoryVolume {
  label: string;
  /** Fraction (0–1) of all completed sets. */
  share: number;
}

export function volumeShares(volume: readonly CategoryVolume[]): VolumeShare[] {
  const total = volume.reduce((n, v) => n + v.sets, 0);
  return volume.map((v) => ({ ...v, label: exerciseCategoryLabel(v.category), share: total === 0 ? 0 : v.sets / total }));
}
