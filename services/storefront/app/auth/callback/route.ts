import { NextResponse, type NextRequest } from 'next/server';
import { completeLogin } from '@/lib/auth';

export async function GET(req: NextRequest) {
  const home = new URL('/', process.env.STOREFRONT_URL);
  try {
    return NextResponse.redirect(new URL(await completeLogin(req.nextUrl.search), process.env.STOREFRONT_URL));
  } catch (err) {
    // A stale or replayed callback, or the shopper cancelled on Keycloak's page.
    console.error('sign-in failed', err);
    home.searchParams.set('signin', 'failed');
    return NextResponse.redirect(home);
  }
}
