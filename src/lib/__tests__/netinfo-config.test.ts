import { netInfoConfiguration } from '../netinfo-config';

const url = 'https://example.supabase.co';
const key = 'sb_publishable_test';

describe('netInfoConfiguration', () => {
  it('leaves native reachability untouched', () => {
    expect(netInfoConfiguration('android', url, key)).toBeNull();
    expect(netInfoConfiguration('ios', url, key)).toBeNull();
  });

  it('never probes the page origin on web (sub-path hosting returns 404 there)', () => {
    const config = netInfoConfiguration('web', url, key)!;
    expect(config.reachabilityUrl).toBe('https://example.supabase.co/auth/v1/health');
    expect(config.reachabilityUrl).not.toBe('/');
    expect(config.reachabilityMethod).toBe('GET');
    expect(config.reachabilityHeaders).toEqual({ apikey: key });
  });

  it('normalizes a trailing slash on the Supabase URL', () => {
    expect(netInfoConfiguration('web', `${url}/`, key)!.reachabilityUrl).toBe(`${url}/auth/v1/health`);
  });

  it('treats only HTTP 200 as reachable', async () => {
    const test = netInfoConfiguration('web', url, key)!.reachabilityTest!;
    await expect(test({ status: 200 } as Response)).resolves.toBe(true);
    await expect(test({ status: 404 } as Response)).resolves.toBe(false);
    await expect(test({ status: 503 } as Response)).resolves.toBe(false);
  });
});
