// Sweeps webhook_deliveries for pending rows that are due, signs each payload with its
// endpoint's own secret (HMAC-SHA256, Stripe-style header), POSTs it, and records the
// outcome with exponential backoff. Nothing in Postgres calls this on its own -- it has to
// be invoked on a schedule. See the deploy notes in claude/partner-api-reference.md for the
// one manual step (a Supabase Cron Job or equivalent hitting this function's URL every
// minute) this migration/function pair cannot set up by itself from here.
//
// Signature header, verified the same way Stripe's own webhooks are verified elsewhere in
// this codebase (see stripe-webhook/index.ts): X-GroundFlow-Signature: t=<unix_seconds>,
// v1=<hex hmac-sha256 of "${t}.${raw_body}" using the endpoint's secret>. A receiver should
// recompute the same HMAC over the literal bytes sent and reject anything that doesn't match,
// and should reject a timestamp too far in the past to block replay.
//
// Backoff: attempt 1 immediate, then roughly 1m, 5m, 30m, 2h, 12h. After 6 failed attempts a
// delivery is marked 'exhausted' and stops retrying; its row (and webhook_deliveries.last_error)
// stays visible to the operator's own UI so the support story is "look at the log", not
// "nothing, silently".

import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { env } from "../_shared/common.ts";

const BACKOFF_MINUTES = [1, 5, 30, 120, 720]; // index = attempt_count after this failure, 1-based
const MAX_ATTEMPTS = 6;
const BATCH_SIZE = 50;

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  // No request body expected -- the scheduler just needs to hit this URL. A shared secret
  // check (not a user-facing API, so a simple header compare is enough here) keeps a random
  // internet request from triggering a sweep.
  const expected = Deno.env.get("WEBHOOK_WORKER_SECRET");
  if (expected && req.headers.get("X-Worker-Secret") !== expected) {
    return new Response("Forbidden", { status: 403 });
  }

  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });

  const { data: due, error } = await admin
    .from("webhook_deliveries")
    .select("id, endpoint_id, event_type, payload, attempt_count, webhook_endpoints(url, active)")
    .eq("status", "pending")
    .lte("next_attempt_at", new Date().toISOString())
    .limit(BATCH_SIZE);
  if (error) {
    console.error("Could not load pending deliveries", error);
    return new Response(JSON.stringify({ error: "Could not load pending deliveries" }), { status: 500 });
  }

  let delivered = 0, failed = 0, exhausted = 0, skipped = 0;

  for (const row of due ?? []) {
    const endpoint = row.webhook_endpoints as unknown as { url: string; active: boolean } | null;
    if (!endpoint?.active) {
      // The endpoint was disabled or removed after this delivery was queued. webhook_deliveries'
      // status check constraint has no 'cancelled' value, so this reuses 'exhausted' (with a
      // last_error that says why) rather than leaving the row 'pending' forever -- a pending row
      // that can never succeed would otherwise be re-selected by every future sweep.
      await admin.from("webhook_deliveries").update({ status: "exhausted", last_error: "endpoint disabled or removed" }).eq("id", row.id);
      skipped++;
      continue;
    }

    const { data: secretRow } = await admin
      .from("webhook_endpoint_secrets")
      .select("secret")
      .eq("endpoint_id", row.endpoint_id)
      .maybeSingle();
    if (!secretRow) {
      // Should not happen -- create_webhook_endpoint always inserts the secret in the same
      // transaction as the endpoint. Mark exhausted rather than leaving a 'pending' row that
      // would otherwise be re-selected by every future sweep with nothing to sign with.
      await admin.from("webhook_deliveries").update({ status: "exhausted", last_error: "no signing secret found for this endpoint" }).eq("id", row.id);
      skipped++;
      continue;
    }

    const envelope = JSON.stringify({ id: row.id, type: row.event_type, created_at: new Date().toISOString(), data: row.payload });
    const ts = Math.floor(Date.now() / 1000);
    const signature = await hmacHex(secretRow.secret, `${ts}.${envelope}`);

    let ok = false;
    let errText = "";
    try {
      const resp = await fetch(endpoint.url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-GroundFlow-Signature": `t=${ts},v1=${signature}`,
          "X-GroundFlow-Event": row.event_type,
          "X-GroundFlow-Delivery": row.id,
        },
        body: envelope,
        signal: AbortSignal.timeout(10_000),
      });
      ok = resp.status >= 200 && resp.status < 300;
      if (!ok) errText = `HTTP ${resp.status}`;
    } catch (e) {
      errText = (e as Error).message;
    }

    if (ok) {
      await admin.from("webhook_deliveries").update({
        status: "delivered", delivered_at: new Date().toISOString(), attempt_count: row.attempt_count + 1,
      }).eq("id", row.id);
      delivered++;
    } else {
      const nextCount = row.attempt_count + 1;
      if (nextCount >= MAX_ATTEMPTS) {
        await admin.from("webhook_deliveries").update({
          status: "exhausted", attempt_count: nextCount, last_error: errText,
        }).eq("id", row.id);
        exhausted++;
      } else {
        const delayMin = BACKOFF_MINUTES[Math.min(nextCount - 1, BACKOFF_MINUTES.length - 1)];
        await admin.from("webhook_deliveries").update({
          attempt_count: nextCount, last_error: errText,
          next_attempt_at: new Date(Date.now() + delayMin * 60_000).toISOString(),
        }).eq("id", row.id);
        failed++;
      }
    }
  }

  return new Response(JSON.stringify({ processed: (due ?? []).length, delivered, failed, exhausted, skipped }), {
    headers: { "Content-Type": "application/json" },
  });
});
