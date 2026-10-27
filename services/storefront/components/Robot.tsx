// Illustrations of each product category, tinted per product so every card looks distinct.
// Pure SVG: no image requests, crisp at any size, and themable through CSS variables.

const HUES: Record<string, number> = { home: 160, industrial: 28, logistics: 205, maker: 265 };

export function hueFor(sku: string, category: string): number {
  const base = HUES[category] ?? 180;
  let h = 0;
  for (const c of sku) h = (h * 31 + c.charCodeAt(0)) % 360;
  return (base + (h % 30) - 15 + 360) % 360;
}

export function Robot({ category, hue, size = 140 }: { category: string; hue: number; size?: number }) {
  const body = `hsl(${hue} 70% 55%)`;
  const dark = `hsl(${hue} 55% 32%)`;
  const light = `hsl(${hue} 85% 78%)`;
  const eye = 'hsl(190 100% 70%)';

  return (
    <svg width={size} height={size} viewBox="0 0 120 120" aria-hidden="true" focusable="false" className="robot">
      <defs>
        <linearGradient id={`g${hue}`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor={light} />
          <stop offset="1" stopColor={body} />
        </linearGradient>
      </defs>
      {category === 'logistics' ? (
        // Courier drone: four rotors around a parcel pod.
        <g>
          {[22, 98].map((x) => (
            <g key={x}>
              <rect x={x - 3} y="36" width="6" height="14" rx="2" fill={dark} />
              <ellipse className="rotor" cx={x} cy="34" rx="18" ry="4" fill={light} opacity="0.85" />
            </g>
          ))}
          <rect x="22" y="44" width="76" height="10" rx="5" fill={dark} />
          <rect x="34" y="40" width="52" height="34" rx="14" fill={`url(#g${hue})`} />
          <circle cx="50" cy="56" r="5" fill={eye} />
          <circle cx="70" cy="56" r="5" fill={eye} />
          <rect x="44" y="80" width="32" height="24" rx="4" fill="hsl(35 60% 60%)" />
          <path d="M44 88h32M60 80v24" stroke="hsl(35 50% 40%)" strokeWidth="2" />
          <path d="M52 74v6M68 74v6" stroke={dark} strokeWidth="3" />
        </g>
      ) : category === 'maker' ? (
        // Desktop arm: base, two links and a gripper.
        <g>
          <rect x="30" y="94" width="60" height="14" rx="5" fill={dark} />
          <rect x="44" y="84" width="32" height="14" rx="5" fill={`url(#g${hue})`} />
          <rect x="54" y="48" width="12" height="40" rx="6" fill={body} transform="rotate(-18 60 86)" />
          <circle cx="72" cy="50" r="8" fill={dark} />
          <rect x="66" y="22" width="12" height="34" rx="6" fill={`url(#g${hue})`} transform="rotate(48 72 50)" />
          <circle cx="94" cy="32" r="6" fill={dark} />
          <path d="M96 26l10-6M98 36l10 4" stroke={dark} strokeWidth="5" strokeLinecap="round" />
          <circle cx="60" cy="86" r="5" fill={eye} />
        </g>
      ) : category === 'industrial' ? (
        // Heavy bot: boxy body on treads.
        <g>
          <rect x="16" y="88" width="88" height="20" rx="10" fill={dark} />
          {[28, 46, 64, 82, 94].map((x) => <circle key={x} cx={x} cy="98" r="5" fill={light} />)}
          <rect x="24" y="38" width="72" height="52" rx="8" fill={`url(#g${hue})`} />
          <rect x="34" y="48" width="52" height="20" rx="6" fill={dark} />
          <rect x="42" y="54" width="12" height="8" rx="2" fill={eye} />
          <rect x="66" y="54" width="12" height="8" rx="2" fill={eye} />
          <rect x="40" y="74" width="40" height="6" rx="3" fill={dark} opacity="0.5" />
          <rect x="54" y="20" width="12" height="18" rx="3" fill={dark} />
          <circle cx="60" cy="18" r="6" fill="hsl(25 95% 55%)" />
        </g>
      ) : (
        // Home helper: friendly round body with an antenna.
        <g>
          <ellipse cx="60" cy="104" rx="30" ry="6" fill={dark} opacity="0.35" />
          <rect x="30" y="58" width="60" height="44" rx="22" fill={`url(#g${hue})`} />
          <circle cx="60" cy="42" r="26" fill={`url(#g${hue})`} />
          <rect x="40" y="32" width="40" height="22" rx="11" fill={dark} />
          <circle cx="51" cy="43" r="5" fill={eye} />
          <circle cx="69" cy="43" r="5" fill={eye} />
          <path d="M60 16V8" stroke={dark} strokeWidth="3" strokeLinecap="round" />
          <circle cx="60" cy="7" r="4" fill="hsl(25 95% 55%)" />
          <rect x="18" y="64" width="12" height="26" rx="6" fill={body} />
          <rect x="90" y="64" width="12" height="26" rx="6" fill={body} />
          <circle cx="60" cy="80" r="7" fill={light} />
        </g>
      )}
    </svg>
  );
}
