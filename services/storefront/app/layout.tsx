import type { ReactNode } from 'react';
import Link from 'next/link';
import './globals.css';

export const metadata = { title: 'Sprocketry', description: 'Cloud-native polyglot demo shop' };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <header>
          <Link href="/" className="brand">Sprocketry</Link>
          <Link href="/cart">Cart</Link>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
