'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { call, cartId, type Cart, type Order, type Quote } from '@/lib/api';

export type Result = { ok: true; message: string } | { ok: false; message: string };

// The layout shows the cart count, so every cart change revalidates from the root.
function refresh() {
  revalidatePath('/', 'layout');
}

function reason(err: unknown): string {
  const text = err instanceof Error ? err.message : String(err);
  if (text.includes('out of stock')) return 'Sorry, that robot just sold out.';
  return 'Something went wrong. Please try again.';
}

export async function addToCart(sku: string, name: string): Promise<Result> {
  try {
    await call<Cart>('cart', `cart/${await cartId()}/items`, {
      method: 'POST',
      body: JSON.stringify({ sku, quantity: 1 }),
    });
    refresh();
    return { ok: true, message: `${name} added to your cart` };
  } catch (err) {
    return { ok: false, message: reason(err) };
  }
}

// The cart API only adds or removes, so a lower quantity is a remove followed by an add.
export async function setQuantity(sku: string, quantity: number): Promise<Result> {
  const id = await cartId();
  try {
    await call<Cart>('cart', `cart/${id}/items/${encodeURIComponent(sku)}`, { method: 'DELETE' });
    if (quantity > 0) {
      await call<Cart>('cart', `cart/${id}/items`, { method: 'POST', body: JSON.stringify({ sku, quantity }) });
    }
    refresh();
    return { ok: true, message: quantity > 0 ? 'Cart updated' : 'Item removed' };
  } catch (err) {
    refresh();
    return { ok: false, message: reason(err) };
  }
}

export async function getQuote(cityId: number): Promise<Quote | null> {
  try {
    return await call<Quote>('shipping', `quote/${cityId}`);
  } catch {
    return null;
  }
}

export type CheckoutState = { error?: string };

export async function checkout(_prev: CheckoutState, formData: FormData): Promise<CheckoutState> {
  const id = await cartId();
  const cityId = Number(formData.get('city'));
  if (!cityId) return { error: 'Choose where to ship your order.' };

  let order: Order;
  try {
    order = await call<Order>('payment', `pay/${id}`, {
      method: 'POST',
      body: JSON.stringify({ user_id: id, city_id: cityId }),
    });
  } catch (err) {
    // Payment has fault injection, so declines are expected; nothing was charged.
    console.error('checkout failed', err);
    return { error: 'Your payment was declined and you have not been charged. Please try again.' };
  }
  refresh();
  redirect(`/order/${order.order_id}?total=${order.total}&shipping=${order.shipping}`);
}
