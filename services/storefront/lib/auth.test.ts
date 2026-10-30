import { describe, expect, it, vi } from 'vitest';

vi.mock('next/headers', () => ({ cookies: async () => ({ get: () => undefined }) }));

const { safeReturnTo } = await import('./auth');

describe('safeReturnTo', () => {
  it.each(['/', '/account', '/products/RB-001?x=1'])('keeps the same-site path %s', (path) => {
    expect(safeReturnTo(path)).toBe(path);
  });

  // Each of these would send the shopper to another site after signing in.
  it.each([
    'https://evil.example/',
    '//evil.example',
    '/\\evil.example',
    '/\t/evil.example',
    '/\n/evil.example',
    '/\\\t\\evil.example',
    'evil',
    '',
    null,
    undefined,
  ])(
    'replaces %s with the home page',
    (path) => {
      expect(safeReturnTo(path)).toBe('/');
    },
  );
});
