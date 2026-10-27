'use client';

import { Robot } from '@/components/Robot';

// Shown when a backend service is unavailable, e.g. while the Dapr sidecars are still starting.
export default function Error({ reset }: { error: Error; reset: () => void }) {
  return (
    <div className="empty-state" role="alert">
      <div className="float tilt-sad"><Robot category="industrial" hue={28} size={150} /></div>
      <h1>Our robots are rebooting</h1>
      <p className="muted">A service didn't answer in time. This usually clears up within a few seconds.</p>
      <button type="button" className="btn btn-primary btn-lg" onClick={reset}>Try again</button>
    </div>
  );
}
