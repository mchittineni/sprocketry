'use client';

import { useActionState } from 'react';
import { postReview, type FormState } from '@/app/actions';

export function ReviewForm({ sku }: { sku: string }) {
  const [state, action, pending] = useActionState<FormState, FormData>(postReview.bind(null, sku), {});
  if (state.ok) return <p className="notice" role="status">{state.message}</p>;
  return (
    <form action={action} className="card form-card" aria-labelledby="write-review">
      <h3 id="write-review">Write a review</h3>
      <fieldset className="rating-input">
        <legend>Rating</legend>
        {[1, 2, 3, 4, 5].map((n) => (
          <label key={n}>
            <input type="radio" name="rating" value={n} required defaultChecked={n === 5} />
            <span>{n}★</span>
          </label>
        ))}
      </fieldset>
      <label className="field-label" htmlFor="review-body">Your review</label>
      <textarea id="review-body" name="body" required maxLength={2000} placeholder="What does it do well? What could be better?" />
      {state.message && <p className="alert" role="alert">{state.message}</p>}
      <button className="btn btn-primary" disabled={pending}>{pending ? 'Posting…' : 'Post review'}</button>
    </form>
  );
}
