'use client';

import Link from 'next/link';
import { useActionState, useState, useTransition } from 'react';
import { checkout, getQuote, setQuantity, type CheckoutState } from '@/app/actions';
import type { Cart, Destination, Quote } from '@/lib/api';
import { Icon } from './Icon';
import { Robot, hueFor } from './Robot';
import { useToast } from './Toast';

const gbp = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' });

export function CartView({
  cart,
  destinations,
  categories,
}: {
  cart: Cart;
  destinations: Destination[];
  categories: Record<string, string>;
}) {
  const [state, action, paying] = useActionState<CheckoutState, FormData>(checkout, {});
  const [, startPay] = useTransition();
  const [city, setCity] = useState('');
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoting, startQuote] = useTransition();
  const count = cart.items.reduce((n, i) => n + i.quantity, 0);

  function onCity(id: string) {
    setCity(id);
    setQuote(null);
    if (!id) return;
    startQuote(async () => setQuote(await getQuote(Number(id))));
  }

  return (
    <div className="cart-layout">
      <section aria-labelledby="items-heading">
        <h1 id="items-heading">
          Your cart <span className="muted">({count} {count === 1 ? 'item' : 'items'})</span>
        </h1>
        <ul className="lines">
          {cart.items.map((item) => (
            <CartLine key={item.sku} item={item} category={categories[item.sku] ?? 'home'} />
          ))}
        </ul>
        <Link href="/" className="back-link">
          <Icon name="arrowLeft" size={18} /> Keep shopping
        </Link>
      </section>

      <aside className="card summary" aria-labelledby="summary-heading">
        <h2 id="summary-heading">Order summary</h2>
        {/* Submitted from onSubmit rather than <form action>, because React resets a form after its
            action runs. That would clear the chosen city (but not its quote) when a payment is declined. */}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            const data = new FormData(e.currentTarget);
            startPay(() => action(data));
          }}
        >
          <label htmlFor="city" className="field-label">Ship to</label>
          <select id="city" name="city" required value={city} onChange={(e) => onCity(e.target.value)}>
            <option value="" disabled>Choose a city</option>
            {destinations.map((d) => (
              <optgroup key={d.code} label={d.name}>
                {d.cities.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </optgroup>
            ))}
          </select>

          <dl className="totals">
            <div><dt>Subtotal</dt><dd>{gbp.format(cart.total)}</dd></div>
            <div>
              <dt>Shipping</dt>
              <dd aria-live="polite">
                {quoting ? <span className="muted">Calculating…</span>
                  : quote ? gbp.format(quote.cost)
                  : <span className="muted">Choose a city</span>}
              </dd>
            </div>
            {quote && (
              <p className="muted quote-note">
                <Icon name="truck" size={16} /> {quote.distanceKm.toLocaleString('en-GB')} km to {quote.city}
              </p>
            )}
            <div className="grand"><dt>Total</dt><dd>{gbp.format(cart.total + (quote?.cost ?? 0))}</dd></div>
          </dl>

          {state.error && (
            <p className="alert" role="alert">
              <Icon name="alert" size={18} /> {state.error}
            </p>
          )}
          <button className="btn btn-primary btn-block" disabled={paying}>
            {paying ? <><span className="spinner" aria-hidden="true" /> Processing payment</> : 'Pay now'}
          </button>
        </form>
      </aside>
    </div>
  );
}

function CartLine({ item, category }: { item: Cart['items'][number]; category: string }) {
  const [pending, start] = useTransition();
  const toast = useToast();

  function update(quantity: number) {
    start(async () => {
      const result = await setQuantity(item.sku, quantity);
      if (!result.ok || quantity === 0) toast(result.ok, result.ok ? `${item.name} removed` : result.message);
    });
  }

  return (
    <li className={`card line ${pending ? 'is-pending' : ''}`}>
      <div className="line-art"><Robot category={category} hue={hueFor(item.sku, category)} size={72} /></div>
      <div className="line-info">
        <h3>{item.name}</h3>
        <p className="muted">{gbp.format(item.price)} each</p>
      </div>
      <div className="stepper" role="group" aria-label={`Quantity of ${item.name}`}>
        <button type="button" onClick={() => update(item.quantity - 1)} disabled={pending} aria-label="Decrease quantity">
          <Icon name="minus" size={16} />
        </button>
        <output aria-live="polite">{item.quantity}</output>
        <button type="button" onClick={() => update(item.quantity + 1)} disabled={pending} aria-label="Increase quantity">
          <Icon name="plus" size={16} />
        </button>
      </div>
      <p className="line-total">{gbp.format(item.price * item.quantity)}</p>
      <button type="button" className="icon-btn" onClick={() => update(0)} disabled={pending} aria-label={`Remove ${item.name}`}>
        <Icon name="trash" size={18} />
      </button>
    </li>
  );
}
