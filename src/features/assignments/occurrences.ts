import { relativeDay, type RelativeDay } from '@/lib/date-tz';

/**
 * Sprint 5 · Tasks 5.13–5.14 — occurrence presentation logic shared by the
 * athlete home "Today's training" card and the coach roster.
 */
export const OCCURRENCE_STATUSES = ['upcoming', 'in_progress', 'completed', 'partially_completed', 'abandoned', 'missed'] as const;
export type OccurrenceStatus = (typeof OCCURRENCE_STATUSES)[number];

export const STATUS_LABEL: Record<OccurrenceStatus, string> = {
  upcoming: 'Upcoming',
  in_progress: 'In progress',
  completed: 'Completed',
  partially_completed: 'Partially completed',
  abandoned: 'Abandoned',
  missed: 'Missed',
};

export type StatusTone = 'neutral' | 'active' | 'success' | 'warning' | 'danger';
export const STATUS_TONE: Record<OccurrenceStatus, StatusTone> = {
  upcoming: 'neutral',
  in_progress: 'active',
  completed: 'success',
  partially_completed: 'warning',
  abandoned: 'warning',
  missed: 'danger',
};

export const statusLabel = (status: string) => STATUS_LABEL[status as OccurrenceStatus] ?? status;
export const statusTone = (status: string): StatusTone => STATUS_TONE[status as OccurrenceStatus] ?? 'neutral';

/**
 * The "Start workout" button shows for `upcoming` and `in_progress` occurrences
 * (an in-progress one re-opens the player). Finished / missed ones do not.
 * A completed or partially completed workout shows a completion mark instead.
 */
export const canStartOccurrence = (status: string) => status === 'upcoming' || status === 'in_progress';
export const showsCompletionMark = (status: string) => status === 'completed' || status === 'partially_completed';

/** Route params the Workout Player needs to run an assigned occurrence (Task 5.13). */
export const playerParams = (o: { workoutVersionId: string; id: string }) => ({ versionId: o.workoutVersionId, occurrenceId: o.id });

export interface OccurrenceRow {
  id: string;
  scheduled_date: string;
  status: string;
  workout_version_id: string;
}

/** Today's occurrences first (organization-local day), then overdue-but-still-startable ones. */
export function todaysTraining<T extends OccurrenceRow>(rows: T[], today: string): T[] {
  const rank = (r: RelativeDay) => (r === 'today' ? 0 : 1);
  return rows
    .filter((r) => {
      const day = relativeDay(r.scheduled_date, today);
      return day === 'today' || (day === 'overdue' && r.status === 'in_progress');
    })
    .sort((a, b) => rank(relativeDay(a.scheduled_date, today)) - rank(relativeDay(b.scheduled_date, today)) || a.scheduled_date.localeCompare(b.scheduled_date));
}

export interface AthleteAssignmentSummary {
  athleteId: string;
  upcomingCount: number;
  nextDate: string | null;
}

/** Per-athlete "N assigned · next <date>" for the coach roster (upcoming occurrences only). */
export function summarizeByAthlete(rows: { athlete_id: string; scheduled_date: string; status: string }[]): Map<string, AthleteAssignmentSummary> {
  const out = new Map<string, AthleteAssignmentSummary>();
  for (const r of rows) {
    if (r.status !== 'upcoming') continue;
    const cur = out.get(r.athlete_id) ?? { athleteId: r.athlete_id, upcomingCount: 0, nextDate: null };
    cur.upcomingCount += 1;
    if (cur.nextDate === null || r.scheduled_date < cur.nextDate) cur.nextDate = r.scheduled_date;
    out.set(r.athlete_id, cur);
  }
  return out;
}
