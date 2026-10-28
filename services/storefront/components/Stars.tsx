// A 1-5 star rating, with the number for screen readers.
export function Stars({ rating }: { rating: number }) {
  const full = Math.round(rating);
  return (
    <span className="stars" role="img" aria-label={`${rating} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((i) => (
        <span key={i} className={i <= full ? undefined : 'off'} aria-hidden="true">★</span>
      ))}
    </span>
  );
}
