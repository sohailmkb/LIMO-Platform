// Connect an operator's Stripe account, or refresh its status.
// POST { org_id, action: "onboard", return_origin }  -> { url }   (owner, admin or super admin)
// POST { org_id, action: "refresh" }                 -> { charges_enabled, details_submitted }
import { callerUser, checkOrigin, hasRole, HttpError, json, serve, serviceClient, stripeClient } from "../_shared/common.ts";

serve(async (req, body) => {
  const admin = serviceClient();
  const user = await callerUser(req, admin);
  if (!user) throw new HttpError(401, "Sign in first");

  const orgId = String(body.org_id ?? "");
  if (!orgId) throw new HttpError(400, "org_id is required");
  if (!(await hasRole(admin, user.id, orgId, ["owner", "admin"]))) {
    throw new HttpError(403, "Only owners and admins can manage payments");
  }

  const { data: org, error } = await admin
    .from("orgs")
    .select("id, name, country, kind, stripe_account_id")
    .eq("id", orgId)
    .single();
  if (error || !org) throw new HttpError(404, "Company not found");
  if (org.kind !== "operator") throw new HttpError(400, "Card payments are for operators");

  const stripe = stripeClient();

  if (body.action === "refresh") {
    if (!org.stripe_account_id) return json({ connected: false, charges_enabled: false, details_submitted: false });
    const acct = await stripe.accounts.retrieve(org.stripe_account_id);
    await admin.from("orgs").update({
      stripe_charges_enabled: !!acct.charges_enabled,
      stripe_details_submitted: !!acct.details_submitted,
    }).eq("id", org.id);
    return json({ connected: true, charges_enabled: !!acct.charges_enabled, details_submitted: !!acct.details_submitted });
  }

  if (body.action !== "onboard") throw new HttpError(400, "action must be onboard or refresh");
  const origin = checkOrigin(body.return_origin);

  let accountId = org.stripe_account_id as string | null;
  if (!accountId) {
    const acct = await stripe.accounts.create({
      type: "standard",
      country: org.country,
      email: user.email ?? undefined,
      business_profile: { name: org.name },
      metadata: { org_id: org.id },
    }, { idempotencyKey: `connect-${org.id}` });
    accountId = acct.id;
    const { error: upErr } = await admin.from("orgs").update({ stripe_account_id: accountId }).eq("id", org.id);
    if (upErr) throw new Error(upErr.message);
    await admin.from("audit_log").insert({
      org_id: org.id, actor_id: user.id, action: "stripe_account_created", entity: "org", entity_id: org.id,
      detail: { stripe_account_id: accountId },
    });
  }

  const link = await stripe.accountLinks.create({
    account: accountId,
    type: "account_onboarding",
    refresh_url: `${origin}/settings?stripe=refresh`,
    return_url: `${origin}/settings?stripe=return`,
  });
  return json({ url: link.url });
});
