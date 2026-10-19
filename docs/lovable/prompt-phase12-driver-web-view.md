# Lovable prompt: Phase 12, driver web view

No migration to run first; this phase is pure frontend. Paste as one message, normal mode.

---

```
Build the item below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, pick the simplest option that fits the existing code and log it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or database functions. Everything this needs already exists: drivers can already read their own assigned trips (RLS policy driver_read on trips), already have their own row on drivers (driver_self_read/driver_self_update), and update_trip_status(p_trip, p_status, p_lat, p_lng) already lets the assigned driver (not just staff) move their own trip through its statuses and optionally attach GPS coordinates.
- Touch only the files named here plus new files. No reformatting or refactoring elsewhere.
- Reuse: primitives.tsx, states.tsx, status-badge.tsx, useFormat, friendlyError, useT. Model the new route's structure on src/routes/_authenticated/my-trips.tsx (same kind of flat, non-staff, mobile-first page, no sidebar).
- All new text through useT() in BOTH en.json and fr.json. Proper French. No em dashes.
- No screenshots while working. At the end run the type check and vitest once, fix failures, stop.

CONTEXT: a driver who signs in today is sent to /app-only and told to use a mobile app that doesn't exist yet. There is no way for a driver to see their own trips or mark themselves en route, arrived, on board or completed anywhere in this product. Dispatchers currently do all of that by phone. The backend has always supported a driver doing this themselves; only the page was never built. This phase builds that page.

1. NEW ROUTE: MY SHIFT (src/routes/_authenticated/my-shift.tsx)
- A flat, mobile-first page (no AppShell sidebar), same pattern as my-trips.tsx.
- Query the driver's own trips directly against `trips` (RLS already scopes this to trips they're assigned to; no RPC needed) — select the same columns and joins src/routes/_authenticated/_staff/dispatch.tsx already selects for a trip card (pickup_at, pickup_address, dropoff_address, duration_hours, status, plus whatever booking/passenger/vehicle fields that query already joins), so the shape is proven correct. Order by pickup_at.
- Group into two sections: "Today" (pickup_at is today, any non-final status) and "Upcoming" (future pickup_at). Finished trips (completed, no_show, cancelled) from today stay visible in Today, muted/collapsed at the bottom, not hidden.
- Each trip is a card: time, pickup and dropoff address, passenger name if the query returns one, vehicle/class if returned, and a status badge (reuse status-badge.tsx).
- Tapping a card opens a detail view (can be a route param view or an in-page expand, whichever this codebase already does for similar drill-ins) showing the full address text, any trip notes/special instructions field the trips/bookings query exposes, and a "Directions" link that opens the pickup address in the device's default maps app (a plain maps URL, not an embedded map).
- STATUS ACTIONS: show only the single next valid action for the trip's current status, matching the exact flow already enforced server-side and mirrored in dispatch.tsx's STATUS_FLOW: assigned → "Start trip" (en_route); en_route → "Mark arrived" (arrived); arrived → "Passenger on board" (on_board) or "No-show" (no_show); on_board → "Complete trip" (completed). No cancel action for drivers (the database already blocks it for non-staff). Tapping an action calls update_trip_status(p_trip, p_status, lat, lng).
- Before each status call, best-effort request the browser's location (navigator.geolocation.getCurrentPosition) with a short timeout; if it succeeds pass p_lat/p_lng, if it's denied, times out, or the API is unavailable, call update_trip_status with lat/lng omitted. Never block the status update on location, never show an error for a declined location prompt.
- Empty state when there are no trips at all ("No trips assigned", reuse EmptyState). Loading/error states via ListSkeleton/ErrorRow as elsewhere.
- Out of scope for this pass, do not build: document expiry view, shift schedule view, editable driver profile, driver scorecard self-view. Note the cut in docs/ASSUMPTIONS.md.

2. ROUTE DRIVERS HERE INSTEAD OF /app-only
- src/lib/access.ts: in destinationsFor, the "driver" case currently points `to: "/app-only"`. Change it to `to: "/my-shift"`.
- src/routes/_authenticated/_staff/route.tsx: in beforeLoad, the fallback `throw redirect({ to: m.hasNonStaff ? "/app-only" : "/onboarding" })` sends a driver-only membership (m.hasDriverOnly) to /app-only today. Change it so a driver-only membership redirects to "/my-shift" instead; keep "/app-only" as the fallback for any other non-staff case that isn't a driver or a customer.
- Leave /app-only itself as-is (still used as a generic "no web page for you" fallback); do not delete it.

ACCEPTANCE (check in code, then report)
1. A user whose only membership is role 'driver' lands on /my-shift after signing in, not /app-only.
2. /my-shift lists their assigned trips split into Today and Upcoming, pulled straight from `trips` with no new RPC.
3. Each trip shows only its one valid next status action, and tapping it calls update_trip_status with best-effort GPS, succeeding whether or not location permission is granted.
4. A completed/no_show/cancelled trip shows no action buttons.
5. The page is usable one-handed on a phone screen.

When done, reply with only: files changed, anything added to docs/ASSUMPTIONS.md, type check and test results.
```
