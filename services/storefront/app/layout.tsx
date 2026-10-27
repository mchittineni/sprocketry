import type { ReactNode } from 'react';
import Link from 'next/link';
import { Nunito_Sans, Rubik } from 'next/font/google';
import { call, cartId, type Cart } from '@/lib/api';
import { Icon } from '@/components/Icon';
import { ToastProvider } from '@/components/Toast';
import './globals.css';

const heading = Rubik({ subsets: ['latin'], weight: ['500', '700'], variable: '--font-heading' });
const body = Nunito_Sans({ subsets: ['latin'], variable: '--font-body' });

export const metadata = { title: 'Sprocketry', description: 'Robots for every job' };
export const viewport = { themeColor: '#047857' };

// The header must render even when the cart service is down.
async function cartCount(): Promise<number> {
  try {
    const cart = await call<Cart>('cart', `cart/${await cartId()}`);
    return cart.items.reduce((n, i) => n + i.quantity, 0);
  } catch {
    return 0;
  }
}

export default async function RootLayout({ children }: { children: ReactNode }) {
  const count = await cartCount();
  return (
    <html lang="en" className={`${heading.variable} ${body.variable}`}>
      <body>
        <a href="#main" className="skip-link">Skip to content</a>
        <ToastProvider>
          <header className="site-header">
            <Link href="/" className="brand">
              <span className="brand-mark" aria-hidden="true" />
              Sprocketry
            </Link>
            <Link href="/cart" className="cart-link" aria-label={`Cart, ${count} ${count === 1 ? 'item' : 'items'}`}>
              <Icon name="cart" size={22} />
              <span className="cart-label">Cart</span>
              {count > 0 && <span key={count} className="badge" aria-hidden="true">{count}</span>}
            </Link>
          </header>
          <main id="main">{children}</main>
          <footer className="site-footer muted">
            Sprocketry is a demo shop for practising cloud-native platform engineering. No real robots are sold.
          </footer>
        </ToastProvider>
      </body>
    </html>
  );
}
