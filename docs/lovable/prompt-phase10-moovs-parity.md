# Lovable prompt: Phase 10, Moovs parity

Before pasting: run `supabase/migrations/0013_moovs_parity.sql` in the Supabase SQL Editor. Paste after Phase 9 has finished. Normal mode, one message.

---

```
Build all 8 items below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, pick the simplest option that fits the existing code and log it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or database functions. All of it exists (migration 0013). Scores, evidence bundles and penalty math are calculated by the database; never compute them in the browser except for display.
- Touch only the files named here plus new files. No reformatting or refactoring elsewhere.
- Reuse: primitives.tsx, states.tsx, StatusBadge, useActiveOrg, useFormat, friendlyError, useT, can() from permissions.ts, Section, Field, the luxury tokens. Do not add any new npm package; maplibre-gl and qrcode.react are already installed and are all you need.
- All new text through useT() in BOTH en.json and fr.json. Proper French. No em dashes.
- Respect roles: hide what can() denies; the database refuses it anyway.
- No screenshots while working. At the end run the type check and vitest once, fix failures, stop.

1. ZONE BOUNDARIES ON THE MAP (src/components/app/pricing-zones.tsx)
- Today a zone is a plain lat/lng/radius circle. Add a toggle in the zone editor: "Circle" (today's three fields) or "Draw on map" (free-form boundary, stored in the new `boundary` jsonb column as a ring of [lat, lng] pairs).
- "Draw on map" shows a MapLibre canvas (same dynamic-import pattern as route-map.tsx). Click to drop a point, click the first point again (or a "Finish shape" button) to close the ring; a "Clear" button restarts. Need at least 3 points before saving. Render the ring as a filled polygon while drawing.
- Save calls `upsert_zone(p_org, p_name, p_kind, p_lat, p_lng, p_radius_km, p_boundary)`: when "Draw on map" is used, pass the ring's centroid as lat/lng (for list display and sorting), a radius_km of null, and the ring as p_boundary; when "Circle" is used, pass p_boundary as null exactly as today.
- Zone list row: show "Custom shape" instead of the radius line when `boundary` is set; a small static polygon thumbnail is a nice-to-have, not required.
- The existing "Try a price" box and zone-rate matching need no changes; the database already matches boundaries when present.

2. DRIVER SCORECARD (src/routes/_authenticated/_staff/drivers.$id.tsx, new src/components/app/driver-scorecard.tsx)
- A "Scorecard" card from `driver_scorecard(p_org, p_driver)` -> {trips_90d, completed_90d, no_shows_90d, cancelled_90d, on_time_pct, timed_trips_90d, rating, ratings}. Show four stat tiles: trips in the last 90 days, on-time % (with the count it's based on; "Not enough timed trips yet" when null), rating (stars, with the review count), no-shows/cancellations. Staff only (owners, admins, dispatchers, accountants); hide the card otherwise.
- Drivers list: add a compact on-time % and rating column, same `driver_ratings(p_org)` call already used for the rating column — just add on-time by also calling `driver_scorecard` per row is too many calls, so instead add these two columns only on the driver detail page, not the list (the list already has a rating column from Phase 9; leave it as is).

3. DRIVER PENALTIES AND PAY RUN DEDUCTIONS (drivers.$id.tsx, new src/components/app/driver-penalties.tsx, new src/routes/_authenticated/_staff/settings/penalty-rules.tsx, billing/payroll.$id.tsx)
- Settings "Penalty rules" page (owners, admins, accountants; add to the Settings nav group): list/add/deactivate rows of `penalty_rules` (name, trigger: Late arrival / No-show / Other, late_minutes when trigger is "late", amount or percent of that trip's driver pay — radio between the two, active toggle). Plain insert/update against the table (RLS already restricts to finance roles).
- A "Scan for penalties" button (anywhere convenient — Today page or the penalty-rules page) calling `apply_penalty_rules(p_org)`, toast with the count created ("3 penalties created" / "Nothing to flag").
- Driver page: a "Penalties" panel listing `driver_penalties` for that driver (amount, note, status pending/applied/voided, trip link when set). "Add penalty" dialog (amount, note) calling `add_driver_penalty(p_org, p_driver, p_amount, p_note)`. "Void" button on a pending row calling `void_driver_penalty(p_penalty)` with a confirm.
- Pay run page (billing/payroll.$id.tsx): the `pay_run_lines.adjustment`/`adjustment_note` fields already render per Phase 9; when `adjustment_note` is "Penalties this period" show it with a small warning-tone badge instead of the plain adjustment text, so it reads as "−$X penalties" rather than a generic line.

4. DISPUTES / CHARGEBACKS (new src/routes/_authenticated/_staff/billing/disputes.tsx, billing/disputes.$id.tsx; add "Disputes" to the Billing nav group for owners, admins, accountants)
- List: amount, currency, reason, status (needs_response amber / under_review / won green / lost red), evidence due date, linked booking number. Filter by status.
- Dispute page: status actions (set_dispute_status to under_review / won / lost, each with a short confirm). An "Evidence" section calling `dispute_evidence(p_dispute)` -> {dispute, booking, trips[] with a timeline of events, rating}. Render it as a printable one-pager (reuse the invoice print CSS pattern): booking summary, each trip's address/time/status timeline as a simple vertical list, the rider's rating/comment if present. A "Print" button (window.print, same approach as the booking invoice). State clearly in a note under the heading: "This is your own trip record for reference while responding in Stripe's dashboard — it is not submitted automatically."
- Disputes arrive via webhook already (no action needed); this phase is the UI to see and work them.

5. SMART DRIVER SUGGESTIONS AT ASSIGN TIME (src/components/app/assign-dialog.tsx)
- When the dialog opens (trip present, driver not yet chosen), call `suggest_drivers(p_trip, 5)` and show the results above the plain driver Select as a short ranked list: name, score, and the reasons chips (e.g. "2.3 km away", "4.8 star average", "95% on time", "2 trip(s) already today"). Clicking a row selects that driver in the existing Select (don't replace the Select, just prefill it) so vehicle choice and the rest of the flow are untouched.
- If `suggest_drivers` returns nothing (e.g. no drivers free), show nothing extra — the plain Select still works exactly as before.
- Customers and drivers never open this dialog, so no permission change is needed; the database already restricts the call to staff.

6. GLOBAL SEARCH (new src/components/app/global-search.tsx, wired into the staff app shell's header)
- A search field in the header (desktop: inline; mobile: an icon that opens a full-screen sheet), placeholder "Search bookings, people, companies…". Debounce ~300ms, minimum 2 characters, call `global_search(p_org, p_query)` -> {contacts, companies, bookings}, each already limited to 8.
- Results in three short grouped lists (Bookings, Contacts, Companies) with icons; clicking a booking goes to bookings/$id, a contact to customers/$id, a company to accounts/$id (or the closest existing route for each — check the actual route names before wiring links and use what exists). Keyboard: Cmd/Ctrl+K focuses it (reuse the Kbd primitive and modKey/useSubmitShortcut pattern already used in assign-dialog.tsx), Escape clears it, arrow keys move between results, Enter opens the highlighted one.
- Empty state below 2 characters: nothing shown. No results: "No matches for “{query}”".

7. TWO-FACTOR AUTHENTICATION (settings.tsx or a new settings/security.tsx tab, linked from Settings nav)
- This uses Supabase Auth's built-in TOTP MFA directly from the browser client (`supabase.auth.mfa.enroll/challenge/verify/listFactors/unenroll`) — no new database objects needed.
- "Security" section: if no verified TOTP factor, show "Set up two-factor authentication" -> enroll() -> show the QR code (render the returned `totp.qr_code` SVG/URI with QRCodeSVG, already installed) and the secret as selectable text for manual entry -> a 6-digit code field -> challenge() + verify(). On success, toast and show "Two-factor authentication is on" with a "Turn off" button (unenroll with a confirm, re-authentication if the SDK requires it).
- If sign-in enforcement for MFA already exists elsewhere in the auth flow, leave it as is; this phase only adds the enrollment UI. Note in ASSUMPTIONS.md if the sign-in screen needs a follow-up MFA challenge step and you didn't find one — don't build that blind, just flag it.

8. GUIDED BOOKING-WIDGET INSTALL (src/routes/_authenticated/_staff/settings.tsx, WidgetSection)
- The existing WidgetSection already has the iframe snippet, the booking link and a QR code — keep all of that. Add tabs above the snippet: "WordPress", "Wix", "Squarespace", "Plain HTML / other", "Google Business Profile". Each tab shows 2-4 short numbered steps (plain text, through useT()) for pasting the same iframe snippet into that platform's embed/HTML block (for Wix: "Add → Embed → Custom Embeds → paste the code"; for WordPress: "Add a Custom HTML block and paste the code"; for Squarespace: "Add a Code Block and paste the code"; for Google Business Profile: "GBP doesn't accept embedded iframes — instead add the booking link above as your profile's 'Book' website link"). The snippet/link/QR stay shared across tabs, not duplicated per tab.
- This is copy and layout only; no new backend call.

ACCEPTANCE (check in code, then report)
1. A zone drawn as a shape on the map saves and a price trip through it picks up the matching zone rate.
2. A driver's scorecard shows real trip/on-time/rating numbers once they have completed trips.
3. A "Late arrival" penalty rule, after "Scan for penalties", creates a pending penalty that shows on the driver's page and folds into the next pay run as a negative adjustment.
4. A dispute's evidence page prints with the booking, trip timeline and rating.
5. Opening the assign dialog on an unassigned trip shows ranked driver suggestions with reasons; clicking one selects it.
6. Cmd/Ctrl+K opens global search; typing a passenger name finds their booking and opens it.
7. Enrolling two-factor authentication shows a scannable QR code and turns on after entering a valid code.
8. The widget section shows platform-specific install steps and the same working snippet under every tab.

When done, reply with only: files changed, anything added to docs/ASSUMPTIONS.md, type check and test results.
```
