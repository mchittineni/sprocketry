import { NextResponse, type NextRequest } from 'next/server';
import { authEnabled, beginLogin } from '@/lib/auth';

export async function GET(req: NextRequest) {
  if (!authEnabled()) return new NextResponse('Sign-in is not configured', { status: 404 });
  return NextResponse.redirect(await beginLogin(req.nextUrl.searchParams.get('returnTo') ?? '/'));
}
