import { call, type Product } from '@/lib/api';
import { Hero3D } from '@/components/Hero3D';
import { Icon } from '@/components/Icon';
import { ProductGrid } from '@/components/ProductGrid';

export const dynamic = 'force-dynamic';

export default async function Home() {
  const products = await call<Product[]>('catalog', 'products');

  return (
    <>
      <section className="hero">
        <div className="hero-copy">
          <p className="eyebrow">Free returns on every bot</p>
          <h1>Robots for every job</h1>
          <p className="lead">
            Pick a helper for the home, the warehouse or the workbench. Tilt any robot to look around it,
            then add it to your cart in one click.
          </p>
          <a href="#shop" className="btn btn-primary btn-lg">
            Browse robots <Icon name="arrowRight" size={18} />
          </a>
        </div>
        <Hero3D />
      </section>
      <ProductGrid products={products} />
    </>
  );
}
