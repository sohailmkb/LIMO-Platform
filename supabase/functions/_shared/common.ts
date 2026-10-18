// Shared setup for the Stripe edge functions.
import Stripe from "npm:stripe@22.6.2";
import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.118.0";
import { isAllowedOrigin } from "./amounts.ts";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing secret ${name}`);
  return v;
}

export function stripeClient(): Stripe {
  return new Stripe(env("STRIPE_SECRET_KEY"), {
    httpClient: Stripe.createFetchHttpClient(),
  });
}

/** Service-role client: bypasses row-level security. Used only after our own checks. */
export function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false },
  });
}

/** The signed-in caller, or null. */
export async function callerUser(req: Request, admin: SupabaseClient): Promise<User | null> {
  const header = req.headers.get("Authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token || token.startsWith("sb_")) return null; // publishable key, not a user session
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user;
}

/** True if the user is a platform super admin. */
export async function isPlatformAdmin(admin: SupabaseClient, userId: string): Promise<boolean> {
  const { data } = await admin.from("platform_admins").select("user_id").eq("user_id", userId).maybeSingle();
  return !!data;
}

/** True if the user holds one of the roles in an active company (or is a super admin). */
export async function hasRole(admin: SupabaseClient, userId: string, orgId: string, roles: string[]): Promise<boolean> {
  if (await isPlatformAdmin(admin, userId)) return true;
  const { data } = await admin
    .from("memberships")
    .select("role, orgs!inner(status)")
    .eq("org_id", orgId)
    .eq("user_id", userId)
    .eq("active", true)
    .in("role", roles)
    .eq("orgs.status", "active")
    .limit(1);
  return !!data && data.length > 0;
}

/** Allowed web origins for return URLs, from the APP_ORIGINS secret (comma separated). */
export function allowedOrigins(): string[] {
  return (Deno.env.get("APP_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

export function checkOrigin(origin: unknown): string {
  if (typeof origin !== "string" || !isAllowedOrigin(origin, allowedOrigins())) {
    throw new HttpError(400, "return_origin is not an allowed site");
  }
  return new URL(origin).origin;
}

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

/** Wraps a handler with CORS, JSON parsing and error mapping. */
export function serve(handler: (req: Request, body: Record<string, unknown>) => Promise<Response>) {
  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    if (req.method !== "POST") return json({ error: "Use POST" }, 405);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { /* empty body */ }
    try {
      return await handler(req, body);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      if (e instanceof Stripe.errors.StripeError) {
        console.error("Stripe error", e.type, e.message);
        return json({ error: e.message }, 502);
      }
      console.error(e);
      return json({ error: "Something went wrong" }, 500);
    }
  });
}
