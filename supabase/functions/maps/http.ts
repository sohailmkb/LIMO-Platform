// Small HTTP helpers for the maps function (kept separate so it does not load the Stripe SDK).
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

/** APP_ORIGINS secret, comma separated. "*.lovable.app" style entries match any subdomain. */
export function allowedOrigins(): string[] {
  return (Deno.env.get("APP_ORIGINS") ?? "").split(",").map((s) => s.trim().replace(/\/$/, "")).filter(Boolean);
}
