# Lovable prompt: card payments (Stripe Connect)

Copy everything between the two `=====` lines.

=====

# Build: card payments through Stripe

Card payments now work on the server. Each operator connects its own Stripe account; customers pay the operator through a Stripe-hosted checkout page. You build the screens only. Hard rules still apply: no schema changes, no new tables, and **never put any Stripe key in the front end or call Stripe from the browser**. All Stripe work happens in these Supabase edge functions, called with `supabase.functions.invoke(name, { body })` (it sends the signed-in session automatically):

| Function | Body | Returns |
|---|---|---|
| `stripe-connect` | `{ org_id, action: "onboard", return_origin: window.location.origin }` | `{ url }` to send the owner to Stripe onboarding |
| `stripe-connect` | `{ org_id, action: "refresh" }` | `{ connected, charges_enabled, details_submitted }` |
| `stripe-checkout` (staff, signed in) | `{ booking_id, kind: "deposit" or "balance", return_origin }` | `{ url, amount, currency }` |
| `stripe-checkout` (public status page) | `{ slug, code, kind, return_origin }` | `{ url, amount, currency }` |

Errors come back as `{ error: "message" }` with a 4xx status; show the message. Owners and admins can call `stripe-connect`; dispatchers cannot.

New database fields:
- `orgs.stripe_account_id`, `orgs.stripe_charges_enabled`, `orgs.stripe_details_submitted`: read-only for the app (the server sets them).
- `orgs.deposit_percent` (0 to 100): owners and admins can edit. 0 means no deposit, customers pay in full.
- `payments.kind` (`deposit`, `balance`, `manual`), `payments.checkout_url`, `payments.payment_intent`, `payments.application_fee`, `payments.updated_at`. Status values: `pending`, `succeeded`, `failed`, `refunded`.
- `platform_settings` (one row): `platform_fee_bps` (100 = 1%), super admin only.
- RPC `booking_amount_due(p_booking uuid)` returns `{ currency, total, paid, balance, deposit_due, deposit_percent, card_payments_ready }`.
- RPC `public_booking_status` now also returns `paid`, `balance`, `deposit_due`, `card_payments_ready`.

## 1. Settings > Payments (owner and admin)
- Status card: Not connected / Setup incomplete (account exists, `stripe_charges_enabled` false) / Ready to take card payments.
- Button: "Connect Stripe" or "Continue setup": invoke `stripe-connect` onboard, then `window.location.href = url`.
- When the page loads with `?stripe=return` or `?stripe=refresh`, invoke `stripe-connect` refresh, show the result, and remove the query string.
- "Deposit required" field: percent 0 to 100, saved to `orgs.deposit_percent`, with the hint "0 means customers pay the full amount".
- Note under the card: "Customers pay your company directly. Refunds and disputes are handled in your Stripe dashboard."

## 2. Booking detail: Card payment section
- Load `booking_amount_due`. Show total, paid, balance, deposit due.
- If `card_payments_ready` is false: show "Connect Stripe in Settings > Payments to take cards" with a link (owners/admins) or "Card payments are not set up" (dispatchers).
- Otherwise buttons: "Copy deposit link" (only when deposit_due > 0) and "Copy payment link" (balance). Each invokes `stripe-checkout` with booking_id and kind, then copies `url` to the clipboard with a toast showing the amount. Also "Open checkout" to open it in a new tab.
- Payments list: kind, amount, status badge, provider (Card / Recorded), date. Pending card payments show "Waiting for customer".
- On `?paid=1`: toast "Payment received. Updating..." and refetch the booking every 3 seconds for up to 30 seconds until paid_amount changes. On `?cancelled=1`: toast "Payment cancelled".
- Keep "Record payment" for cash and bank transfers (provider `manual`, kind `manual`).

## 3. Public status page (`/book/:slug/status/:code`)
- If `card_payments_ready` and `balance > 0`: primary button "Pay deposit (amount)" when `deposit_due > 0`, otherwise "Pay now (amount)". Invoke `stripe-checkout` with slug, code, kind, `return_origin: window.location.origin`, then redirect to `url`.
- Show "Secure payment by Stripe" under the button.
- `?paid=1`: "Thank you. Confirming your payment..." and refetch every 3 seconds for up to 30 seconds; then show Paid or Deposit paid. `?cancelled=1`: "Payment cancelled. You can try again."
- If card payments are not ready, keep the current line "Payment is arranged with the operator."

## 4. Booking list and Today
- Payment badge already exists; make sure `partial` reads "Deposit paid".
- Today: add "Payments received today" (sum of succeeded payments today, per currency).

## 5. Super admin (if the /platform area exists)
- On Overview or a Settings tab: "Platform fee on card payments" in percent (store as basis points in `platform_settings.platform_fee_bps`, 0 to 20%). Note: "Applies to new payments only."

## 6. English and French for every new string.

## Acceptance test
1. Settings > Payments > Connect Stripe opens Stripe onboarding; returning shows the status.
2. With card payments ready, a booking's "Copy payment link" gives a Stripe checkout URL; paying with 4242 4242 4242 4242 turns the booking Paid within 30 seconds.
3. With deposit 30% on a 135.60 booking, "Copy deposit link" charges 40.68; after paying, the booking shows Deposit paid and the balance 94.92.
4. The public status page shows Pay now and completes the same way.
5. A dispatcher sees the links but cannot connect Stripe.

=====
