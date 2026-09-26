import { buildRoster, eligibleCoaches, searchRoster, type MemberRow } from '../coach-roster';

const pos = (name: string, ended_at: string | null = null) => ({ ended_at, positions: { name } });
const members: MemberRow[] = [
  { id: 'a', full_name: 'Juan', member_positions: [pos('Athlete')] },
  { id: 'b', full_name: 'Ana', member_positions: [pos('Athlete')] },
  { id: 'x', full_name: 'Coach X', member_positions: [pos('Athlete'), pos('Coach')] },
  { id: 'y', full_name: 'Coach Y', member_positions: [pos('Coach')] },
  { id: 'z', full_name: 'Former Coach', member_positions: [pos('Coach', '2026-01-01T00:00:00Z'), pos('Athlete')] },
  { id: 'n', full_name: '', member_positions: [pos('Athlete')] },
];
const assignments = [{ id: 'as1', athlete_id: 'a', coach_id: 'x', started_at: '2026-09-01T00:00:00Z' }];

describe('buildRoster', () => {
  const { athletes, coaches } = buildRoster(members, assignments);

  it('attaches each athlete’s current coach', () => {
    expect(athletes.find((e) => e.id === 'a')?.currentCoach).toEqual({ id: 'x', name: 'Coach X', since: '2026-09-01T00:00:00Z' });
    expect(athletes.find((e) => e.id === 'b')?.currentCoach).toBeNull();
  });

  it('offers only members holding an ACTIVE Coach position as coaches', () => {
    expect(coaches.map((c) => c.id).sort()).toEqual(['x', 'y']);
  });

  it('names unnamed members and sorts by name', () => {
    expect(athletes.map((e) => e.name)).toEqual(['Ana', 'Coach X', 'Coach Y', 'Former Coach', 'Juan', 'Unnamed member']);
  });
});

describe('eligibleCoaches', () => {
  const { athletes, coaches } = buildRoster(members, assignments);
  it('excludes the athlete themselves and their current coach', () => {
    const juan = athletes.find((e) => e.id === 'a')!;
    expect(eligibleCoaches(juan, coaches).map((c) => c.id)).toEqual(['y']);
    const coachX = athletes.find((e) => e.id === 'x')!;
    expect(eligibleCoaches(coachX, coaches).map((c) => c.id)).toEqual(['y']);
  });
});

describe('searchRoster', () => {
  const { athletes } = buildRoster(members, assignments);
  it('matches names case-insensitively', () => {
    expect(searchRoster(athletes, 'coach').map((e) => e.id)).toEqual(['x', 'y', 'z']);
    expect(searchRoster(athletes, '  ').length).toBe(athletes.length);
  });
});
