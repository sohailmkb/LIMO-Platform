// Create a Stripe Checkout page for a booking, on the operator's own Stripe account.
// Staff:  POST { booking_id, kind: "deposit"|"balance", return_origin }  (signed in)
// Public: POST { slug, code, kind: "deposit"|"balance", return_origin }  (customer status page)
// -> { url, amount, currency }
import { amountDue, feeMinor, toMinor, type PaymentKind } from "../_shared/amounts.ts";
import { callerUser, checkOrigin, hasRole, HttpError, json, serve, serviceClient, stripeClient } from "../_shared/common.ts";

serve(async (req, body) => {
  const admin = serviceClient();
  const kind = body.kind as PaymentKind;
  if (kind !== "deposit" && kind !== "balance") throw new HttpError(400, "kind must be deposit or balance");
  const origin = checkOrigin(body.return_origin);

  // Find the booking and decide where to send the customer afterwards.
  let bookingId: string;
  let backPath: string;
  if (body.booking_id) {
    const user = await callerUser(req, admin);
    if (!user) throw new HttpError(401, "Sign in first");
    bookingId = String(body.booking_id);
    const { data: b } = await admin.from("bookings").select("org_id").eq("id", bookingId).maybeSingle();
    if (!b) throw new HttpError(404, "Booking not found");
    if (!(await hasRole(admin, user.id, b.org_id, ["owner", "admin", "dispatcher"]))) {
      throw new HttpError(403, "Not allowed");
    }
    backPath = `/bookings/${bookingId}`;
  } else {
    const slug = String(body.slug ?? ""), code = String(body.code ?? "");
    if (!slug || !code) throw new HttpError(400, "slug and code are required");
    const { data: o } = await admin.from("orgs").select("id").eq("slug", slug).eq("status", "active").maybeSingle();
    if (!o) throw new HttpError(404, "Booking not found");
    const { data: b } = await admin.from("bookings").select("id").eq("org_id", o.id).eq("public_code", code).maybeSingle();
    if (!b) throw new HttpError(404, "Booking not found");
    bookingId = b.id;
    backPath = `/book/${encodeURIComponent(slug)}/status/${encodeURIComponent(code)}`;
  }

  const { data: bk, error } = await admin
    .from("bookings")
    .select("id, number, status, currency, total, paid_amount, org_id, booker:contacts(email), org:orgs(name, status, stripe_account_id, stripe_charges_enabled, deposit_percent)")
    .eq("id", bookingId)
    .single();
  if (error || !bk) throw new HttpError(404, "Booking not found");
  // deno-lint-ignore no-explicit-any
  const org = bk.org as any;
  // deno-lint-ignore no-explicit-any
  const booker = bk.booker as any;
  if (bk.status === "cancelled") throw new HttpError(409, "This booking is cancelled");
  if (org.status !== "active") throw new HttpError(409, "This company is not taking payments");
  if (!org.stripe_account_id || !org.stripe_charges_enabled) {
    throw new HttpError(409, "Card payments are not set up for this company yet");
  }

  const due = amountDue(kind, Number(bk.total), Number(bk.paid_amount), Number(org.deposit_percent));
  if (due <= 0) throw new HttpError(409, kind === "deposit" ? "No deposit is due" : "Nothing left to pay");
  const minor = toMinor(due);

  // Reuse an open checkout for the same amount instead of creating duplicates.
  const { data: open } = await admin
    .from("payments")
    .select("checkout_url, amount, created_at")
    .eq("booking_id", bk.id).eq("provider", "stripe").eq("status", "pending").eq("kind", kind)
    .gte("created_at", new Date(Date.now() - 20 * 3600 * 1000).toISOString())
    .order("created_at", { ascending: false }).limit(1);
  if (open && open.length && Number(open[0].amount) === due && open[0].checkout_url) {
    return json({ url: open[0].checkout_url, amount: due, currency: bk.currency });
  }

  const { data: settings } = await admin.from("platform_settings").select("platform_fee_bps").single();
  const fee = feeMinor(minor, Number(settings?.platform_fee_bps ?? 0));

  const stripe = stripeClient();
  const metadata = { booking_id: bk.id, org_id: bk.org_id, kind };
  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    line_items: [{
      quantity: 1,
      price_data: {
        currency: String(bk.currency).toLowerCase(),
        unit_amount: minor,
        product_data: { name: `${org.name}: booking #${bk.number}${kind === "deposit" ? " (deposit)" : ""}` },
      },
    }],
    customer_email: booker?.email ?? undefined,
    payment_intent_data: { metadata, ...(fee > 0 ? { application_fee_amount: fee } : {}) },
    metadata,
    success_url: `${origin}${backPath}?paid=1`,
    cancel_url: `${origin}${backPath}?cancelled=1`,
  }, { stripeAccount: org.stripe_account_id });

  const { error: insErr } = await admin.from("payments").insert({
    org_id: bk.org_id, booking_id: bk.id, provider: "stripe", provider_ref: session.id,
    amount: due, currency: bk.currency, status: "pending", kind,
    checkout_url: session.url, application_fee: fee / 100,
  });
  if (insErr) throw new Error(insErr.message);

  return json({ url: session.url, amount: due, currency: bk.currency });
});
