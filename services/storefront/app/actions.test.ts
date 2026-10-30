import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const CART = '6f1c2a1e-3b4d-4c5e-8f60-718293a4b5c6';
vi.mock('next/headers', () => ({ cookies: async () => ({ get: () => ({ value: CART }) }) }));
vi.mock('next/cache', () => ({ revalidatePath: vi.fn() }));
vi.mock('next/navigation', () => ({
  redirect: vi.fn((url: string) => {
    throw new Error(`NEXT_REDIRECT ${url}`);
  }),
}));

const session = { sub: 'user-1', name: 'Ada', accessToken: 'token-abc', expiresAt: 0 };
const getSession = vi.fn(async (): Promise<typeof session | null> => null);
vi.mock('@/lib/auth', () => ({ getSession: () => getSession(), authEnabled: () => true }));

const { addToCart, checkout, getQuote, postReview, saveProfile, setQuantity } = await import('./actions');

// Answers every Dapr call with the given status and body, and records the requests.
function backend(status: number, body: unknown = {}) {
  const fetch = vi.fn<(url: string, init?: RequestInit) => Promise<Response>>(
    async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status }),
  );
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

function form(fields: Record<string, string>) {
  const data = new FormData();
  for (const [k, v] of Object.entries(fields)) data.set(k, v);
  return data;
}

beforeEach(() => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
  getSession.mockResolvedValue(null);
});
afterEach(() => vi.unstubAllGlobals());

describe('addToCart', () => {
  it('adds one of the item to the visitor cart', async () => {
    const fetch = backend(200);
    expect(await addToCart('RB-002', 'Sweep Bot')).toEqual({ ok: true, message: 'Sweep Bot added to your cart' });

    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(new RegExp(`/v1\\.0/invoke/cart/method/cart/${CART}/items$`));
    expect(init?.method).toBe('POST');
    expect(JSON.parse(String(init?.body))).toEqual({ sku: 'RB-002', quantity: 1 });
  });

  it.each([
    ['"out of stock"', 'Sorry, that robot just sold out.'],
    ['"only 3 in stock"', 'Sorry, only 3 left in stock.'],
    ['boom', 'Something went wrong. Please try again.'],
  ])('explains a %s refusal', async (body, message) => {
    backend(409, body);
    expect(await addToCart('RB-002', 'Sweep Bot')).toEqual({ ok: false, message });
  });
});

describe('setQuantity', () => {
  it('sets the quantity in one call, so a failure cannot drop the line', async () => {
    const fetch = backend(200);
    expect(await setQuantity('RB 2', 2)).toEqual({ ok: true, message: 'Cart updated' });

    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(new RegExp(`/cart/${CART}/items/RB%202$`));
    expect(init?.method).toBe('PUT');
    expect(JSON.parse(String(init?.body))).toEqual({ quantity: 2 });
  });

  it('reports a removal', async () => {
    backend(200);
    expect(await setQuantity('RB-002', 0)).toEqual({ ok: true, message: 'Item removed' });
  });

  it.each([-1, 1.5, 100, Number.NaN])('refuses the quantity %s without calling the cart', async (quantity) => {
    const fetch = backend(200);
    expect((await setQuantity('RB-002', quantity)).ok).toBe(false);
    expect(fetch).not.toHaveBeenCalled();
  });
});

describe('getQuote', () => {
  it('is null when shipping fails', async () => {
    backend(503);
    expect(await getQuote(1)).toBeNull();
  });

  // A server action can be called with any argument, and fetch would resolve "..", reaching other sidecar APIs.
  it.each(['../../../../metadata', '1/../../../secrets/store/key', 0, -3, 2.5])(
    'refuses %s without calling the sidecar',
    async (cityId) => {
      const fetch = backend(200, { cost: 1 });
      expect(await getQuote(cityId as number)).toBeNull();
      expect(fetch).not.toHaveBeenCalled();
    },
  );
});

describe('checkout', () => {
  it('asks for a destination before paying', async () => {
    const fetch = backend(200);
    expect(await checkout({}, form({}))).toEqual({ error: 'Choose where to ship your order.' });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('redirects to the order page once paid', async () => {
    const fetch = backend(200, { order_id: 'o1', total: 716.1, shipping: 18.1 });
    await expect(checkout({}, form({ city: '1' }))).rejects.toThrow('NEXT_REDIRECT /order/o1?total=716.1&shipping=18.1');
    expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({ user_id: CART, city_id: 1 });
  });

  it('says nothing was charged when payment is declined', async () => {
    backend(502, '{"detail":"payment gateway error"}');
    expect((await checkout({}, form({ city: '1' }))).error).toMatch(/declined and you have not been charged/);
  });

  it('asks the shopper to update the cart when stock ran out', async () => {
    backend(409, '{"detail":"out of stock: RB-004"}');
    expect((await checkout({}, form({ city: '1' }))).error).toMatch(/sold out.*update your cart/);
  });
});

describe('checkout as a signed-in shopper', () => {
  it('records the order against the shopper rather than the cart', async () => {
    getSession.mockResolvedValue(session);
    const fetch = backend(200, { order_id: 'o1', total: 1, shipping: 1 });
    await expect(checkout({}, form({ city: '1' }))).rejects.toThrow('NEXT_REDIRECT');
    expect(JSON.parse(String(fetch.mock.calls[0][1]?.body)).user_id).toBe('user-1');
  });
});

describe('postReview', () => {
  const review = (fields: Record<string, string>) => postReview('RB-001', {}, form(fields));

  it('asks a signed-out shopper to sign in, without calling the service', async () => {
    const fetch = backend(201);
    expect(await review({ rating: '5', body: 'Great' })).toEqual({ ok: false, message: 'Sign in to write a review.' });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('forwards the access token to the reviews service', async () => {
    getSession.mockResolvedValue(session);
    const fetch = backend(201, {});
    expect((await review({ rating: '4', body: ' Solid ' })).ok).toBe(true);
    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(/\/invoke\/reviews\/method\/products\/RB-001\/reviews$/);
    expect((init?.headers as Record<string, string>).authorization).toBe('Bearer token-abc');
    expect(JSON.parse(String(init?.body))).toEqual({ rating: 4, body: 'Solid' });
  });

  it.each([
    [{ rating: '0', body: 'x' }, 'Choose a rating from 1 to 5 stars.'],
    [{ rating: '5', body: '   ' }, 'Write between 1 and 2000 characters.'],
  ])('rejects %o before calling the service', async (fields, message) => {
    getSession.mockResolvedValue(session);
    const fetch = backend(201);
    expect(await review(fields)).toEqual({ ok: false, message });
    expect(fetch).not.toHaveBeenCalled();
  });

  it.each([
    [409, 'You have already reviewed this robot.'],
    [401, 'Sign in to write a review.'],
    [500, 'Something went wrong. Please try again.'],
  ])('explains a %i from the service', async (code, message) => {
    getSession.mockResolvedValue(session);
    backend(code, 'nope');
    expect(await review({ rating: '5', body: 'x' })).toEqual({ ok: false, message });
  });
});

describe('saveProfile', () => {
  it('saves the name and default city', async () => {
    getSession.mockResolvedValue(session);
    const fetch = backend(200, {});
    expect(await saveProfile({}, form({ displayName: ' Ada ', city: '3' }))).toEqual({ ok: true, message: 'Saved.' });
    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(/\/invoke\/profile\/method\/me$/);
    expect(init?.method).toBe('PUT');
    expect(JSON.parse(String(init?.body))).toEqual({ displayName: 'Ada', defaultCityId: 3 });
  });

  it('clears the default city when none is chosen', async () => {
    getSession.mockResolvedValue(session);
    const fetch = backend(200, {});
    await saveProfile({}, form({ displayName: 'Ada', city: '' }));
    expect(JSON.parse(String(fetch.mock.calls[0][1]?.body)).defaultCityId).toBeNull();
  });

  it('explains an unknown city', async () => {
    getSession.mockResolvedValue(session);
    backend(400, '{"error":"unknown city"}');
    expect(await saveProfile({}, form({ displayName: 'Ada', city: '99' }))).toEqual({ ok: false, message: 'Choose a city from the list.' });
  });
});