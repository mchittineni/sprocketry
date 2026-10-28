import { redirect } from 'next/navigation';
import { authedCall, destinations as loadDestinations, type Profile } from '@/lib/api';
import { getSession } from '@/lib/auth';
import { AccountForm } from '@/components/AccountForm';

export const dynamic = 'force-dynamic';

export default async function AccountPage() {
  const session = await getSession();
  if (!session) redirect('/auth/login?returnTo=/account');
  const [profile, destinations] = await Promise.all([authedCall<Profile>('profile', 'me'), loadDestinations()]);

  return (
    <div className="account">
      <h1>Your account</h1>
      {profile.email && <p className="muted">Signed in as {profile.email}</p>}
      <AccountForm profile={profile} destinations={destinations} />
    </div>
  );
}
