// Partner-facing API: quote / book / modify / cancel / status, authenticated with the
// key_id + secret pairs issued by issue_api_credential() (0017). This is the piece that was
// explicitly deferred when that migration shipped -- see its own comment and
// 0024_partner_api.sql for why these need dedicated api_* RPCs rather than reusing the
// staff-facing ones.
//
// Auth: Authorization: Bearer <key_id>.<secret>  (key_id looks like key_xxxxxxxxxxxxxxxx,
// contains no '.', so splitting on the first '.' is unambiguous).
// Idempotency: Idempotency-Key header required on every mutating request (POST /v1/bookings,
// .../modify, .../cancel). Same key + same request body replays the stored response. Same
// key + a different body is rejected -- the caller reused a key for a different request.
//
// Known v1 simplifications, stated plainly rather than silently assumed:
//  - api_clients.environment (sandbox/production) is checked for existence only; sandbox
//    credentials write to the same data as production. A real sandboxed dataset is future
//    work, not pretended here.
//  - No per-credential rate limiting yet. Nothing in this file enforces one; add it before
//    handing a credential to a partner you don't fully trust.
//  - No OAuth2/OIDC layer -- this is a static key/secret pair, matching what 0017 already
//    issues. Good enough for a first partner, not a long-term identity story.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { corsHeaders, env, HttpError } from "../_shared/common.ts";

// Local, not the shared json() helper: every response here also carries X-Request-Id for
// correlation, which the shared helper (used by the Stripe functions) doesn't need.
function respond(body: unknown, status: number, headers: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface AuthedClient {
  clientId: string;
}

async function authenticate(req: Request, admin: SupabaseClient): Promise<AuthedClient> {
  const header = req.headers.get("Authorization") ?? "";
  const bearer = header.replace(/^Bearer\s+/i, "");
  const dot = bearer.indexOf(".");
  if (dot < 1) throw new HttpError(401, "Missing or malformed Authorization header. Expected: Bearer <key_id>.<secret>");
  const keyId = bearer.slice(0, dot);
  const secret = bearer.slice(dot + 1);

  const { data: cred, error: credErr } = await admin
    .from("api_credentials")
    .select("id, client_id, revoked_at, client:api_clients(id, active)")
    .eq("key_id", keyId)
    .maybeSingle();
  if (credErr) throw new HttpError(500, "Could not verify credential");
  if (!cred || cred.revoked_at) throw new HttpError(401, "Unknown or revoked API key");
  const client = cred.client as unknown as { id: string; active: boolean } | null;
  if (!client?.active) throw new HttpError(401, "This API client is not active");

  const { data: secretRow } = await admin
    .from("api_credential_secrets")
    .select("secret")
    .eq("credential_id", cred.id)
    .maybeSingle();
  if (!secretRow || !timingSafeEqual(secretRow.secret, secret)) throw new HttpError(401, "Invalid secret");

  return { clientId: cred.client_id };
}

/** Runs body through the stored idempotency record for this client+key, or records a fresh one. */
async function withIdempotency(
  admin: SupabaseClient,
  clientId: string,
  req: Request,
  rawBody: string,
  handler: () => Promise<{ status: number; body: unknown }>,
): Promise<{ status: number; body: unknown }> {
  const key = req.headers.get("Idempotency-Key");
  if (!key) throw new HttpError(400, "Idempotency-Key header is required for this request");
  const hash = await sha256Hex(rawBody);

  const { data: existing } = await admin
    .from("idempotency_keys")
    .select("request_hash, response_status, response_body")
    .eq("client_id", clientId)
    .eq("key", key)
    .maybeSingle();
  if (existing) {
    if (existing.request_hash !== hash) {
      throw new HttpError(409, "This Idempotency-Key was already used with a different request body");
    }
    return { status: existing.response_status ?? 200, body: existing.response_body };
  }

  const result = await handler();
  // Best-effort store; a race on the unique (client_id, key) constraint just means another
  // concurrent request with the same key won the insert -- fine, both produced the same result.
  await admin.from("idempotency_keys").insert({
    client_id: clientId, key, request_hash: hash,
    response_status: result.status, response_body: result.body,
  });
  return result;
}

function requestId(): string {
  return crypto.randomUUID();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const reqId = requestId();
  const headers = { ...corsHeaders, "Content-Type": "application/json", "X-Request-Id": reqId };

  try {
    const url = new URL(req.url);
    const marker = "/partner-api";
    const idx = url.pathname.indexOf(marker);
    const path = idx >= 0 ? url.pathname.slice(idx + marker.length) : url.pathname;

    const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
    const { clientId } = await authenticate(req, admin);

    // GET /v1/vehicle-classes
    if (req.method === "GET" && path === "/v1/vehicle-classes") {
      const { data: client } = await admin.from("api_clients").select("org_id").eq("id", clientId).maybeSingle();
      const { data, error } = await admin
        .from("vehicle_classes")
        .select("id, name, seats, luggage")
        .eq("org_id", client!.org_id)
        .order("sort_order");
      if (error) throw new HttpError(500, "Could not list vehicle classes");
      return respond({ vehicle_classes: data }, 200, headers);
    }

    // POST /v1/quotes  (read-only, no idempotency key required)
    if (req.method === "POST" && path === "/v1/quotes") {
      const body = await req.json();
      const { data: client } = await admin.from("api_clients").select("org_id").eq("id", clientId).maybeSingle();
      const { data, error } = await admin.rpc("quote_price", {
        p_org: client!.org_id,
        p_class: body.vehicle_class_id,
        p_service: body.service_type,
        p_distance: body.distance ?? 0,
        p_hours: body.hours ?? 0,
      });
      if (error) throw new HttpError(422, error.message);
      return respond(data, 200, headers);
    }

    // POST /v1/bookings
    if (req.method === "POST" && path === "/v1/bookings") {
      const raw = await req.text();
      const { status, body } = await withIdempotency(admin, clientId, req, raw, async () => {
        const b = JSON.parse(raw);
        const { data, error } = await admin.rpc("api_create_booking", {
          p_client: clientId,
          p_passenger_name: b.passenger_name,
          p_passenger_phone: b.passenger_phone ?? null,
          p_service: b.service_type,
          p_class: b.vehicle_class_id,
          p_pickup_at: b.pickup_at,
          p_pickup_address: b.pickup_address,
          p_dropoff_address: b.dropoff_address ?? null,
          p_distance: b.distance ?? 0,
          p_hours: b.hours ?? 0,
        });
        if (error) return { status: 422, body: { error: error.message } };
        return { status: 201, body: data };
      });
      return respond(body, status, headers);
    }

    // GET /v1/bookings/:id
    const statusMatch = path.match(/^\/v1\/bookings\/([^/]+)$/);
    if (req.method === "GET" && statusMatch) {
      const { data, error } = await admin.rpc("api_booking_status", { p_client: clientId, p_booking: statusMatch[1] });
      if (error || !data) return respond({ error: "Booking not found" }, 404, headers);
      return respond(data, 200, headers);
    }

    // POST /v1/bookings/:id/modify
    const modifyMatch = path.match(/^\/v1\/bookings\/([^/]+)\/modify$/);
    if (req.method === "POST" && modifyMatch) {
      const raw = await req.text();
      const { status, body } = await withIdempotency(admin, clientId, req, raw, async () => {
        const b = raw ? JSON.parse(raw) : {};
        const { data, error } = await admin.rpc("api_modify_booking", {
          p_client: clientId, p_booking: modifyMatch[1],
          p_pickup_at: b.pickup_at ?? null, p_pickup_address: b.pickup_address ?? null, p_dropoff_address: b.dropoff_address ?? null,
        });
        if (error) return { status: 422, body: { error: error.message } };
        return { status: 200, body: data };
      });
      return respond(body, status, headers);
    }

    // POST /v1/bookings/:id/cancel
    const cancelMatch = path.match(/^\/v1\/bookings\/([^/]+)\/cancel$/);
    if (req.method === "POST" && cancelMatch) {
      const raw = await req.text();
      const { status, body } = await withIdempotency(admin, clientId, req, raw, async () => {
        const b = raw ? JSON.parse(raw) : {};
        const { data, error } = await admin.rpc("api_cancel_booking", {
          p_client: clientId, p_booking: cancelMatch[1], p_reason: b.reason ?? null,
        });
        if (error) return { status: 422, body: { error: error.message } };
        return { status: 200, body: data };
      });
      return respond(body, status, headers);
    }

    return respond({ error: "Not found" }, 404, headers);
  } catch (e) {
    if (e instanceof HttpError) return respond({ error: e.message }, e.status, headers);
    console.error("partner-api error", reqId, e);
    return respond({ error: "Something went wrong", request_id: reqId }, 500, headers);
  }
});
