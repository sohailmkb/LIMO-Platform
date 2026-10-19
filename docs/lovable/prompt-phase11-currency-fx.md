# Lovable prompt: Phase 11, currency and FX

Before pasting: run `supabase/migrations/0015_currency_fx.sql` in the Supabase SQL Editor. Paste after Phase 10 has finished. Normal mode, one message.

---

```
Build all 5 items below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, pick the simplest option that fits the existing code and log it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or database functions. All of it exists (migration 0015). Conversion math happens only through to_usd(); never compute an FX amount in the browser.
- Touch only the files named here plus new files. No reformatting or refactoring elsewhere.
- Reuse: primitives.tsx, states.tsx, useFormat, friendlyError, useT.
- All new text through useT() in BOTH en.json and fr.json. Proper French. No em dashes.
- No screenshots while working. At the end run the type check and vitest once, fix failures, stop.

CONTEXT: each operator and travel agency keeps pricing and invoicing in its own currency (default_currency) — that is unchanged and correct. This phase adds a platform-wide USD view on top of it for comparing across companies, a way to fix a company's currency after signup, and a real bug fix: a farmed-out trip's price was rendered in whoever was looking at it's own currency, not the currency it was actually priced in.

1. REFERENCE DATA: EXCHANGE RATES (src/routes/_authenticated/platform/reference.tsx)
- Add a fourth tab "Exchange rates" next to Currencies / Languages / Tax presets, same Tabs pattern already on this page.
- List every row from `fx_rates` (currency_code, rate_to_usd, updated_at): code, current rate, last updated. USD shows "1.00 (fixed)" and has no edit control — every other currency gets an inline edit (pencil icon opens a small dialog with one numeric field, decimals allowed, must be positive) calling `set_fx_rate(p_currency, p_rate)`.
- A one-line hint under the tab title: "Used to show a combined USD total across companies. Update these as rates move — nothing here is live."

2. PLATFORM OVERVIEW: COMBINED USD TOTAL (src/routes/_authenticated/platform/index.tsx)
- `platform_overview()` now also returns `booking_value_30d_usd` (a plain number) alongside the existing `booking_value_30d` (the per-currency breakdown, already rendered — leave that exactly as is). Add one more tile in the same "Value last 30 days" section: a combined total labelled "All companies (USD)", `f.money(value, "USD")`, visually distinct (e.g. a top border or slightly larger) from the per-currency tiles since it's a derived total, not a real booking currency.

3. PLATFORM COMPANIES: USD REVENUE COLUMN (src/routes/_authenticated/platform/companies/index.tsx)
- `platform_companies()` rows now include `revenue_30d_usd` (a number). Add a right-aligned "Revenue (30d)" column to the table showing `f.money(c.revenue_30d_usd, "USD")`, placed after the existing currency/country column. Add it to the CSV export too, as its own column.

4. CHANGE A COMPANY'S CURRENCY (src/routes/_authenticated/platform/companies/$id.tsx)
- Next to the existing `{org.country} · {org.default_currency}` line, add a small edit (pencil) button, platform owners and admins only. Opens a dialog: a currency Select (options from the `currencies` table, excluding the current one), and this exact warning text above the Select, styled as a warning callout: "This changes the currency code shown for every new quote, invoice and pay run from now on. It does not convert anything already priced — existing rate cards, invoices and pay runs keep their old numbers under the new code until {company} updates them." Confirm calls `platform_set_org_currency(p_org, p_currency)`. After saving, refetch and toast "Currency updated."

5. FIX: A FARMED-OUT TRIP'S PRICE SHOWS THE WRONG CURRENCY (src/routes/_authenticated/_staff/network.tsx)
- Line ~168 renders `f.money(r.partner_price)` with no currency, which silently formats the number in the VIEWER's own currency rather than the currency it was actually priced in. `farm_outs` rows now carry their own `currency` column (already included since the query selects `*`). Change it to `f.money(r.partner_price, r.currency)`.
- When `r.currency` differs from the viewer's own `activeOrg.default_currency`, also show the USD-equivalent in parentheses, small and muted, next to it: e.g. "€90.00 (≈ $97 USD)" — compute it with a tiny RPC call to `to_usd(r.currency, r.partner_price)` per distinct currency present in the list (not per row — batch by unique currency to avoid N calls), or simplest: one query of `to_usd` per row is fine given this list is typically short; do not add client-side FX math.

ACCEPTANCE (check in code, then report)
1. Reference data > Exchange rates lists all currencies with their rate; editing CAD's rate and reloading shows the new value.
2. Platform Overview shows a combined USD figure alongside the per-currency breakdown.
3. The Companies list and its CSV export both show a USD revenue column.
4. Changing a company's currency on its detail page shows the warning, saves, and the header updates.
5. A farm-out priced in EUR shows "€" to a USD-default viewer, with a USD-equivalent shown alongside it, not silently relabeled as "$".

When done, reply with only: files changed, anything added to docs/ASSUMPTIONS.md, type check and test results.
```
