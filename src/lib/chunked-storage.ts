/**
 * Supabase session JSON routinely exceeds SecureStore's ~2 KB per-value limit
 * (access token + refresh token + user object). This adapter splits a value
 * across numbered keys and records the chunk count under a manifest key.
 *
 * Kept free of expo imports so it can be unit tested against an in-memory store.
 */
export interface KeyValueBackend {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

export const CHUNK_SIZE = 1800;

const manifestKey = (key: string) => `${key}.chunks`;
const chunkKey = (key: string, index: number) => `${key}.${index}`;

export function createChunkedStorage(backend: KeyValueBackend) {
  async function removeChunks(key: string) {
    const raw = await backend.getItem(manifestKey(key));
    const count = raw ? Number.parseInt(raw, 10) : 0;
    for (let i = 0; i < count; i++) {
      await backend.removeItem(chunkKey(key, i));
    }
    await backend.removeItem(manifestKey(key));
  }

  return {
    async getItem(key: string): Promise<string | null> {
      const raw = await backend.getItem(manifestKey(key));
      if (raw === null) return null;
      const count = Number.parseInt(raw, 10);
      if (!Number.isFinite(count) || count < 0) return null;

      const parts: string[] = [];
      for (let i = 0; i < count; i++) {
        const part = await backend.getItem(chunkKey(key, i));
        // A missing chunk means a torn write; treat the session as absent so
        // the user re-authenticates instead of parsing corrupt JSON.
        if (part === null) return null;
        parts.push(part);
      }
      return parts.join('');
    },

    async setItem(key: string, value: string): Promise<void> {
      await removeChunks(key);
      const count = Math.ceil(value.length / CHUNK_SIZE);
      for (let i = 0; i < count; i++) {
        await backend.setItem(chunkKey(key, i), value.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE));
      }
      // Manifest is written last so a partial write is never read as complete.
      await backend.setItem(manifestKey(key), String(count));
    },

    async removeItem(key: string): Promise<void> {
      await removeChunks(key);
    },
  };
}
