import type { Enums, Json } from '@/types/database';

/** Shape returned by public.get_my_access_context(). */
export interface AccessContext {
  positions: string[];
  permissions: string[];
  isSystemAdmin: boolean;
}

export type MemberStatus = Enums<'member_status'>;

const isStringArray = (v: unknown): v is string[] =>
  Array.isArray(v) && v.every((x) => typeof x === 'string');

/**
 * Validates the RPC payload at the trust boundary. Anything unexpected
 * (including the `{ error: 'Unauthenticated' }` shape) throws, so the UI never
 * grants access based on a malformed response.
 */
export function parseAccessContext(payload: Json): AccessContext {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('Access context: unexpected payload');
  }
  if ('error' in payload) {
    throw new Error(`Access context: ${String(payload.error)}`);
  }
  const { positions, permissions, is_system_admin } = payload;
  if (!isStringArray(positions) || !isStringArray(permissions) || typeof is_system_admin !== 'boolean') {
    throw new Error('Access context: malformed payload');
  }
  return { positions, permissions, isSystemAdmin: is_system_admin };
}

export type AccessRoute =
  | 'loading' // session or membership still resolving
  | 'signed-out'
  | 'pending' // pending_approval, suspended or rejected: held at PendingApprovalScreen
  | 'error' // membership could not be loaded (e.g. offline on first launch)
  | 'active';

export interface AccessInputs {
  initialized: boolean;
  hasSession: boolean;
  status: MemberStatus | undefined;
  access: AccessContext | undefined;
  failed: boolean;
}

/**
 * Single source of truth for which route group a user may see. Client-side
 * only: every protected read and write is independently enforced by RLS.
 * Fails closed: a user is 'active' only with a confirmed active status AND a
 * loaded access context.
 */
export function resolveAccessRoute(i: AccessInputs): AccessRoute {
  if (!i.initialized) return 'loading';
  if (!i.hasSession) return 'signed-out';
  if (i.status !== undefined && i.status !== 'active') return 'pending';
  if (i.failed) return 'error';
  if (i.status === undefined || i.access === undefined) return 'loading';
  return 'active';
}

export const hasPermission = (access: AccessContext | undefined, permission: string) =>
  access?.permissions.includes(permission) ?? false;

/** Permissions that unlock at least one screen in the (officer) route group. */
export const OFFICER_PERMISSIONS = ['members:approve', 'coaches:assign', 'exercises:approve'] as const;
