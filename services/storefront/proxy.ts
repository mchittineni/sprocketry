import { NextResponse, type NextRequest } from 'next/server';
import { isCartId } from '@/lib/cart-id';

// Pages that need a signed-in shopper. Checked here, before rendering, so a signed-out visitor gets a real
// redirect: once a page starts streaming, Next.js can only redirect in the browser.
const SIGNED_IN = ['/account'];

export function proxy(req: NextRequest) {
  if (SIGNED_IN.some((p) => req.nextUrl.pathname.startsWith(p)) && !req.cookies.has('sid')) {
    const login = new URL('/auth/login', process.env.STOREFRONT_URL ?? req.url);
    login.searchParams.set('returnTo', req.nextUrl.pathname);
    return NextResponse.redirect(login);
  }
  // Gives every visitor a cart id cookie, replacing one that isn't a UUID, since it ends up in backend paths.
  if (isCartId(req.cookies.get('cart_id')?.value)) return NextResponse.next();
  const id = crypto.randomUUID();
  // Set it on the request too, so this first render already sees the visitor's own cart.
  req.cookies.set('cart_id', id);
  const res = NextResponse.next({ request: { headers: req.headers } });
  res.cookies.set('cart_id', id, {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.STOREFRONT_URL?.startsWith('https:') ?? false,
    path: '/',
  });
  return res;
}

export const config = { matcher: ['/((?!_next|favicon.ico|api/healthz).*)'] };
