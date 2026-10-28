import Link from 'next/link';
import { notFound } from 'next/navigation';
import { call, type Product, type ReviewList } from '@/lib/api';
import { authEnabled, getSession } from '@/lib/auth';
import { AddButton } from '@/components/ProductGrid';
import { ReviewForm } from '@/components/ReviewForm';
import { Robot, hueFor } from '@/components/Robot';
import { Stars } from '@/components/Stars';

export const dynamic = 'force-dynamic';

const gbp = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' });
const date = new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium' });

export default async function ProductPage({ params }: { params: Promise<{ sku: string }> }) {
  const { sku } = await params;
  const product = await call<Product>('catalog', `products/${encodeURIComponent(sku)}`).catch((err: Error) => {
    if (err.message.includes(': 404 ')) notFound();
    throw err;
  });
  // The page still sells the robot when the reviews service is down.
  const [reviews, session] = await Promise.all([
    call<ReviewList>('reviews', `products/${encodeURIComponent(sku)}/reviews`).catch(() => null),
    getSession().catch(() => null),
  ]);
  const hue = hueFor(product.sku, product.category);

  return (
    <>
      <div className="product-page">
        <div className="card product-hero"><Robot category={product.category} hue={hue} size={220} /></div>
        <div className="product-detail">
          <span className="tag">{product.category}</span>
          <h1>{product.name}</h1>
          {reviews && reviews.count > 0 && reviews.average !== null && (
            <p className="rating-summary">
              <Stars rating={reviews.average} />
              <span className="muted">{reviews.average} from {reviews.count} {reviews.count === 1 ? 'review' : 'reviews'}</span>
            </p>
          )}
          <p className="lead">{product.description}</p>
          <div className="product-foot">
            <span className="price">{gbp.format(product.price)}</span>
            <AddButton sku={product.sku} name={product.name} disabled={product.stock === 0} />
          </div>
        </div>
      </div>

      <section className="reviews" aria-labelledby="reviews-heading">
        <h2 id="reviews-heading">Reviews</h2>
        {!reviews ? (
          <p className="muted">Reviews are unavailable right now.</p>
        ) : reviews.count === 0 ? (
          <p className="muted">No reviews yet.</p>
        ) : (
          reviews.reviews.map((r) => (
            <article key={r.id} className="card review">
              <header>
                <strong>{r.author}</strong>
                <span><Stars rating={r.rating} /> <span className="muted">{date.format(new Date(r.created_at))}</span></span>
              </header>
              <p>{r.body}</p>
            </article>
          ))
        )}
        {authEnabled() && (session ? (
          <ReviewForm sku={product.sku} />
        ) : (
          <p><a href={`/auth/login?returnTo=${encodeURIComponent(`/products/${product.sku}`)}`}>Sign in</a> to write a review.</p>
        ))}
        <Link href="/" className="back-link">Keep shopping</Link>
      </section>
    </>
  );
}
