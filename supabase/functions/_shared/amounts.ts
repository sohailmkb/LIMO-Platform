// Pure money and URL helpers, unit-tested in tests/functions.
// All supported currencies (USD, CAD, GBP, EUR) use 2 decimal places.

export type PaymentKind = "deposit" | "balance";

/** Major units (135.60) to Stripe minor units (13560). */
export function toMinor(amount: number): number {
  return Math.round(amount * 100);
}

/** Minor units back to major units with 2 decimals. */
export function fromMinor(minor: number): number {
  return Math.round(minor) / 100;
}

/** Platform fee in minor units, rounded down so the operator never pays more than the stated rate. */
export function feeMinor(minor: number, bps: number): number {
  if (bps <= 0) return 0;
  return Math.floor((minor * bps) / 10000);
}

/** Amount to charge now, in major units, never negative. */
export function amountDue(kind: PaymentKind, total: number, paid: number, depositPercent: number): number {
  const t = Number(total), p = Number(paid);
  if (kind === "deposit") {
    const deposit = Math.round(t * Number(depositPercent)) / 100; // total * pct / 100, to cents
    return Math.max(fromMinor(toMinor(deposit) - toMinor(p)), 0);
  }
  return Math.max(fromMinor(toMinor(t) - toMinor(p)), 0);
}

/** Only redirect back to our own sites. Compares scheme and host exactly. */
export function isAllowedOrigin(origin: string, allowed: string[]): boolean {
  let o: URL;
  try { o = new URL(origin); } catch { return false; }
  return allowed.some((a) => {
    try {
      const u = new URL(a.trim());
      return u.protocol === o.protocol && u.host === o.host;
    } catch { return false; }
  });
}
