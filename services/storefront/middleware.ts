import { NextResponse, type NextRequest } from 'next/server';

// Gives every visitor a cart id cookie on first request.
export function middleware(req: NextRequest) {
  const res = NextResponse.next();
  if (!req.cookies.has('cart_id')) {
    res.cookies.set('cart_id', crypto.randomUUID(), { httpOnly: true, sameSite: 'lax', path: '/' });
  }
  return res;
}

export const config = { matcher: ['/((?!_next|favicon.ico|api/healthz).*)'] };
