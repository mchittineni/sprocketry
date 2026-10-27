import Link from 'next/link';
import { call, cartId, type Cart, type Destination, type Product } from '@/lib/api';
import { CartView } from '@/components/CartView';
import { Robot } from '@/components/Robot';

export const dynamic = 'force-dynamic';

interface Country { code: string; name: string }
interface City { id: number; name: string }

export default async function CartPage() {
  const cart = await call<Cart>('cart', `cart/${await cartId()}`);

  if (cart.items.length === 0) {
    return (
      <div className="empty-state">
        <div className="float"><Robot category="home" hue={160} size={160} /></div>
        <h1>Your cart is empty</h1>
        <p className="muted">Every robot ships with free returns. Find one that fits the job.</p>
        <Link href="/" className="btn btn-primary btn-lg">Browse robots</Link>
      </div>
    );
  }

  // Shipping destinations and product categories (for the line illustrations) load in parallel.
  const [countries, products] = await Promise.all([
    call<Country[]>('shipping', 'countries'),
    call<Product[]>('catalog', 'products'),
  ]);
  const destinations: Destination[] = await Promise.all(
    countries.map(async (c) => ({ ...c, cities: await call<City[]>('shipping', `cities/${c.code}`) })),
  );
  const categories = Object.fromEntries(products.map((p) => [p.sku, p.category]));

  return <CartView cart={cart} destinations={destinations} categories={categories} />;
}
