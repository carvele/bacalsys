/** Maps Supabase / PostgREST / Auth errors to messages safe to show members. */
export function describeError(error: unknown): string {
  if (error && typeof error === 'object') {
    const e = error as { code?: string; message?: string };
    switch (e.code) {
      case '42501':
        return 'You do not have permission to do that.';
      case '55000':
        return 'This request was already processed.';
      case 'P0002':
        return 'That record no longer exists.';
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
