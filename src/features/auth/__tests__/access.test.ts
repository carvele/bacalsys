import { hasPermission, parseAccessContext, resolveAccessRoute, type AccessInputs } from '../access';

const athlete = { positions: ['Athlete'], permissions: [], isSystemAdmin: false };
const base: AccessInputs = { initialized: true, hasSession: true, status: 'active', access: athlete, failed: false };

describe('resolveAccessRoute', () => {
  it('waits for the persisted session before deciding', () => {
    expect(resolveAccessRoute({ ...base, initialized: false })).toBe('loading');
  });

  it('routes users without a session to the auth screens', () => {
    expect(resolveAccessRoute({ ...base, hasSession: false, status: undefined, access: undefined })).toBe('signed-out');
  });

  it.each(['pending_approval', 'suspended', 'rejected'] as const)(
    'holds %s members at the pending gate even if an access context is present',
    (status) => {
      expect(resolveAccessRoute({ ...base, status })).toBe('pending');
    },
  );

  it('only grants the active route with both an active status and a loaded access context', () => {
    expect(resolveAccessRoute(base)).toBe('active');
    expect(resolveAccessRoute({ ...base, access: undefined })).toBe('loading');
    expect(resolveAccessRoute({ ...base, status: undefined })).toBe('loading');
  });

  it('fails closed when membership cannot be loaded', () => {
    expect(resolveAccessRoute({ ...base, status: undefined, access: undefined, failed: true })).toBe('error');
    expect(resolveAccessRoute({ ...base, access: undefined, failed: true })).toBe('error');
  });

  it('keeps a known non-active member gated even when a later request fails', () => {
    expect(resolveAccessRoute({ ...base, status: 'pending_approval', failed: true })).toBe('pending');
  });
});

describe('parseAccessContext', () => {
  it('maps the RPC payload', () => {
    expect(
      parseAccessContext({ positions: ['President'], permissions: ['members:approve'], is_system_admin: false }),
    ).toEqual({ positions: ['President'], permissions: ['members:approve'], isSystemAdmin: false });
  });

  it('rejects the unauthenticated shape', () => {
    expect(() => parseAccessContext({ error: 'Unauthenticated' })).toThrow('Unauthenticated');
  });

  it.each([null, 'x', [], { positions: 'Athlete', permissions: [], is_system_admin: false }, { positions: [], permissions: [1], is_system_admin: false }, { positions: [], permissions: [], is_system_admin: 'yes' }])(
    'rejects malformed payload %p',
    (payload) => {
      expect(() => parseAccessContext(payload as never)).toThrow();
    },
  );
});

describe('hasPermission', () => {
  it('is false without an access context', () => {
    expect(hasPermission(undefined, 'members:approve')).toBe(false);
  });

  it('checks exact permission names', () => {
    const ctx = { ...athlete, permissions: ['members:approve'] };
    expect(hasPermission(ctx, 'members:approve')).toBe(true);
    expect(hasPermission(ctx, 'members:app')).toBe(false);
  });
});
