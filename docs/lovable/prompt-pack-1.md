# Lovable prompt pack 1: operator web, Day 1 and 2

Paste one prompt at a time. Wait for it to finish and check it before the next. Table and function names below are the real ones in `supabase/migrations`. Lovable must not invent others.

Prompt 0 (once, before the others):

```
This app is the operator web for a multi-operator chauffeur and limo platform. It uses the connected Supabase project. Use the Supabase JS client with the anon key only. Row-level security already protects the data, so do not add your own tenant filtering as a security measure. Do not create or alter database tables or policies; the schema is managed in the repo's supabase/migrations folder. If a screen needs a table or function that does not exist, tell me instead of creating it.

Use English and French from the start with a translation file per language and a language switcher. Do not add other languages yet. Format money with Intl.NumberFormat using the operator's currency, and times in the operator's timezone using its 12 or 24-hour setting.

Style: clean, calm, professional. Neutral greys, one deep navy accent, generous spacing, no gradients.
```

Prompt 1: sign-in and operator sign-up

```
Build email and password sign-in and sign-up with Supabase Auth.

After a new user signs up, show a one-screen "Create your company" form with: company name, URL slug (lowercase letters, numbers, hyphens), country (CA, US, GB, DE, FR, ES, IT), currency (USD, CAD, GBP, EUR), language (en or fr), timezone, units (metric or imperial), 24-hour clock (toggle), and tax preset.

Tax preset options come from the table tax_presets filtered by the chosen country. Show label and rate. Default to the first option.

On submit call the RPC create_operator with parameters p_name, p_slug, p_country, p_currency, p_locale, p_timezone, p_unit_system, p_clock_24h, p_tax_preset. It returns the new org id. Then go to the bookings page.

If a signed-in user already has a row in memberships with role owner, admin or dispatcher, skip the form and go to the bookings page. Show a clear error if the slug is taken.
```

Prompt 2: bookings list

```
Build a Bookings page for the signed-in operator staff member.

Load the person's org from memberships (role owner, admin or dispatcher) and orgs. Show a table of bookings (table bookings) newest first with columns: number, passenger_name, service_type, status, total with currency, payment_status, created_at. Add a status filter and a search box on passenger_name.

Clicking a row opens a detail page showing the booking, its booking_lines (description, amount, tax_amount), and its trip from the trips table (pickup_at, pickup_address, dropoff_address, status).

Add a "New booking" button.
```

Prompt 3: new booking with live quote

```
Build the New booking page.

Fields: passenger name, passenger phone, booker (pick or create a row in contacts for this org), service type (one_way or hourly), vehicle class (from vehicle_classes for this org), pickup date and time, pickup address, dropoff address (one_way only), distance (one_way only, in the operator's unit), hours (hourly only).

As the fields change, call the RPC quote_price with p_org, p_class, p_service, p_distance, p_hours and show the returned lines, subtotal, tax_total and total. The RPC returns JSON with currency, tax_label, lines, subtotal, tax_total and total. Show tax_label next to the tax amount.

On "Create booking" call the RPC create_booking with p_org, p_booker, p_passenger_name, p_passenger_phone, p_service, p_class, p_pickup_at, p_pickup_address, p_dropoff_address, p_distance, p_hours. It returns the booking id. Then open that booking's detail page.

Show RPC errors in plain language.
```

Check after prompt 3: with a Sedan, one_way and 30 km, the Alpha-style test operator (Canada, CAD, Ontario HST) must show 120.00 + 15.60 = 135.60 CAD.
