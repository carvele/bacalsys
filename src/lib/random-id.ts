/**
 * RFC4122 v4-ish UUID from `Math.random`. Used only for client-side
 * correlation and idempotency keys (never for cryptographic purposes), so
 * `Math.random`'s strength is sufficient — this avoids adding a native
 * dependency (`expo-crypto`) purely to mint local ids.
 */
export function randomId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
