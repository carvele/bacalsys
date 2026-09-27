import { sqliteOutbox } from './sqlite-outbox';

/** Native (iOS/Android): expo-sqlite. See outbox-storage.web.ts for the web build. */
export const outboxStorage = sqliteOutbox;
