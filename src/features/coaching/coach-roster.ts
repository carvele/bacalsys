/**
 * Shapes the member directory and active coach assignments into the officer's
 * coach-assignment roster. UX only: public.assign_primary_coach() re-validates
 * every rule (coaches:assign, active athlete, active Coach position, same
 * organization, no-op) on the server.
 */
export interface MemberRow {
  id: string;
  full_name: string;
  member_positions: { ended_at: string | null; positions: { name: string } | null }[];
}

export interface ActiveAssignment {
  id: string;
  athlete_id: string;
  coach_id: string;
  started_at: string;
}

export interface RosterEntry {
  id: string;
  name: string;
  positions: string[];
  currentCoach: { id: string; name: string; since: string } | null;
}

export const activePositions = (m: MemberRow) =>
  m.member_positions.filter((mp) => mp.ended_at === null && mp.positions).map((mp) => mp.positions!.name);

export const displayName = (name: string | null | undefined) => (name && name.trim()) || 'Unnamed member';

export function buildRoster(members: MemberRow[], assignments: ActiveAssignment[]) {
  const byId = new Map(members.map((m) => [m.id, m]));
  const coachOf = new Map(assignments.map((a) => [a.athlete_id, a]));

  const entries: RosterEntry[] = members
    .map((m) => {
      const a = coachOf.get(m.id);
      return {
        id: m.id,
        name: displayName(m.full_name),
        positions: activePositions(m),
        currentCoach: a ? { id: a.coach_id, name: displayName(byId.get(a.coach_id)?.full_name), since: a.started_at } : null,
      };
    })
    .sort((x, y) => x.name.localeCompare(y.name));

  const coaches = entries.filter((e) => e.positions.includes('Coach'));
  return { athletes: entries, coaches };
}

/** Coaches offered for an athlete: never the athlete themselves or their current coach (the server rejects both). */
export const eligibleCoaches = (athlete: RosterEntry, coaches: RosterEntry[]) =>
  coaches.filter((c) => c.id !== athlete.id && c.id !== athlete.currentCoach?.id);

export function searchRoster(entries: RosterEntry[], query: string) {
  const q = query.trim().toLowerCase();
  return q ? entries.filter((e) => e.name.toLowerCase().includes(q)) : entries;
}
