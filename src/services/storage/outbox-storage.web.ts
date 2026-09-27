import { webOutbox } from './web-outbox';

/** Web: IndexedDB (in-memory under Jest). See outbox-storage.ts for native. */
export const outboxStorage = webOutbox;
