export default async function OrderPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ total?: string }>;
}) {
  const { id } = await params;
  const { total } = await searchParams;
  return (
    <>
      <h1>Order placed</h1>
      <p>Order <code>{id}</code> is on its way to the warehouse.</p>
      {total && <p>Charged £{Number(total).toFixed(2)} including shipping.</p>}
    </>
  );
}
