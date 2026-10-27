// Every backend call goes through the Dapr sidecar's service invocation API,
// so the storefront never needs to know where other services run.
import { cookies } from 'next/headers';

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

export async function call<T>(app: string, path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${DAPR}/${app}/method/${path}`, {
    cache: 'no-store',
    ...init,
    headers: { 'content-type': 'application/json', ...init?.headers },
  });
  if (!res.ok) throw new Error(`${app} ${path}: ${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}

export async function cartId(): Promise<string> {
  const jar = await cookies();
  return jar.get('cart_id')?.value ?? 'anonymous';
}
