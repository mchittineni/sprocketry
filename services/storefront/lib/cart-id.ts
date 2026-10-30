// Kept apart from api.ts so the proxy can use it without loading the session code.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Cart ids end up in backend paths, so only the UUIDs the proxy issues are accepted. */
export function isCartId(value: string | undefined): value is string {
  return value !== undefined && UUID.test(value);
}
