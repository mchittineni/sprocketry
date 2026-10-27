import { redirect } from 'next/navigation';
import { call, cartId, type Cart, type Order } from '@/lib/api';

export const dynamic = 'force-dynamic';

interface Country { code: string; name: string }
interface City { id: number; name: string }

async function checkout(formData: FormData) {
  'use server';
  const id = await cartId();
  const order = await call<Order>('payment', `pay/${id}`, {
    method: 'POST',
    body: JSON.stringify({ user_id: id, city_id: Number(formData.get('city')) }),
  });
  redirect(`/order/${order.order_id}?total=${order.total}`);
}

export default async function CartPage() {
  const cart = await call<Cart>('cart', `cart/${await cartId()}`);
  const countries = await call<Country[]>('shipping', 'countries');
  const cities = await Promise.all(
    countries.map(async (c) => ({ ...c, cities: await call<City[]>('shipping', `cities/${c.code}`) })),
  );

  if (cart.items.length === 0) return <p>Your cart is empty.</p>;

  return (
    <>
      <h1>Cart</h1>
      <table>
        <thead><tr><th>Item</th><th>Qty</th><th>Price</th></tr></thead>
        <tbody>
          {cart.items.map((i) => (
            <tr key={i.sku}><td>{i.name}</td><td>{i.quantity}</td><td>£{(i.price * i.quantity).toFixed(2)}</td></tr>
          ))}
        </tbody>
      </table>
      <p><strong>Subtotal: £{cart.total.toFixed(2)}</strong> <span className="muted">(shipping added at checkout)</span></p>
      <form action={checkout}>
        <label>
          Ship to{' '}
          <select name="city" required>
            {cities.map((c) => (
              <optgroup key={c.code} label={c.name}>
                {c.cities.map((city) => <option key={city.id} value={city.id}>{city.name}</option>)}
              </optgroup>
            ))}
          </select>
        </label>{' '}
        <button>Pay now</button>
      </form>
    </>
  );
}
