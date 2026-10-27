import { revalidatePath } from 'next/cache';
import { call, cartId, type Product } from '@/lib/api';

export const dynamic = 'force-dynamic';

async function addToCart(formData: FormData) {
  'use server';
  const id = await cartId();
  await call(`cart`, `cart/${id}/items`, {
    method: 'POST',
    body: JSON.stringify({ sku: formData.get('sku'), quantity: 1 }),
  });
  revalidatePath('/cart');
}

export default async function Home() {
  const products = await call<Product[]>('catalog', 'products');

  return (
    <>
      <h1>Robots for every job</h1>
      <div className="grid">
        {products.map((p) => (
          <form key={p.sku} action={addToCart} className="card">
            <h3>{p.name}</h3>
            <p className="muted">{p.description}</p>
            <p>£{Number(p.price).toFixed(2)}</p>
            <input type="hidden" name="sku" value={p.sku} />
            <button disabled={p.stock === 0}>{p.stock === 0 ? 'Out of stock' : 'Add to cart'}</button>
          </form>
        ))}
      </div>
    </>
  );
}
