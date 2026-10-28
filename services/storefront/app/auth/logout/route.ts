import { NextResponse } from 'next/server';
import { logout } from '@/lib/auth';

export async function GET() {
  return NextResponse.redirect(await logout());
}
