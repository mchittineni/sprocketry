'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { call, cartId, type Cart, type Order, type Quote } from '@/lib/api';
import { reason } from '@/lib/messages';

export type Result = { ok: true; message: string } | { ok: false; message: string };

// The layout shows the cart count, so every cart change revalidates from the root.
function refresh() {
  revalidatePath('/', 'layout');
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

export async function setQuantity(sku: string, quantity: number): Promise<Result> {
  try {
    await call<Cart>('cart', `cart/${await cartId()}/items/${encodeURIComponent(sku)}`, {
      method: 'PUT',
      body: JSON.stringify({ quantity }),
    });
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
    console.error('checkout failed', err);
    if (String(err).includes('out of stock')) {
      refresh();
      return { error: 'Part of your order just sold out, so you have not been charged. Please update your cart.' };
    }
    // Payment has fault injection, so declines are expected; nothing was charged.
    return { error: 'Your payment was declined and you have not been charged. Please try again.' };
  }
  refresh();
  redirect(`/order/${order.order_id}?total=${order.total}&shipping=${order.shipping}`);
}
