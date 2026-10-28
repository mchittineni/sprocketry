import Link from 'next/link';
import { authedCall, call, cartId, destinations as loadDestinations, type Cart, type Profile, type Product, type Quote } from '@/lib/api';
import { getSession } from '@/lib/auth';
import { CartView } from '@/components/CartView';
import { Robot } from '@/components/Robot';

export const dynamic = 'force-dynamic';

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

  // Shipping destinations, product categories (for the line illustrations) and, for a signed-in shopper,
  // their default city all load in parallel. The default city is a convenience, so a failure is ignored.
  const [destinations, products, defaultCityId] = await Promise.all([
    loadDestinations(),
    call<Product[]>('catalog', 'products'),
    defaultCity(),
  ]);
  const categories = Object.fromEntries(products.map((p) => [p.sku, p.category]));
  const initialQuote = defaultCityId ? await call<Quote>('shipping', `quote/${defaultCityId}`).catch(() => null) : null;

  return (
    <CartView
      cart={cart}
      destinations={destinations}
      categories={categories}
      defaultCityId={initialQuote ? defaultCityId : null}
      initialQuote={initialQuote}
    />
  );
}

async function defaultCity(): Promise<number | null> {
  try {
    if (!(await getSession())) return null;
    return (await authedCall<Profile>('profile', 'me')).defaultCityId;
  } catch {
    return null;
  }
}
