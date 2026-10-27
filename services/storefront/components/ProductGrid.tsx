'use client';

import { useMemo, useState, useTransition, type CSSProperties } from 'react';
import { addToCart } from '@/app/actions';
import type { Product } from '@/lib/api';
import { Icon } from './Icon';
import { Robot, hueFor } from './Robot';
import { Tilt } from './Tilt';
import { useToast } from './Toast';

const gbp = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' });

export function ProductGrid({ products }: { products: Product[] }) {
  const [category, setCategory] = useState('all');
  const [query, setQuery] = useState('');
  const categories = useMemo(() => ['all', ...new Set(products.map((p) => p.category))].sort(), [products]);

  const shown = products.filter(
    (p) =>
      (category === 'all' || p.category === category) &&
      `${p.name} ${p.description}`.toLowerCase().includes(query.trim().toLowerCase()),
  );

  return (
    <section id="shop" aria-labelledby="shop-heading">
      <div className="toolbar">
        <h2 id="shop-heading">Shop robots</h2>
        <label className="search">
          <span className="sr-only">Search robots</span>
          <Icon name="search" size={18} />
          <input type="search" placeholder="Search robots" value={query} onChange={(e) => setQuery(e.target.value)} />
        </label>
      </div>

      <div className="chips" role="group" aria-label="Filter by category">
        {categories.map((c) => (
          <button key={c} type="button" className="chip" aria-pressed={category === c} onClick={() => setCategory(c)}>
            {c === 'all' ? 'All' : c[0].toUpperCase() + c.slice(1)}
          </button>
        ))}
      </div>

      <p className="muted result-count" aria-live="polite">
        {shown.length} {shown.length === 1 ? 'robot' : 'robots'}
      </p>

      {shown.length === 0 ? (
        <div className="empty">
          <p>No robots match your filters.</p>
          <button type="button" className="btn btn-ghost" onClick={() => { setQuery(''); setCategory('all'); }}>
            Clear filters
          </button>
        </div>
      ) : (
        <ul className="grid">
          {shown.map((p, i) => (
            <li key={p.sku} style={{ '--i': i } as CSSProperties} className="grid-item">
              <ProductCard product={p} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function ProductCard({ product: p }: { product: Product }) {
  const hue = hueFor(p.sku, p.category);
  const soldOut = p.stock === 0;
  return (
    <Tilt className="product">
      <div className="art depth-3" style={{ '--hue': hue } as CSSProperties}>
        <Robot category={p.category} hue={hue} />
      </div>
      <div className="depth-1 product-body">
        <div className="product-meta">
          <span className="tag">{p.category}</span>
          {soldOut ? (
            <span className="stock stock-out">Sold out</span>
          ) : p.stock <= 10 ? (
            <span className="stock stock-low">Only {p.stock} left</span>
          ) : (
            <span className="stock">In stock</span>
          )}
        </div>
        <h3>{p.name}</h3>
        <p className="muted">{p.description}</p>
      </div>
      <div className="product-foot depth-2">
        <span className="price">{gbp.format(p.price)}</span>
        <AddButton sku={p.sku} name={p.name} disabled={soldOut} />
      </div>
    </Tilt>
  );
}

function AddButton({ sku, name, disabled }: { sku: string; name: string; disabled: boolean }) {
  const [pending, start] = useTransition();
  const [added, setAdded] = useState(false);
  const toast = useToast();

  function add() {
    start(async () => {
      const result = await addToCart(sku, name);
      toast(result.ok, result.message);
      if (result.ok) {
        setAdded(true);
        setTimeout(() => setAdded(false), 1500);
      }
    });
  }

  if (disabled) {
    return <button type="button" className="btn" disabled>Sold out</button>;
  }
  return (
    <button type="button" className="btn btn-primary" onClick={add} disabled={pending} aria-label={`Add ${name} to cart`}>
      {pending ? <span className="spinner" aria-hidden="true" /> : <Icon name={added ? 'check' : 'plus'} size={18} />}
      {pending ? 'Adding' : added ? 'Added' : 'Add'}
    </button>
  );
}
