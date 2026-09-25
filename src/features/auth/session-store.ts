import type { Session } from '@supabase/supabase-js';
import { create } from 'zustand';

interface SessionState {
  /** Current Supabase session, or null when signed out. */
  session: Session | null;
  /** False until the persisted session has been read from storage. */
  initialized: boolean;
  setSession: (session: Session | null) => void;
}

export const useSessionStore = create<SessionState>((set) => ({
  session: null,
  initialized: false,
  setSession: (session) => set({ session, initialized: true }),
}));
