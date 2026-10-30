// Every backend call goes through the Dapr sidecar's service invocation API,
// so the storefront never needs to know where other services run.
import { cookies } from 'next/headers';
import { getSession } from './auth';
import { isCartId } from './cart-id';

const DAPR = `http://localhost:${process.env.DAPR_HTTP_PORT ?? '3500'}/v1.0/invoke`;

export interface Product {
  sku: string;
  name: string;
  description: string;
  category: string;
  price: number;
  stock: number;
}

export interface Cart {
  id: string;
  items: { sku: string; name: string; price: number; quantity: number }[];
  total: number;
}

export interface Order {
  order_id: string;
  total: number;
  shipping: number;
}

export interface Quote {
  cityId: number;
  city: string;
  country: string;
  distanceKm: number;
  cost: number;
}

export interface Destination {
  code: string;
  name: string;
  cities: { id: number; name: string }[];
}

// fetch resolves dot segments (also percent-encoded ones), so a path built from caller input could otherwise
// climb out of /invoke/<app>/method and reach any sidecar API, such as secrets or publish.
function checkPath(path: string) {
  const segments = path.split('/').map((s) => s.replace(/%2e/gi, '.'));
  if (/[?#\\]/.test(path) || segments.some((s) => s === '.' || s === '..')) throw new Error(`invalid path ${path}`);
}

export async function call<T>(app: string, path: string, init?: RequestInit): Promise<T> {
  checkPath(path);
  const res = await fetch(`${DAPR}/${app}/method/${path}`, {
    cache: 'no-store',
    ...init,
    headers: { 'content-type': 'application/json', ...init?.headers },
  });
  if (!res.ok) throw new Error(`${app} ${path}: ${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}

export interface Review {
  id: number;
  sku: string;
  author: string;
  rating: number;
  body: string;
  created_at: string;
}

export interface ReviewList {
  sku: string;
  count: number;
  average: number | null;
  reviews: Review[];
}

export interface Profile {
  userId: string;
  displayName: string;
  email: string | null;
  defaultCityId: number | null;
}

export class NotSignedInError extends Error {
  constructor() {
    super('not signed in');
  }
}

/** Calls a service that needs the shopper's identity, forwarding their access token through Dapr. */
export async function authedCall<T>(app: string, path: string, init?: RequestInit): Promise<T> {
  const session = await getSession();
  if (!session) throw new NotSignedInError();
  return call<T>(app, path, { ...init, headers: { ...init?.headers, authorization: `Bearer ${session.accessToken}` } });
}

/** The visitor's cart. The proxy issues a fresh id before rendering, so a missing or forged one is a bug. */
export async function cartId(): Promise<string> {
  const id = (await cookies()).get('cart_id')?.value;
  if (!isCartId(id)) throw new Error('missing or invalid cart_id cookie');
  return id;
}

/** Every shipping destination, grouped by country. */
export async function destinations(): Promise<Destination[]> {
  const countries = await call<{ code: string; name: string }[]>('shipping', 'countries');
  return Promise.all(
    countries.map(async (c) => ({ ...c, cities: await call<{ id: number; name: string }[]>('shipping', `cities/${c.code}`) })),
  );
}
