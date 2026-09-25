import { CHUNK_SIZE, createChunkedStorage, type KeyValueBackend } from '../chunked-storage';

function memoryBackend() {
  const map = new Map<string, string>();
  const backend: KeyValueBackend = {
    getItem: async (k) => map.get(k) ?? null,
    setItem: async (k, v) => {
      map.set(k, v);
    },
    removeItem: async (k) => {
      map.delete(k);
    },
  };
  return { map, backend };
}

describe('createChunkedStorage', () => {
  it('round-trips a value larger than a single SecureStore entry', async () => {
    const { map, backend } = memoryBackend();
    const storage = createChunkedStorage(backend);
    const session = JSON.stringify({ access_token: 'a'.repeat(5000), refresh_token: 'r' });

    await storage.setItem('sb-auth', session);

    expect(await storage.getItem('sb-auth')).toBe(session);
    for (const [, value] of map) expect(value.length).toBeLessThanOrEqual(CHUNK_SIZE);
  });

  it('returns null for a missing key', async () => {
    const storage = createChunkedStorage(memoryBackend().backend);
    expect(await storage.getItem('nope')).toBeNull();
  });

  it('removes stale chunks when a shorter value overwrites a longer one', async () => {
    const { map, backend } = memoryBackend();
    const storage = createChunkedStorage(backend);

    await storage.setItem('k', 'x'.repeat(CHUNK_SIZE * 3));
    await storage.setItem('k', 'short');

    expect(await storage.getItem('k')).toBe('short');
    expect([...map.keys()].sort()).toEqual(['k.0', 'k.chunks']);
  });

  it('treats a torn write (missing chunk) as no session', async () => {
    const { map, backend } = memoryBackend();
    const storage = createChunkedStorage(backend);

    await storage.setItem('k', 'y'.repeat(CHUNK_SIZE * 2));
    map.delete('k.1');

    expect(await storage.getItem('k')).toBeNull();
  });

  it('removeItem deletes every chunk and the manifest', async () => {
    const { map, backend } = memoryBackend();
    const storage = createChunkedStorage(backend);

    await storage.setItem('k', 'z'.repeat(CHUNK_SIZE + 1));
    await storage.removeItem('k');

    expect(map.size).toBe(0);
  });
});
