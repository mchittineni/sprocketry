import { NextResponse, type NextRequest } from 'next/server';

// Pages that need a signed-in shopper. Checked here, before rendering, so a signed-out visitor gets a real
// redirect: once a page starts streaming, Next.js can only redirect in the browser.
const SIGNED_IN = ['/account'];

export function proxy(req: NextRequest) {
  if (SIGNED_IN.some((p) => req.nextUrl.pathname.startsWith(p)) && !req.cookies.has('sid')) {
    const login = new URL('/auth/login', process.env.STOREFRONT_URL ?? req.url);
    login.searchParams.set('returnTo', req.nextUrl.pathname);
    return NextResponse.redirect(login);
  }
  // Gives every visitor a cart id cookie on first request.
  const res = NextResponse.next();
  if (!req.cookies.has('cart_id')) {
    res.cookies.set('cart_id', crypto.randomUUID(), { httpOnly: true, sameSite: 'lax', path: '/' });
  }
  return res;
}

export const config = { matcher: ['/((?!_next|favicon.ico|api/healthz).*)'] };
