'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { authedCall, call, cartId, NotSignedInError, type Cart, type Order, type Profile, type Quote, type Review } from '@/lib/api';
import { getSession } from '@/lib/auth';
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

  // Orders belong to the signed-in shopper, or to the anonymous cart otherwise.
  const userId = (await getSession().catch(() => null))?.sub ?? id;
  let order: Order;
  try {
    order = await call<Order>('payment', `pay/${id}`, {
      method: 'POST',
      body: JSON.stringify({ user_id: userId, city_id: cityId }),
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

export type FormState = { ok?: boolean; message?: string };

function status(err: unknown): number | undefined {
  const match = err instanceof Error ? /: (\d{3}) /.exec(err.message) : null;
  return match ? Number(match[1]) : undefined;
}

export async function postReview(sku: string, _prev: FormState, formData: FormData): Promise<FormState> {
  const rating = Number(formData.get('rating'));
  const body = String(formData.get('body') ?? '').trim();
  if (!(rating >= 1 && rating <= 5)) return { ok: false, message: 'Choose a rating from 1 to 5 stars.' };
  if (!body || body.length > 2000) return { ok: false, message: 'Write between 1 and 2000 characters.' };
  try {
    await authedCall<Review>('reviews', `products/${encodeURIComponent(sku)}/reviews`, {
      method: 'POST',
      body: JSON.stringify({ rating, body }),
    });
  } catch (err) {
    if (err instanceof NotSignedInError || status(err) === 401) return { ok: false, message: 'Sign in to write a review.' };
    if (status(err) === 409) return { ok: false, message: 'You have already reviewed this robot.' };
    console.error('review failed', err);
    return { ok: false, message: 'Something went wrong. Please try again.' };
  }
  revalidatePath(`/products/${sku}`);
  return { ok: true, message: 'Thanks! Your review is live.' };
}

export async function saveProfile(_prev: FormState, formData: FormData): Promise<FormState> {
  const displayName = String(formData.get('displayName') ?? '').trim();
  const city = String(formData.get('city') ?? '');
  if (!displayName || displayName.length > 60) return { ok: false, message: 'Use a name of 1 to 60 characters.' };
  try {
    await authedCall<Profile>('profile', 'me', {
      method: 'PUT',
      body: JSON.stringify({ displayName, defaultCityId: city ? Number(city) : null }),
    });
  } catch (err) {
    if (err instanceof NotSignedInError || status(err) === 401) return { ok: false, message: 'Your session has ended. Sign in again.' };
    if (status(err) === 400) return { ok: false, message: 'Choose a city from the list.' };
    console.error('profile update failed', err);
    return { ok: false, message: 'Something went wrong. Please try again.' };
  }
  refresh();
  return { ok: true, message: 'Saved.' };
}