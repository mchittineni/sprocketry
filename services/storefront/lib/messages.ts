// Turns a failed backend call into a message a shopper can act on.
export function reason(err: unknown): string {
  const text = err instanceof Error ? err.message : String(err);
  const left = /only (\d+) in stock/.exec(text);
  if (left) return `Sorry, only ${left[1]} left in stock.`;
  if (text.includes('out of stock')) return 'Sorry, that robot just sold out.';
  return 'Something went wrong. Please try again.';
}
