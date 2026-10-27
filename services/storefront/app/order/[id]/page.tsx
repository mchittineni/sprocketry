import Link from 'next/link';
import { Icon } from '@/components/Icon';

const gbp = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' });

export default async function OrderPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ total?: string; shipping?: string }>;
}) {
  const { id } = await params;
  const { total, shipping } = await searchParams;

  return (
    <div className="order">
      <div className="parcel" aria-hidden="true">
        <div className="cube">
          <span className="face front" />
          <span className="face back" />
          <span className="face right" />
          <span className="face left" />
          <span className="face top" />
          <span className="face bottom" />
        </div>
      </div>

      <h1>Order placed</h1>
      <p className="lead">Thanks! Your robot is on its way to the warehouse.</p>

      <div className="card receipt">
        <p className="muted">Order number</p>
        <p className="order-id"><code>{id}</code></p>
        {total && (
          <p>
            Charged <strong>{gbp.format(Number(total))}</strong>
            {shipping && <span className="muted">, including {gbp.format(Number(shipping))} shipping</span>}
          </p>
        )}
      </div>

      <ol className="steps" aria-label="Order progress">
        <li className="done"><Icon name="check" size={16} /> Paid</li>
        <li className="active"><Icon name="truck" size={16} /> Dispatching</li>
        <li>Delivered</li>
      </ol>

      <Link href="/" className="btn btn-primary btn-lg">Keep shopping</Link>
    </div>
  );
}
