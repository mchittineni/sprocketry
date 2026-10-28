import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('next/headers', () => ({ cookies: async () => ({ get: () => ({ value: 'cart-1' }) }) }));
vi.mock('next/cache', () => ({ revalidatePath: vi.fn() }));
vi.mock('next/navigation', () => ({
  redirect: vi.fn((url: string) => {
    throw new Error(`NEXT_REDIRECT ${url}`);
  }),
}));

const { addToCart, checkout, getQuote, setQuantity } = await import('./actions');

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

beforeEach(() => vi.spyOn(console, 'error').mockImplementation(() => {}));
afterEach(() => vi.unstubAllGlobals());

describe('addToCart', () => {
  it('adds one of the item to the visitor cart', async () => {
    const fetch = backend(200);
    expect(await addToCart('RB-002', 'Sweep Bot')).toEqual({ ok: true, message: 'Sweep Bot added to your cart' });

    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(/\/v1\.0\/invoke\/cart\/method\/cart\/cart-1\/items$/);
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
    expect(url).toMatch(/\/cart\/cart-1\/items\/RB%202$/);
    expect(init?.method).toBe('PUT');
    expect(JSON.parse(String(init?.body))).toEqual({ quantity: 2 });
  });

  it('reports a removal', async () => {
    backend(200);
    expect(await setQuantity('RB-002', 0)).toEqual({ ok: true, message: 'Item removed' });
  });
});

describe('getQuote', () => {
  it('is null when shipping fails', async () => {
    backend(503);
    expect(await getQuote(1)).toBeNull();
  });
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
    expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({ user_id: 'cart-1', city_id: 1 });
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
