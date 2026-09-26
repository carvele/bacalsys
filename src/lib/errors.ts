/**
 * Maps Supabase / PostgREST / Auth errors to messages safe to show members.
 * `overrides` lets a screen phrase a code for its own context (e.g. 55000).
 */
export function describeError(error: unknown, overrides: Partial<Record<string, string>> = {}): string {
  if (error && typeof error === 'object') {
    const e = error as { code?: string; message?: string };
    if (e.code && overrides[e.code]) return overrides[e.code]!;
    switch (e.code) {
      case '42501':
        return 'You do not have permission to do that.';
      case '55000':
        return 'This request was already processed.';
      case 'P0002':
        return 'That record no longer exists.';
      case '22023':
        // Raised by BaCalSys RPCs with messages written for members (e.g. "A rejection reason is required").
        return e.message && e.message.length <= 160 ? e.message : 'That request is not valid.';
      case '23505':
        return 'Something with that name already exists.';
      case '23514':
        return 'Some details are not valid. Check the form and try again.';
      case 'invalid_credentials':
        return 'Incorrect email or password.';
      case 'user_already_exists':
      case 'email_exists':
        return 'An account with this email already exists.';
      case 'weak_password':
        return 'Choose a stronger password (at least 8 characters).';
      case 'over_request_rate_limit':
      case 'over_email_send_rate_limit':
        return 'Too many attempts. Wait a moment and try again.';
    }
    if (e.message?.includes('Network request failed') || e.message?.includes('Failed to fetch')) {
      return 'Cannot reach the server. Check your connection and try again.';
    }
  }
  return 'Something went wrong. Please try again.';
}
