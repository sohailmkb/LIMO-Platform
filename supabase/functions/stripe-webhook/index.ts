// Stripe webhook for events on connected accounts.
// Marks payments paid, failed or refunded, and keeps each company's Stripe status current.
import Stripe from "npm:stripe@22.6.2";
import { env, serviceClient, stripeClient } from "../_shared/common.ts";

const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const signature = req.headers.get("Stripe-Signature");
  const raw = await req.text();
  const stripe = stripeClient();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, signature ?? "", env("STRIPE_WEBHOOK_SECRET"), undefined, cryptoProvider);
  } catch (e) {
    console.error("Bad signature", (e as Error).message);
    return new Response("Bad signature", { status: 400 });
  }

  const admin = serviceClient();
  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.payment_status !== "paid") break; // async methods settle later
        const pi = typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent?.id ?? null;
        const { data: rows } = await admin.from("payments")
          .update({ status: "succeeded", payment_intent: pi, updated_at: new Date().toISOString() })
          .eq("provider", "stripe").eq("provider_ref", s.id).neq("status", "succeeded")
          .select("id, org_id, booking_id, amount");
        if (rows && rows.length) {
          await admin.from("audit_log").insert({
            org_id: rows[0].org_id, action: "payment_succeeded", entity: "booking", entity_id: rows[0].booking_id,
            detail: { amount: rows[0].amount, session: s.id },
          });
        }
        break;
      }
      case "checkout.session.expired":
      case "checkout.session.async_payment_failed": {
        const s = event.data.object as Stripe.Checkout.Session;
        await admin.from("payments")
          .update({ status: "failed", checkout_url: null, updated_at: new Date().toISOString() })
          .eq("provider", "stripe").eq("provider_ref", s.id).eq("status", "pending");
        break;
      }
      case "charge.refunded": {
        const c = event.data.object as Stripe.Charge;
        const pi = typeof c.payment_intent === "string" ? c.payment_intent : c.payment_intent?.id;
        if (pi && c.refunded) { // full refunds only; partial refunds handled in week 2
          await admin.from("payments")
            .update({ status: "refunded", updated_at: new Date().toISOString() })
            .eq("provider", "stripe").eq("payment_intent", pi);
        }
        break;
      }
      case "account.updated": {
        const a = event.data.object as Stripe.Account;
        await admin.from("orgs").update({
          stripe_charges_enabled: !!a.charges_enabled,
          stripe_details_submitted: !!a.details_submitted,
        }).eq("stripe_account_id", a.id);
        break;
      }
      default:
        break;
    }
  } catch (e) {
    console.error("Webhook handling failed", event.type, e);
    return new Response("Retry later", { status: 500 }); // Stripe retries
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
