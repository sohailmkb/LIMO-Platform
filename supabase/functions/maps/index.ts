// Address search and driving distance through Google Maps Platform. The key never reaches the browser.
// POST { action: "autocomplete", input, session, lang?, country? } -> { suggestions: [{ place_id, main, secondary }] }
// POST { action: "details", place_id, session, lang? }               -> { address, lat, lng, name, airport }
// POST { action: "route", points: [{lat,lng}, ...], depart_at? }     -> { meters, km, miles, seconds, minutes }
// Secret: GOOGLE_MAPS_API_KEY (Places API (New) and Routes API enabled). Callers: any allowed web origin.
import { allowedOrigins, corsHeaders, json } from "./http.ts";

const KEY = () => {
  const k = Deno.env.get("GOOGLE_MAPS_API_KEY");
  if (!k) throw new Fail(503, "Maps are not set up yet");
  return k;
};

class Fail extends Error {
  constructor(public status: number, message: string) { super(message); }
}

const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : NaN);

async function google(url: string, fieldMask: string, body?: unknown) {
  const res = await fetch(url, {
    method: body ? "POST" : "GET",
    headers: { "Content-Type": "application/json", "X-Goog-Api-Key": KEY(), "X-Goog-FieldMask": fieldMask },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.error("Google error", res.status, JSON.stringify(data).slice(0, 500));
    throw new Fail(502, "The map service did not answer. Type the address instead.");
  }
  return data as Record<string, unknown>;
}

async function autocomplete(b: Record<string, unknown>) {
  const input = str(b.input, 200);
  if (input.length < 3) return { suggestions: [] };
  const country = str(b.country, 2).toLowerCase();
  const data = await google("https://places.googleapis.com/v1/places:autocomplete",
    "suggestions.placePrediction.placeId,suggestions.placePrediction.structuredFormat", {
      input,
      sessionToken: str(b.session, 64) || undefined,
      languageCode: str(b.lang, 5) || "en",
      ...(country ? { includedRegionCodes: [country] } : {}),
    });
  const list = (data.suggestions as { placePrediction?: Record<string, any> }[] | undefined) ?? [];
  return {
    suggestions: list
      .map((s) => s.placePrediction)
      .filter(Boolean)
      .slice(0, 6)
      .map((p) => ({
        place_id: p!.placeId as string,
        main: p!.structuredFormat?.mainText?.text ?? "",
        secondary: p!.structuredFormat?.secondaryText?.text ?? "",
      })),
  };
}

async function details(b: Record<string, unknown>) {
  const id = str(b.place_id, 300);
  if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Fail(400, "place_id is required");
  const q = new URLSearchParams({ languageCode: str(b.lang, 5) || "en" });
  const session = str(b.session, 64);
  if (session) q.set("sessionToken", session);
  const p = await google(`https://places.googleapis.com/v1/places/${id}?${q}`,
    "formattedAddress,location,displayName,types");
  const loc = p.location as { latitude: number; longitude: number } | undefined;
  const types = (p.types as string[] | undefined) ?? [];
  const name = (p.displayName as { text?: string } | undefined)?.text ?? "";
  const formatted = (p.formattedAddress as string | undefined) ?? "";
  return {
    address: name && !formatted.startsWith(name) ? `${name}, ${formatted}` : formatted,
    lat: loc?.latitude ?? null,
    lng: loc?.longitude ?? null,
    name,
    airport: types.includes("airport"),
  };
}

async function route(b: Record<string, unknown>) {
  const pts = Array.isArray(b.points) ? (b.points as { lat: unknown; lng: unknown }[]) : [];
  if (pts.length < 2 || pts.length > 8) throw new Fail(400, "Give 2 to 8 points");
  const ll = pts.map((p) => {
    const lat = num(p?.lat), lng = num(p?.lng);
    if (Number.isNaN(lat) || Number.isNaN(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) throw new Fail(400, "Bad point");
    return { location: { latLng: { latitude: lat, longitude: lng } } };
  });
  const depart = str(b.depart_at, 40);
  const future = depart && Date.parse(depart) > Date.now() + 60_000 ? new Date(depart).toISOString() : undefined;
  const data = await google("https://routes.googleapis.com/directions/v2:computeRoutes",
    "routes.distanceMeters,routes.duration", {
      origin: ll[0],
      destination: ll[ll.length - 1],
      intermediates: ll.slice(1, -1),
      travelMode: "DRIVE",
      routingPreference: future ? "TRAFFIC_AWARE" : "TRAFFIC_UNAWARE",
      ...(future ? { departureTime: future } : {}),
    });
  const r = (data.routes as { distanceMeters?: number; duration?: string }[] | undefined)?.[0];
  if (!r?.distanceMeters) throw new Fail(422, "No driving route between these places");
  const seconds = Number(String(r.duration ?? "0s").replace("s", "")) || 0;
  return {
    meters: r.distanceMeters,
    km: Math.round(r.distanceMeters / 100) / 10,
    miles: Math.round(r.distanceMeters / 160.9344) / 10,
    seconds,
    minutes: Math.round(seconds / 60),
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  // Browsers always send Origin; only our own sites may spend the maps quota.
  const origin = req.headers.get("Origin");
  const allowed = allowedOrigins();
  if (allowed.length && (!origin || !allowed.some((a) => origin === a || (a.startsWith("*.") && origin.endsWith(a.slice(1)))))) {
    return json({ error: "Not allowed from this site" }, 403);
  }
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }
  try {
    switch (body.action) {
      case "autocomplete": return json(await autocomplete(body));
      case "details": return json(await details(body));
      case "route": return json(await route(body));
      default: return json({ error: "action must be autocomplete, details or route" }, 400);
    }
  } catch (e) {
    if (e instanceof Fail) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: "Something went wrong" }, 500);
  }
});
