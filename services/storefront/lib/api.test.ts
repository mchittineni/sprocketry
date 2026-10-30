import { afterEach, describe, expect, it, vi } from 'vitest';

let cookie: string | undefined;
vi.mock('next/headers', () => ({ cookies: async () => ({ get: () => (cookie ? { value: cookie } : undefined) }) }));
vi.mock('./auth', () => ({ getSession: async () => null }));

const { call, cartId } = await import('./api');

afterEach(() => vi.unstubAllGlobals());

describe('call', () => {
  // fetch would resolve each of these to a sidecar API outside /invoke/<app>/method.
  it.each(['quote/../../../../metadata', 'quote/%2e%2e/%2E%2E/metadata', 'quote/./x', 'quote/1?x', 'quote/1#', 'quote\\..\\x'])(
    'refuses %s without calling the sidecar',
    async (path) => {
      const fetch = vi.fn();
      vi.stubGlobal('fetch', fetch);
      await expect(call('shipping', path)).rejects.toThrow('invalid path');
      expect(fetch).not.toHaveBeenCalled();
    },
  );
});

describe('cartId', () => {
  it('returns the UUID the proxy issued', async () => {
    cookie = '6f1c2a1e-3b4d-4c5e-8f60-718293a4b5c6';
    expect(await cartId()).toBe(cookie);
  });

  it.each(['anonymous', '../../../../publish/pubsub/orders#', undefined])('refuses the cookie %s', async (value) => {
    cookie = value;
    await expect(cartId()).rejects.toThrow('cart_id');
  });
});
