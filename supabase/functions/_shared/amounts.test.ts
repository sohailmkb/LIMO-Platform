import { amountDue, feeMinor, fromMinor, isAllowedOrigin, toMinor } from "./amounts.ts";

function eq(actual: unknown, expected: unknown, name: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

Deno.test("minor units", () => {
  eq(toMinor(135.6), 13560, "135.60");
  eq(toMinor(0.1 + 0.2), 30, "float noise");
  eq(fromMinor(13560), 135.6, "back");
});

Deno.test("balance due", () => {
  eq(amountDue("balance", 135.6, 0, 0), 135.6, "unpaid");
  eq(amountDue("balance", 135.6, 40.68, 30), 94.92, "after deposit");
  eq(amountDue("balance", 135.6, 135.6, 0), 0, "paid");
  eq(amountDue("balance", 135.6, 200, 0), 0, "overpaid never negative");
});

Deno.test("deposit due", () => {
  eq(amountDue("deposit", 135.6, 0, 30), 40.68, "30% of 135.60");
  eq(amountDue("deposit", 135.6, 40.68, 30), 0, "deposit already paid");
  eq(amountDue("deposit", 135.6, 0, 0), 0, "no deposit policy");
  eq(amountDue("deposit", 90.4, 0, 25), 22.6, "25% of 90.40");
  eq(amountDue("deposit", 99.99, 0, 33.33), 33.33, "rounded to cents");
});

Deno.test("platform fee", () => {
  eq(feeMinor(13560, 0), 0, "zero");
  eq(feeMinor(13560, 100), 135, "1% rounds down");
  eq(feeMinor(13560, 250), 339, "2.5%");
});

Deno.test("allowed origins", () => {
  const allowed = ["https://app.example.com", "https://id-preview--abc.lovable.app"];
  eq(isAllowedOrigin("https://app.example.com", allowed), true, "exact");
  eq(isAllowedOrigin("https://app.example.com/anything", allowed), true, "path ignored");
  eq(isAllowedOrigin("http://app.example.com", allowed), false, "scheme must match");
  eq(isAllowedOrigin("https://evil.com", allowed), false, "other host");
  eq(isAllowedOrigin("https://app.example.com.evil.com", allowed), false, "suffix trick");
  eq(isAllowedOrigin("not a url", allowed), false, "garbage");
});
