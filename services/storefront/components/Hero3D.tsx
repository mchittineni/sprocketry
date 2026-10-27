'use client';

import { useRef, type PointerEvent } from 'react';
import { Robot } from './Robot';

// A small 3D stage: a grid floor in perspective, three robots on a turntable,
// and a scene that leans toward the pointer.
export function Hero3D() {
  const ref = useRef<HTMLDivElement>(null);

  function onMove(e: PointerEvent<HTMLDivElement>) {
    if (e.pointerType !== 'mouse' || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    ref.current.style.setProperty('--px', String((e.clientX - r.left) / r.width - 0.5));
    ref.current.style.setProperty('--py', String((e.clientY - r.top) / r.height - 0.5));
  }

  return (
    <div className="stage" ref={ref} onPointerMove={onMove} aria-hidden="true">
      <div className="scene">
        <div className="floor" />
        <div className="turntable">
          <div className="pod pod-1"><Robot category="home" hue={160} size={150} /></div>
          <div className="pod pod-2"><Robot category="logistics" hue={205} size={120} /></div>
          <div className="pod pod-3"><Robot category="industrial" hue={28} size={120} /></div>
        </div>
      </div>
    </div>
  );
}
