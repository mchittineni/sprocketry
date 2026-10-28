// Sign-in through Keycloak (OpenID Connect authorization code flow with PKCE). Tokens stay on the server:
// sessions live in the Dapr state store, and the browser holds only a random session id in a cookie.
import * as oidc from 'openid-client';
import { cookies } from 'next/headers';

const DAPR_STATE = `http://localhost:${process.env.DAPR_HTTP_PORT ?? '3500'}/v1.0/state/statestore`;
const SESSION_COOKIE = 'sid';
const LOGIN_COOKIE = 'oidc_login';
const SESSION_TTL_SECONDS = 24 * 60 * 60;
// Refresh this long before the access token expires, so a request never carries one that lapses in flight.
const REFRESH_MARGIN_SECONDS = 30;

export interface Session {
  sub: string;
  name: string;
  email?: string;
  accessToken: string;
  expiresAt: number; // epoch seconds
  refreshToken?: string;
  idToken?: string;
}

/** Sign-in is offered only when the storefront is configured for it. */
export function authEnabled(): boolean {
  return Boolean(process.env.OIDC_DISCOVERY_URL && process.env.OIDC_CLIENT_ID && process.env.STOREFRONT_URL);
}

function publicUrl(path: string): URL {
  return new URL(path, process.env.STOREFRONT_URL);
}

let config: Promise<oidc.Configuration> | undefined;

// Keycloak names its issuer by the address browsers use, while the storefront reaches it on an internal
// one, so openid-client's discovery (which requires the two to match) can't be used. The document is
// fetched directly instead, and the issuer it declares is still checked against every ID token.
function getConfig(): Promise<oidc.Configuration> {
  config ??= (async () => {
    const res = await fetch(`${process.env.OIDC_DISCOVERY_URL}/.well-known/openid-configuration`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`OIDC discovery failed: ${res.status}`);
    const metadata = (await res.json()) as oidc.ServerMetadata;
    const c = new oidc.Configuration(
      metadata,
      process.env.OIDC_CLIENT_ID!,
      undefined,
      oidc.ClientSecretPost(process.env.OIDC_CLIENT_SECRET ?? ''),
    );
    // In-cluster and local traffic to Keycloak is plain HTTP.
    if (metadata.token_endpoint?.startsWith('http:')) oidc.allowInsecureRequests(c);
    return c;
  })().catch((err) => {
    config = undefined; // retry on the next request rather than caching the failure
    throw err;
  });
  return config;
}

/** Only same-site paths, so the login flow can't be used to redirect elsewhere. */
export function safeReturnTo(value: string | null | undefined): string {
  return value && value.startsWith('/') && !value.startsWith('//') && !value.startsWith('/\\') ? value : '/';
}

const secure = () => process.env.STOREFRONT_URL?.startsWith('https:') ?? false;

/** Starts sign-in: remembers the PKCE verifier and state, and returns Keycloak's login URL. */
export async function beginLogin(returnTo: string): Promise<URL> {
  const c = await getConfig();
  const verifier = oidc.randomPKCECodeVerifier();
  const state = oidc.randomState();
  (await cookies()).set(LOGIN_COOKIE, JSON.stringify({ verifier, state, returnTo: safeReturnTo(returnTo) }), {
    httpOnly: true,
    sameSite: 'lax',
    secure: secure(),
    path: '/auth',
    maxAge: 600,
  });
  return oidc.buildAuthorizationUrl(c, {
    redirect_uri: publicUrl('/auth/callback').href,
    scope: 'openid profile email',
    code_challenge: await oidc.calculatePKCECodeChallenge(verifier),
    code_challenge_method: 'S256',
    state,
  });
}

/** Finishes sign-in: exchanges the code, stores the session and returns where to send the shopper. */
export async function completeLogin(search: string): Promise<string> {
  const jar = await cookies();
  const pending = jar.get(LOGIN_COOKIE)?.value;
  jar.delete({ name: LOGIN_COOKIE, path: '/auth' });
  if (!pending) throw new Error('no sign-in in progress');
  const { verifier, state, returnTo } = JSON.parse(pending) as { verifier: string; state: string; returnTo: string };

  // The callback URL must be the public one Keycloak redirected to, not the address this server listens on.
  const tokens = await oidc.authorizationCodeGrant(await getConfig(), publicUrl(`/auth/callback${search}`), {
    pkceCodeVerifier: verifier,
    expectedState: state,
  });
  const sid = crypto.randomUUID() + crypto.randomUUID();
  await saveSession(sid, toSession(tokens));
  jar.set(SESSION_COOKIE, sid, { httpOnly: true, sameSite: 'lax', secure: secure(), path: '/', maxAge: SESSION_TTL_SECONDS });
  return safeReturnTo(returnTo);
}

function toSession(tokens: oidc.TokenEndpointResponse & oidc.TokenEndpointResponseHelpers, previous?: Session): Session {
  const claims = tokens.claims();
  const expiresIn = tokens.expiresIn() ?? 300;
  return {
    sub: claims?.sub ?? previous!.sub,
    name: String(claims?.name ?? claims?.preferred_username ?? previous?.name ?? 'Shopper'),
    email: (claims?.email as string | undefined) ?? previous?.email,
    accessToken: tokens.access_token,
    expiresAt: Math.floor(Date.now() / 1000) + expiresIn,
    refreshToken: tokens.refresh_token ?? previous?.refreshToken,
    idToken: tokens.id_token ?? previous?.idToken,
  };
}

/** The signed-in shopper, refreshing their access token when it is about to expire; null if signed out. */
export async function getSession(): Promise<Session | null> {
  if (!authEnabled()) return null;
  const sid = (await cookies()).get(SESSION_COOKIE)?.value;
  if (!sid) return null;
  const session = await loadSession(sid);
  if (!session) return null;
  if (session.expiresAt - REFRESH_MARGIN_SECONDS > Date.now() / 1000) return session;
  if (!session.refreshToken) return null;
  try {
    const refreshed = toSession(await oidc.refreshTokenGrant(await getConfig(), session.refreshToken), session);
    await saveSession(sid, refreshed);
    return refreshed;
  } catch {
    // The Keycloak session has ended (signed out elsewhere, or idle too long).
    await deleteSession(sid);
    return null;
  }
}

/** Ends the local session and returns Keycloak's logout URL, which ends the Keycloak session too. */
export async function logout(): Promise<URL> {
  const jar = await cookies();
  const sid = jar.get(SESSION_COOKIE)?.value;
  const session = sid ? await loadSession(sid) : null;
  if (sid) await deleteSession(sid);
  jar.delete(SESSION_COOKIE);
  if (!authEnabled()) return publicUrl('/');
  return oidc.buildEndSessionUrl(await getConfig(), {
    post_logout_redirect_uri: publicUrl('/').href,
    ...(session?.idToken ? { id_token_hint: session.idToken } : { client_id: process.env.OIDC_CLIENT_ID! }),
  });
}

async function loadSession(sid: string): Promise<Session | null> {
  const res = await fetch(`${DAPR_STATE}/session-${encodeURIComponent(sid)}`, { cache: 'no-store' });
  // Dapr answers 204 for a key that doesn't exist (or has expired).
  if (res.status === 204) return null;
  if (!res.ok) throw new Error(`session store: ${res.status}`);
  return (await res.json()) as Session;
}

async function saveSession(sid: string, session: Session): Promise<void> {
  const res = await fetch(DAPR_STATE, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify([{ key: `session-${sid}`, value: session, metadata: { ttlInSeconds: String(SESSION_TTL_SECONDS) } }]),
  });
  if (!res.ok) throw new Error(`session store: ${res.status}`);
}

async function deleteSession(sid: string): Promise<void> {
  await fetch(`${DAPR_STATE}/session-${encodeURIComponent(sid)}`, { method: 'DELETE' });
}
