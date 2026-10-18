# Stripe setup (test mode)

How payments work: each limo company connects its own Stripe account. Customers pay that company directly through a Stripe-hosted checkout page (the company is the seller of record and handles refunds and disputes in its own Stripe dashboard). The platform can take a fee per payment; it starts at 0% and the super admin can change it.

Never paste a Stripe secret key (`sk_test_...`) or webhook secret (`whsec_...`) into chat, Lovable or the code. They go only into Supabase secrets.

## 1. Turn on Connect in your Stripe sandbox (5 min)
1. In the Stripe Dashboard, make sure you are in your **sandbox** (test mode).
2. Search for **Connect** and click **Get started**.
3. When asked how you will use Connect, choose a **platform** where businesses you onboard get paid (wording varies). If asked about the dashboard your users get, choose **Stripe Dashboard (full access)**, which is a "Standard" account.
4. Under Connect settings, fill in **branding** (platform name, icon, colour). Onboarding pages use it.

## 2. Copy your secret key
Developers > **API keys** > **Secret key** (`sk_test_...`). Reveal and copy it. Keep it in your password manager.

## 3. Add secrets in Supabase
Supabase > your project > **Edge Functions** > **Secrets** (or Project Settings > Edge Functions). Add:

| Name | Value |
|---|---|
| `STRIPE_SECRET_KEY` | your `sk_test_...` key |
| `APP_ORIGINS` | `https://id-preview--9ffac9da-f0de-4950-806e-56cf589a38cf.lovable.app` (add your published and custom domains later, comma separated) |

`STRIPE_WEBHOOK_SECRET` comes in step 6.

## 4. Run the database update
SQL Editor > New query > paste `supabase/migrations/0007_stripe.sql` > Run.

## 5. Deploy the three functions (from your laptop)
In PowerShell, in the project folder (`Documents\LIMO-Platform`, the latest version):

```
npx.cmd supabase login
npx.cmd supabase functions deploy --project-ref jtfdgxiiwysxdjhxymmm
```

The first command opens a browser to approve. The second deploys `stripe-connect`, `stripe-checkout` and `stripe-webhook` using `supabase/config.toml`. In Supabase > Edge Functions you should see all three.

## 6. Create the webhook in Stripe
1. Stripe Dashboard > Developers > **Webhooks** > **Add destination** (or Add endpoint).
2. Events from: **Connected accounts**.
3. Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `checkout.session.expired`, `charge.refunded`, `account.updated`.
4. Endpoint URL: `https://jtfdgxiiwysxdjhxymmm.supabase.co/functions/v1/stripe-webhook`
5. Save, then reveal the **Signing secret** (`whsec_...`) and add it in Supabase secrets as `STRIPE_WEBHOOK_SECRET`.

## 7. Test (after Lovable builds the payment screens)
1. Website > Settings > Payments > **Connect Stripe**. Stripe's test onboarding opens; use its test data options. You return to Settings showing "Ready to take card payments".
2. Open a booking > **Card payment** > copy the payment link, open it, pay with card `4242 4242 4242 4242`, any future date, any CVC.
3. Back on the booking, within a few seconds it shows **Paid**.
4. On the customer status page (`/book/<slug>/status/<code>`) a **Pay now** button appears for unpaid bookings.
