'use client';

import { useActionState } from 'react';
import { saveProfile, type FormState } from '@/app/actions';
import type { Destination, Profile } from '@/lib/api';

export function AccountForm({ profile, destinations }: { profile: Profile; destinations: Destination[] }) {
  const [state, action, pending] = useActionState<FormState, FormData>(saveProfile, {});
  return (
    <form action={action} className="card form-card">
      <label className="field-label" htmlFor="displayName">Name</label>
      <input id="displayName" name="displayName" type="text" required maxLength={60} defaultValue={profile.displayName} />
      <label className="field-label" htmlFor="city">Default shipping city</label>
      <select id="city" name="city" defaultValue={profile.defaultCityId ?? ''}>
        <option value="">None: choose at checkout</option>
        {destinations.map((d) => (
          <optgroup key={d.code} label={d.name}>
            {d.cities.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </optgroup>
        ))}
      </select>
      {state.message && <p className={state.ok ? 'notice' : 'alert'} role={state.ok ? 'status' : 'alert'}>{state.message}</p>}
      <button className="btn btn-primary" disabled={pending}>{pending ? 'Saving…' : 'Save'}</button>
    </form>
  );
}
