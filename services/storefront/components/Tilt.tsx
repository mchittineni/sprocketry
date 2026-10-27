'use client';

import { useRef, type ReactNode, type PointerEvent } from 'react';

// Tilts its contents toward the pointer in 3D. Children opt into depth with the
// .depth-1/.depth-2/.depth-3 classes (translateZ). Reduced motion turns the tilt off in CSS.
export function Tilt({ children, className = '', max = 10 }: { children: ReactNode; className?: string; max?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const frame = useRef(0);

  function onMove(e: PointerEvent<HTMLDivElement>) {
    if (e.pointerType !== 'mouse') return; // touch scrolls; don't fight it
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width;
    const y = (e.clientY - r.top) / r.height;
    cancelAnimationFrame(frame.current);
    frame.current = requestAnimationFrame(() => {
      el.style.setProperty('--rx', `${(0.5 - y) * max}deg`);
      el.style.setProperty('--ry', `${(x - 0.5) * max}deg`);
      el.style.setProperty('--gx', `${x * 100}%`);
      el.style.setProperty('--gy', `${y * 100}%`);
    });
  }

  function onLeave() {
    cancelAnimationFrame(frame.current);
    const el = ref.current;
    if (!el) return;
    el.style.setProperty('--rx', '0deg');
    el.style.setProperty('--ry', '0deg');
  }

  return (
    <div className={`tilt ${className}`} onPointerMove={onMove} onPointerLeave={onLeave}>
      <div ref={ref} className="tilt-inner">
        {children}
        <span className="glare" aria-hidden="true" />
      </div>
    </div>
  );
}
