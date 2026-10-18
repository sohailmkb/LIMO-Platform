# Lovable prompt: Phase 8, real bookings and the luxury finish

Before pasting:
1. Run `supabase/migrations/0010_booking_depth.sql` in the Supabase SQL Editor (Lovable regenerates its types from the live database, so this comes first).
2. Maps use free OpenStreetMap services for now (no key, nothing to set up). Google can replace them later by changing one file; see `docs/MAPS_SETUP.md`.

Paste the block below as one message, in normal mode.

---

```
Build all 9 items below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, choose the simplest option that fits the existing code and log it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or database functions. Everything below already exists in the database.
- Touch only the files named here plus new files. Do not reformat, rename or refactor anything else.
- Reuse: PageHeader, Section, Field, EmptyState, DetailRow (primitives.tsx); ListSkeleton, ErrorRow (states.tsx); StatusBadge; useActiveOrg, useFormat (org-context.tsx); formatMoney, formatDateTime, zonedInputToUtc, utcToZonedInput (format.ts); lineLabel, taxLabelFromLines (price-lines.ts); friendlyError; invokeFn (payments.ts); useT. Query keys start with ["org", orgId, ...].
- All new text through useT() in BOTH src/i18n/en.json and fr.json. Proper French. No em dashes.
- No screenshots while working. At the end run the type check and the vitest suite once, fix failures, stop.

THE LOOK (applies to every item)
The colour and font tokens in src/styles.css are already set for a quiet-luxury look: warm ivory background, onyx ink, onyx sidebar, one champagne accent (bg-gold, text-gold, border-gold, bg-gold-soft), Cormorant Garamond for display (font-display, and every h1 already uses it), Inter for everything else, utilities eyebrow (small spaced uppercase label) and hairline-gold (thin champagne rule). Do not change the colour values in styles.css. Use the tokens; never hard-code colours.
Principles, taken from Aman, Four Seasons and Blacklane: restraint over decoration; generous space; hairline borders instead of heavy shadows; serif only for headings and large money figures; small uppercase eyebrow labels above groups; champagne only for the single most important action or active state on a screen; no gradients except hairline-gold; no emoji; calm motion (fade-up only).

1. LUXURY POLISH (UI only, no logic changes)
- PageHeader: optional eyebrow prop rendered above the title; title text-3xl. Section titles: font-display text-xl.
- Button: add variant "gold" (bg-gold, text-gold-foreground, hover slightly darker). Use it only for: Request a ride, Accept and confirm, Pay now, and Create booking.
- Tables (bookings, customers, drivers, dispatch list, reports): header cells use eyebrow, rows h-12, hover bg-muted/50.
- Large totals (booking total, quote panel total, invoice total, Today money tiles) in font-display text-3xl tnum.
- AuthLayout (login, signup, reset, onboarding): split screen on desktop. Left half bg-sidebar with BrandMark, a serif line "Every journey, impeccably run." (translate), an eyebrow line "Chauffeur · Limousine · Shuttle", and hairline-gold. Right half: the form on bg-background. Phone: form only, BrandMark on top.
- Public booking pages (portal-shell, book.$slug, status page): onyx hero band (bg-sidebar, ivory text) with the operator logo (or initials) and name in serif; the form card overlaps the band by 48px; step indicator uses gold for the current step. When the operator has brand_color, set it as --gold on the portal root so their colour replaces champagne there only.
- Vehicle class choice on the portal: cards with name in serif, seats and luggage icons, price "from" when known, selected card has border-gold and bg-gold-soft.
- Today page: greeting in serif with the time of day and the user's first name ("Good evening, Sohail"), KPI tiles with eyebrow labels.
- EmptyState title in font-display text-xl.

2. ADDRESS SEARCH, DISTANCE AND MAPS (free, no API key)
New: src/lib/maps.ts, src/components/app/address-field.tsx, src/components/app/route-map.tsx. Add the npm package maplibre-gl (version 5).
All map calls go through src/lib/maps.ts so we can switch to Google later by changing that one file. Export:
  searchPlaces(input, {lang, near:{lat,lng}?, country?}) -> [{id, label, secondary, lat, lng, airport}]
  routeBetween(points:[{lat,lng}]) -> {km, miles, minutes, line: GeoJSON LineString} | null
Implementation now (free OpenStreetMap services, called straight from the browser):
- Search: GET https://photon.komoot.io/api/?q={input}&limit=6&lang={en|fr|de, else omit}&lat={near.lat}&lon={near.lng}. Results are GeoJSON features; coordinates are [lng, lat]. label = name, or "housenumber street" when there is no name; secondary = city, state, country joined with commas. airport = properties.osm_key "aeroway" and osm_value "aerodrome" or "terminal". Drop duplicates by label + secondary. If the operator country is known, sort results in that country first.
- Route: GET https://router.project-osrm.org/route/v1/driving/{lng,lat;lng,lat;...}?overview=full&geometries=geojson. distance is metres, duration is seconds. Times are typical driving times without live traffic: label them "About 32 min drive".
- Be a good citizen: debounce search 350 ms, minimum 3 characters, cancel the previous request (AbortController), cache results in memory for the session, never call in a loop. If a call fails or times out (5 s), return [] or null silently and let the user type freely.
- "near" for search bias: the operator's last used pickup coordinates if any, otherwise none.
AddressField: text input with a suggestion list (arrow keys, Enter, Escape). On pick its value becomes {address, lat, lng, airport}. Typing after a pick clears lat and lng. It always works as plain text if no suggestion is chosen.
Distance: when pickup, drop-off and any stops all have coordinates, call routeBetween (points in order) and fill distance in the operator unit (km or miles) plus "About N min drive". Staff can overwrite the distance. On the portal, hide the distance field when it was filled from the route and show it as a normal input when it was not.
RouteMap: MapLibre map with the style https://tiles.openfreemap.org/styles/positron, markers for pickup (onyx), stops (grey) and drop-off (champagne, var(--gold)), the route line in onyx at 3 px, fitted to bounds with 40 px padding, no scroll zoom until clicked, 220 px tall on phones and 280 px on desktop, rounded with a hairline border. Keep MapLibre's attribution control visible (required by OpenStreetMap and OpenFreeMap) and add "Routing: OSRM" to it. Load the map lazily (dynamic import) so pages without a map stay light.
Use AddressField for pickup, drop-off and stops in: src/routes/_authenticated/_staff/bookings/new.tsx, src/components/app/booking-edit-dialog.tsx (pickup and drop-off only), src/routes/book.$slug.tsx. Show RouteMap under the price on the staff new booking form, in the review step on the portal, and on the booking detail trip card when the trip has coordinates (fetch the route on view; show nothing if it fails).

3. TRIP BUILDER (staff new booking and the portal)
Files: bookings/new.tsx, book.$slug.tsx, src/lib/portal.functions.ts. New: src/lib/trip.ts (shared types and the JSON builder), src/components/app/price-breakdown.tsx.
- Trip type segmented control: One way | Round trip | Hourly. Round trip shows Return date and time (must be after pickup).
- Stops: "Add a stop" (up to 5), each an AddressField, with move up, move down and remove.
- Airport details appear when either address came back with airport true, or when "Airport pickup" is ticked: flight number, airline (optional), Meet and greet checkbox.
- Passengers and luggage steppers; amber note when they exceed the class seats or luggage.
- Notes to the chauffeur (textarea, 1000 chars).
- Live price from price_trip(p_org uuid, p jsonb) for staff and public_price_trip(p_slug text, p jsonb) on the portal (add a server function publicPriceTrip in portal.functions.ts like the existing ones). Debounce 300 ms. price-breakdown.tsx renders lines (lineLabel), subtotal, tax (tax_label), total. Discount lines show in ok colour with a minus sign.
- p JSON (exact keys): class_id, service ("one_way" | "hourly"), distance, hours, round_trip, stops (count, for pricing), stops_list [{address, lat, lng}], extras [{id, qty}], promo_code, tip_percent, pickup_at (ISO, from zonedInputToUtc in the operator timezone), return_at, pickup_address, pickup_lat, pickup_lng, dropoff_address, dropoff_lat, dropoff_lng, flight_number, airline, meet_greet, notes, passenger_count, luggage_count, passenger_name, passenger_phone, customer_notes. Staff also: status ("confirmed" or "quoted"). Portal also: booker_name, booker_email, booker_phone.
- Staff submit: create_booking_v2(p_org, p_booker, p) with two buttons: "Create booking" (status confirmed, gold) and "Save as quote" (status quoted). Open the new booking.
- Portal submit: public_create_booking_v2(p_slug, p) through a new server function; returns {public_code, total, currency}; go to the status page as today.
- Hourly: show "Minimum N hours" under the hours field when the rate card has min_hours (read from the price lines description; do not query rate_cards on the portal).

4. EXTRAS, PROMO CODES, GRATUITY
Files: src/routes/_authenticated/_staff/pricing.tsx, settings.tsx, the two booking forms.
- Pricing page, new Section "Extras": table of extras (name, price, taxable, max qty, active, sort), add, edit inline, delete with confirm. Examples as placeholder text: Child seat, Meet and greet, Bottle of champagne.
- Pricing page, new Section "Promo codes": code, type (percent or fixed), value, starts, ends, max uses, used (read only), active. Add, edit, deactivate. Code input forced upper case.
- Rate card editor on the pricing page: add columns "Per extra stop" (per_stop) and "Minimum hours" (min_hours, hourly rows only).
- Settings: "Default gratuity %" (orgs.default_tip_percent) and "Quotes valid for (hours)" (orgs.quote_valid_hours), owners and admins.
- Booking forms: extras as a list with a checkbox and a qty stepper up to max_qty (portal reads extras from public_operator); promo code field with Apply; show "Applied, saves X" or the reason: invalid "This code is not valid", expired "This code has expired", not_started "This code is not active yet", used_up "This code has been fully used". Portal only: gratuity chips 0, 10, 15, 20 % and Custom, preselected to default_tip_percent. Staff: gratuity % input.

5. QUOTES CUSTOMERS ACCEPT ONLINE
Files: bookings/$id.tsx, bookings/index.tsx, book.$slug_.status.$code.tsx, portal.functions.ts.
- Bookings list: a "Quotes" filter (status quoted), and a "Sent" or "Expired" hint from quote_sent_at and quote_expires_at.
- Booking detail when status is quoted: "Send quote" calls send_quote(p_booking) (returns the public code), copies the status link and toasts "Quote link copied. Valid until {time}". "Confirm now" calls confirm_booking(p_booking). Show "Quote sent {time}, expires {time}" when sent.
- Status page: public_booking_status now also returns lines, subtotal, tax_total, can_accept, quote_expires_at, round_trip, return_at, stops, flight_number, meet_greet, passenger_count, luggage_count and operator {name, logo_url, brand_color}. Show the price breakdown always. When can_accept: gold "Accept and confirm" calls public_accept_quote(p_slug, p_code) through a new server function, then refetch; the existing Pay box shows after confirmation. When quoted, sent and expired: "This quote has expired. Contact {operator} for a new one." When quoted and not sent: "Your request is with {operator}. You will receive a quote shortly."
- Also show on the status page: return trip time, stops, flight and meet and greet, passengers and luggage.

6. OPERATOR BRANDING
Files: settings.tsx, invoice-view.tsx, portal-shell.tsx, app-shell.tsx (org badge only).
- Settings Section "Brand": logo upload to the Supabase storage bucket "branding" at path `${orgId}/logo-${Date.now()}.${ext}` (png, jpg, webp or svg, max 1 MB), then save the public URL to orgs.logo_url. Preview, Replace, Remove. Brand colour picker (hex, orgs.brand_color) with a live preview chip and Reset.
- Use the logo: portal hero, status page, invoice header (InvoiceData.org gains logo_url), and the sidebar org badge (img in the 28 px tile when set).

7. ROUND TRIPS AND STOPS ON THE BOOKING PAGE AND DISPATCH
Files: bookings/$id.tsx, dispatch.tsx.
- A booking can now have two trips (leg "outbound" and "return"). The booking page lists every trip as its own card (Outbound, Return) with its own time, addresses, status, driver, Assign and status actions. Stops (trip_stops, ordered by seq) show between pickup and drop-off on the timeline. Show flight, airline, meet and greet, passengers, luggage and notes in the trip card.
- Dispatch cards: small badges "Return", "Airport" (flight_number set), "{n} stops".
- Edit (booking-edit-dialog) stays one-way only: when round_trip is true, hide class, service and distance edits and show "Round trips: cancel and rebook to change the route."

8. DRIVER PAY RATE
File: src/routes/_authenticated/_staff/drivers/$id.tsx.
- Field "Pay rate (% of fare)" for drivers.pay_percent with hint "Filled in automatically when a trip is completed, unless pay was entered by hand." Owners and admins only.

9. SMALL FIXES
- On booking detail, cancelled bookings show "Balance due" as 0 and hide payment actions.
- French time format: when the language is French, show 24 hour times (8 h 30, 18 h 00) regardless of the operator's 12 hour setting.

ACCEPTANCE (check in code, then report)
1. Login and the portal show the split-screen and hero designs; champagne appears only on the main action.
2. Typing "Pearson" in pickup suggests Toronto Pearson International Airport (marked as an airport); choosing pickup and drop-off fills the distance and draws the route on the map; with the network blocked the field still works as plain text.
3. A round trip with 2 stops, a child seat, promo SAVE10 and 15% gratuity shows the same total on the form as on the created booking.
4. Portal request, then Send quote, then Accept and confirm on the status page, ends confirmed.
5. Uploading a logo shows it on the portal, the invoice and the sidebar.
6. A round trip booking shows two trip cards, each assignable to a different driver.

When done, reply with only: files changed, anything added to docs/ASSUMPTIONS.md, type check and test results.
```
