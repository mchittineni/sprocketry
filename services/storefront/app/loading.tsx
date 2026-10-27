// Skeleton that keeps the layout stable while server data loads.
export default function Loading() {
  return (
    <div aria-busy="true" aria-label="Loading">
      <div className="skeleton skeleton-hero" />
      <ul className="grid">
        {Array.from({ length: 6 }, (_, i) => (
          <li key={i} className="skeleton skeleton-card" />
        ))}
      </ul>
    </div>
  );
}
