# Lovable master prompt: operator web and booking portal, v1

How to use: copy everything between the two `=====` lines into Lovable as ONE message. Lovable works through it in the build order in section 11. When it stops, reply "Continue with the next phase in the build order" until all phases are done. Then run the acceptance test in section 12.

=====

# Build: Limo Platform operator web app and public booking portal

You are building the web app for a multi-operator chauffeur, limo and shuttle platform for the US, Canada, UK and EU. Many independent operators (limo companies) use one shared Supabase database. Each operator sees only its own data. The mobile apps for drivers and customers are built separately; you build the web.

Two audiences:
1. **Operator staff** (owner, admin, dispatcher): sign in and run their business: bookings, dispatch, drivers, fleet, pricing, customers, partners, reports, team, settings.
2. **The public**: book a car from an operator's booking page at `/book/:slug` without signing in.

## 1. Hard rules (read first, follow throughout)

1. **Do not create, alter or drop any database table, column, view, policy, trigger or function.** The schema is final for this phase and lives in the repo under `supabase/migrations`. Never write SQL migrations. If a screen genuinely needs something that does not exist, do not invent it: build the screen without it, and add a line to a file `BACKEND_REQUESTS.md` in the repo root describing what is missing and why.
2. **Use only the tables, columns and functions listed in sections 4 and 5.** Never guess a column name. If a name is not in this brief, it does not exist.
3. Use the connected Supabase project through the Supabase JS client with the **anon key only**. Never use or ask for the service role key.
4. **Security is enforced by row-level security in the database.** You do not need to filter by operator for safety, but DO filter queries by the active `org_id` so a user who belongs to two operators sees one at a time.
5. **All business actions go through the database functions in section 5** (`create_operator`, `quote_price`, `create_booking`, `assign_trip`, `update_trip_status`, and the others). Never recompute prices or taxes in the browser; display what the functions return.
6. Money: columns are numeric and arrive as strings. Convert with `Number()`. Format with `Intl.NumberFormat(locale, { style: 'currency', currency })` using the booking's or operator's currency. Never add currency symbols by hand.
7. Times: store and send UTC ISO strings. Display and enter all times in the **operator's timezone** (`orgs.timezone`) and its clock setting (`orgs.clock_24h`: true = 24-hour, false = 12-hour). When a user enters a pickup time, interpret it in the operator's timezone, then convert to UTC before sending. Use `date-fns` and `date-fns-tz` for this.
8. Distances: `orgs.unit_system` is `metric` (km) or `imperial` (miles). Label distance inputs and outputs with the right unit. Values are stored in that unit; do not convert.
9. Languages: English and French only, with full translation files (`en.json`, `fr.json`) and a language switcher in the header and on the booking portal. Default to the operator's `default_locale` for the portal and to the browser language (if fr, else en) for staff. Every visible string goes through the translation function. No other languages yet.
10. Show database errors in plain language in a toast or inline message. Never show raw stack traces. Common cases: duplicate slug on sign-up ("That web address is taken"), `no rate card for this vehicle class and service`, `cannot move trip from X to Y`.
11. Do not build: Stripe or any real card payment, maps, live GPS, SMS or email sending, a driver mobile app, a customer mobile app. These come later.

## 2. Product and design direction

The product competes with Moovs and Limo Anywhere by being calmer and cleaner. Operators are busy dispatchers, often on a laptop all day. Optimise for scanning and speed.

- Look: professional, consulting-grade. Neutral greys, white surfaces, one deep navy accent `#1F3A5F`, status colours used sparingly (amber for needs attention, green for done, red for problems). No gradients, no stock illustrations, no emoji.
- Type: Inter or the system font. Tabular figures for money and times.
- Layout: left sidebar navigation, top bar with operator name, operator switcher (only if the user is staff at more than one operator), language switcher, user menu with sign out.
- Tables: dense but readable rows, sticky headers, a search box and filters above, empty states that say what to do next.
- Forms: labels above fields, inline validation, primary action bottom right, keyboard friendly.
- Responsive: works on a 13-inch laptop first, usable on a tablet, the booking portal must work well on a phone.
- Use shadcn/ui components and Tailwind.

## 3. Roles and what they can do

Roles live in `memberships.role`: `owner`, `admin`, `dispatcher`, `driver`, `customer`.

- Staff = owner, admin, dispatcher. They can use the whole operator web app.
- Only owner and admin can: edit Settings, manage Team, edit Pricing and tax rates. Hide those actions from dispatchers (the database also blocks them).
- Drivers and customers who sign in to the web see a simple page: "This account is for the mobile app. Download it to continue." with a sign-out button. They do not get the operator web.

Active operator: after sign-in, load the user's active staff memberships. If none, go to onboarding. If one, use it. If several, show a chooser and remember the choice in localStorage. Expose `activeOrg` (the full `orgs` row) through a React context; every page reads `org_id`, `timezone`, `clock_24h`, `unit_system`, `default_currency` from it.

## 4. Database reference (tables and columns you may use)

All `id` columns are uuid. Every operator-owned table has `org_id`. Timestamps are timestamptz.

**Reference data (read-only, everyone):**
- `plans`: id (text: starter, growth, scale), name, seat_limit, features (jsonb), sort_order
- `currencies`: code (USD, CAD, GBP, EUR), symbol, minor_unit
- `locales`: code (en, fr, es, de, it), name, status (`live` or `review`; offer only `live`)
- `tax_presets`: code, country, region, label, rate (0.13 = 13%), kind (VAT, GST, HST, SALES_TAX, NONE)

**Tenancy:**
- `orgs`: id, name, slug, country, timezone, default_currency, default_locale, unit_system, clock_24h, plan_id, trial_ends_at, stripe_account_id, listed_in_network, created_at
- `profiles`: id (= auth user id), full_name, phone, locale, created_at
- `memberships`: id, org_id, user_id, role, active, created_at

**Operator setup:**
- `tax_rates`: id, org_id, code, label, rate, kind, is_default (exactly one default per operator)
- `vehicle_classes`: id, org_id, name, seats, luggage, sort_order
- `vehicles`: id, org_id, class_id, label, plate, active, created_at
- `drivers`: id, org_id, user_id (null if the driver has no app login yet), full_name, phone, status (`offline`, `available`, `busy`), active, created_at
- `driver_documents`: id, org_id, driver_id, kind (text: licence, insurance, inspection), expires_on (date)
- `rate_cards`: id, org_id, class_id, service_type (`one_way`, `hourly`), currency, base_amount, per_distance, per_hour, minimum_amount. Unique per (org_id, class_id, service_type, currency).
- `surcharges`: id, org_id, name, amount_type (`fixed` or `percent`; percent is a fraction, 0.10 = 10%), amount, active

**Customers:**
- `accounts` (corporate clients): id, org_id, name, created_at
- `contacts` (bookers and passengers): id, org_id, account_id, user_id, full_name, email, phone, created_at

**Orders:**
- `bookings`: id, org_id, number (integer, show as #number), public_code (8 characters, shown to customers), booker_id (contacts.id), account_id, passenger_name, passenger_phone, service_type, class_id, status (`quoted`, `confirmed`, `in_progress`, `completed`, `cancelled`), currency, subtotal, tax_total, total, paid_amount, payment_status (`unpaid`, `partial`, `paid`, `refunded`), created_at. `subtotal`, `tax_total`, `total`, `paid_amount` and `payment_status` are maintained by the database; never write them.
- `booking_lines`: id, org_id, booking_id, kind (`fare`, `surcharge`, `extra`, `tip`), description, amount, tax_rate_id, tax_amount. Inserting, updating or deleting a line updates the booking totals automatically.
- `trips`: id, org_id, booking_id, pickup_at, pickup_address, pickup_lat, pickup_lng, dropoff_address, dropoff_lat, dropoff_lng, distance, duration_hours, vehicle_id, driver_id, status (`unassigned`, `offered`, `assigned`, `en_route`, `arrived`, `on_board`, `completed`, `no_show`, `cancelled`), created_at. Never update `status` directly; use the functions.
- `trip_events`: id, org_id, trip_id, status, actor_id, lat, lng, created_at (history, read-only for you)
- `trip_costs` (staff only): trip_id (primary key), org_id, driver_pay, partner_cost. Upsert on trip_id.
- `payments`: id, org_id, booking_id, provider (default `stripe`; use `manual` for recorded payments), provider_ref, amount, currency, status (`pending`, `succeeded`, `failed`, `refunded`), created_at. Inserting a `succeeded` payment updates the booking's paid_amount and payment_status automatically.
- `farm_outs`: id, from_org_id, to_org_id, trip_id, partner_price, status (`offered`, `accepted`, `declined`, `cancelled`), created_at
- `audit_log` (read-only): id, org_id, actor_id, action, entity, entity_id, detail, created_at

**Views:**
- `trip_margin` (staff only): trip_id, org_id, booking_id, currency, revenue, driver_pay, partner_cost, margin. Revenue excludes tax. Only trips with a `trip_costs` row appear.

## 5. Database functions (call with `supabase.rpc(name, params)`)

Parameter names must match exactly.

| Function | Params | Returns | Use |
|---|---|---|---|
| `create_operator` | p_name, p_slug, p_country, p_currency, p_locale, p_timezone, p_unit_system, p_clock_24h, p_tax_preset | uuid (new org id) | Onboarding. Creates the operator, makes the caller owner, starts a 14-day trial, copies the country's tax rates, creates Sedan, SUV and Van classes with starter rate cards. |
| `quote_price` | p_org, p_class, p_service, p_distance, p_hours, p_tax_rate (optional) | jsonb: currency, tax_rate_id, tax_label, lines[ {kind, description, amount, tax_amount} ], subtotal, tax_total, total | Live price on the new booking form. |
| `create_booking` | p_org, p_booker, p_passenger_name, p_passenger_phone, p_service, p_class, p_pickup_at, p_pickup_address, p_dropoff_address, p_distance, p_hours | uuid (booking id) | Staff creates a confirmed booking with its lines and one trip. |
| `assign_trip` | p_trip, p_driver, p_vehicle (optional) | void | Dispatch. Sets driver and vehicle, status `assigned`. |
| `update_trip_status` | p_trip, p_status, p_lat (optional), p_lng (optional) | void | Moves a trip. Staff may cancel any trip before the passenger is on board. Allowed flow: assigned → en_route → arrived → on_board → completed; arrived → no_show; unassigned/offered/assigned/en_route/arrived → cancelled. Booking status follows automatically. |
| `network_directory` | none | rows: id, name, slug, country | Operators open to partner work. |
| `team_members` | p_org | rows: membership_id, user_id, email, role, active, created_at | Team page. |
| `add_member_by_email` | p_org, p_email, p_role (`admin`, `dispatcher`, `driver`, `customer`), p_driver_name (optional) | text: `added`, `already_member` or `no_account` | Owner/admin adds someone who has already signed up. For `driver` it also creates the drivers row. On `no_account`, tell the user: "This person needs to create an account first (in the app or at /signup), then add them again." |
| `public_operator` | p_slug | jsonb: name, slug, country, timezone, currency, locale, unit_system, clock_24h, classes[ {id, name, seats, luggage} ], or null | Booking portal header and vehicle list. Works signed out. |
| `public_quote` | p_org_slug, p_class, p_service, p_distance, p_hours | same shape as quote_price | Booking portal price. Works signed out. |
| `public_create_booking` | p_slug, p_class, p_service, p_pickup_at, p_pickup_address, p_dropoff_address, p_distance, p_hours, p_booker_name, p_booker_email, p_booker_phone, p_passenger_name (optional), p_passenger_phone (optional) | jsonb: public_code, total, currency, status (`quoted`) | Booking portal submit. Pickup must be at least 30 minutes ahead. Creates a booking request with status `quoted` that staff then confirm. |
| `public_booking_status` | p_slug, p_code | jsonb: public_code, status, payment_status, total, currency, passenger_name, pickup_at, pickup_address, dropoff_address, trip_status, or null | Booking portal status page. |

## 6. Shared building blocks (build these first)

- `useActiveOrg()` context as described in section 3.
- `formatMoney(amount, currency)`, `formatDateTime(iso)`, `formatTime(iso)`, `formatDistance(value)` helpers that read the active operator's timezone, clock and units and the current language.
- `StatusBadge` for booking status, trip status and payment status, with translated labels and consistent colours: quoted = amber, confirmed = navy, in_progress / en_route / arrived / on_board = blue, completed / paid = green, cancelled / no_show / failed = red, unassigned = amber outline, unpaid = grey, partial = amber.
- `QuotePanel`: takes the quote jsonb and renders lines, subtotal, tax (with tax_label) and total.
- A pickup date-time field that works in the operator's timezone and returns UTC ISO.
- Supabase Realtime subscription helper for `trips`, `trip_events` and `bookings` filtered by `org_id`, with a 30-second polling fallback.

## 7. Pages: operator web (signed in, staff)

### 7.1 Sign-in, sign-up, onboarding
- `/login`: email and password (Supabase Auth). Link to `/signup` and a "Forgot password" flow using Supabase's reset email.
- `/signup`: email, password, full name. After sign-up, upsert `profiles` (id = user id, full_name). If email confirmation is on in Supabase, show "Check your email"; otherwise go straight to onboarding.
- `/onboarding` ("Create your company"), shown when the user has no staff membership: company name, web address slug (auto-suggest from the name; lowercase letters, numbers, hyphens; show the future booking link `/book/<slug>`), country (Canada, United States, United Kingdom, Germany, France, Spain, Italy), currency (preselect by country: CA → CAD, US → USD, GB → GBP, others → EUR), language (en or fr), timezone (preselect from the browser, searchable list), units (preselect imperial for US and GB, metric otherwise), 24-hour clock (preselect off for US and CA, on otherwise), tax preset (from `tax_presets` for the chosen country, showing label and rate as a percent). Submit calls `create_operator`, then go to `/today`.
- Note on screen under tax: "Starting rates only. Passenger transport can have reduced rates in some places; confirm with your accountant." 

### 7.2 Today (`/today`, the home page)
- KPI tiles for today in the operator timezone: trips today, unassigned trips, in progress now, booking requests waiting (bookings with status `quoted`), revenue today (sum of booking totals for trips picked up today, in the operator currency), margin today (sum of `trip_margin.margin` for today's trips).
- "Needs attention" list: unassigned trips in the next 24 hours, booking requests waiting, driver documents expiring in the next 30 days.
- "Next 12 hours" timeline of trips with time, passenger, pickup, driver, status; click opens the booking.

### 7.3 Bookings (`/bookings`)
- Table: #number, created date, pickup time (first trip), passenger_name, service type, vehicle class name, status, total, payment_status. Search on passenger name, number and public code. Filters: status, payment status, date range on pickup. Sort by pickup time by default. Paginate 50 per page.
- Tabs at the top: All, Requests (status `quoted`), Upcoming, Completed, Cancelled.
- "New booking" button.

### 7.4 New booking (`/bookings/new`)
- Booker: search existing `contacts` by name, email or phone, or create one inline (full_name, email, phone, optional account). Optional corporate account selector from `accounts`.
- Passenger name and phone (default to the booker, editable).
- Service type: One way or Hourly.
- Vehicle class: cards from `vehicle_classes` with seats and luggage.
- Pickup date and time (operator timezone), pickup address, drop-off address (one way only), distance in km or miles (one way), hours (hourly).
- Live `QuotePanel` that calls `quote_price` (debounced 400 ms) whenever class, service, distance or hours change.
- "Create booking" calls `create_booking`, then opens the booking detail page with a success toast.

### 7.5 Booking detail (`/bookings/:id`)
- Header: #number, public code, status badge, payment badge, created date.
- Customer card: booker contact, passenger, account.
- Trip card: pickup time, pickup and drop-off, distance or hours, vehicle class, assigned driver and vehicle, trip status, and a status history timeline from `trip_events`.
- Price card: `booking_lines` with subtotal, tax and total; paid amount and balance.
- Actions:
  - If status is `quoted` (portal request): "Confirm booking" (update `bookings.status` to `confirmed`) and "Decline" (call `update_trip_status` with `cancelled` on its trip).
  - "Assign driver": dialog with available drivers and vehicles of the right class, calls `assign_trip`.
  - "Cancel booking": confirm dialog, then `update_trip_status(trip, 'cancelled')`.
  - "Record payment": amount (defaults to balance), method note; inserts into `payments` with provider `manual`, status `succeeded`, provider_ref = the note, currency = booking currency. Label this clearly as recording a payment taken outside the system. Card payments come later.
  - "Driver pay and costs" (staff only): edit `trip_costs.driver_pay` and `partner_cost` for the trip (upsert); show resulting margin from `trip_margin`.
  - "Farm out to partner": see 7.10.
  - "Copy customer link": copies `<site>/book/<slug>/status/<public_code>`.

### 7.6 Dispatch (`/dispatch`)
- Date picker (defaults to today in the operator timezone) and a view toggle.
- Board view: columns Unassigned, Assigned, On the road (en_route, arrived, on_board), Done (completed, no_show, cancelled). Cards show pickup time, passenger, pickup and drop-off, vehicle class, driver.
- Assign from a card with the same dialog as 7.5. Drag from Unassigned onto a driver in a right-hand "Drivers" panel also assigns.
- Status override menu on a card (staff can move a trip forward through the allowed flow, mark no-show, or cancel) using `update_trip_status`. Show only the moves the flow allows.
- Drivers panel: active drivers with status and today's trip count.
- Live: subscribe to `trips` changes for the operator so driver taps from the phone appear without refresh.

### 7.7 Drivers (`/drivers`)
- Table: full_name, phone, status, app login (yes if user_id is set), active, documents expiring soon.
- "Add driver": full_name, phone (inserts into `drivers` without a login).
- "Give app access": email; calls `add_member_by_email(org, email, 'driver', full_name)`. Explain the `no_account` result as in section 5.
- Driver detail: profile edit, documents table (`driver_documents`: kind, expires_on; add, edit, delete; highlight expired in red and expiring within 30 days in amber), upcoming and recent trips.

### 7.8 Fleet (`/fleet`)
- Vehicle classes tab: name, seats, luggage, sort order; add, edit, delete (warn that classes used by bookings cannot be deleted and show the database error nicely if it happens).
- Vehicles tab: label, plate, class, active; add, edit, deactivate.

### 7.9 Pricing (`/pricing`, owner and admin edit, dispatcher read-only)
- Rate cards: a grid with one row per vehicle class and columns for One way (base, per km or mile, minimum) and Hourly (per hour, minimum), in the operator's default currency. Save with upsert on (org_id, class_id, service_type, currency).
- A "Try a price" box: pick class, service, distance or hours, show `quote_price` result.
- Surcharges: name, fixed or percent, amount, active.
- Tax rates: code, label, rate shown as percent, kind, default; exactly one default (when setting a new default, first unset the old one, then set the new one).

### 7.10 Network and partners (`/network`)
- Directory tab: rows from `network_directory()` excluding the operator itself; search by name and country.
- Outgoing tab: `farm_outs` where from_org_id = active org, with trip pickup time and route, partner, partner_price, status. Cancel an offered farm-out (status `cancelled`).
- Incoming tab: `farm_outs` where to_org_id = active org, with the trip details (the partner can read the trip but NOT the booking or customer). Accept (status `accepted`) or Decline (status `declined`).
- From a booking (7.5), "Farm out to partner": choose a partner from the directory, enter partner_price; inserts `farm_outs` (from_org_id = active org, to_org_id, trip_id, partner_price). Also set `trip_costs.partner_cost` to the same price.
- Settings toggle "List my company in the partner directory" maps to `orgs.listed_in_network`.

### 7.11 Customers (`/customers`)
- Contacts tab: name, email, phone, account, number of bookings; add, edit; detail shows their bookings.
- Accounts tab: corporate accounts with their contacts and bookings.

### 7.12 Reports (`/reports`)
- Date range (default this month). Revenue (sum of booking subtotals, excluding tax), tax collected, driver pay, partner cost, margin and margin percent, all from `bookings`, `trips` and `trip_margin`.
- Table per trip from `trip_margin` joined in the browser with `trips` (pickup_at) and `bookings` (number, passenger_name). Export to CSV.
- A simple bar chart of revenue and margin per day (Recharts).

### 7.13 Team (`/team`, owner and admin)
- List from `team_members(org)`: email, role, active, joined.
- "Add team member": email and role; calls `add_member_by_email`.
- Deactivate or reactivate: update `memberships.active`.
- Show plan seat limit from `plans.seat_limit` for the operator's `plan_id` and how many staff seats are used (count of active owner, admin and dispatcher memberships). Warn when over the limit; do not block.

### 7.14 Settings (`/settings`, owner and admin)
- Company: name, timezone, default language, units, 24-hour clock, listed in partner directory. Updates `orgs`.
- Booking page: show the public link `/book/<slug>` with a copy button and a QR code.
- Currency: show `default_currency` read-only with the note "Changing currency needs new rate cards; contact support."
- Plan: plan name and trial end date (`trial_ends_at`) with days remaining. No billing yet.

## 8. Public booking portal (signed out)

### 8.1 `/book/:slug`
- Load `public_operator(slug)`. If null, show a clean "Booking page not found".
- Header: operator name. Language switcher (en, fr), defaulting to the operator's `locale`.
- Step 1, Trip: service (One way or Hourly), pickup date and time (in the operator's timezone; say which timezone), pickup address, drop-off address (one way), approximate distance (one way, in the operator's unit, with the hint "Your operator confirms the final price") or hours (hourly).
- Step 2, Vehicle: class cards from `classes` with seats and luggage, each showing the price from `public_quote` for the entered trip.
- Step 3, Your details: name, email, phone; checkbox "I am booking for someone else" reveals passenger name and phone.
- Review: full `QuotePanel`, the trip summary, and the line "This is a booking request. The operator will confirm it. Payment is arranged with the operator."
- Submit calls `public_create_booking`. On success go to the status page.
- Mobile first. Large tap targets. No sign-in.

### 8.2 `/book/:slug/status/:code`
- Load `public_booking_status(slug, code)`. Show reference code, status in plain words (quoted = "Request received, waiting for confirmation"; confirmed = "Confirmed"; in_progress = "Your driver is on the way"; completed = "Completed"; cancelled = "Cancelled"), pickup time, addresses, passenger, total.
- Refresh every 30 seconds.

## 9. Routing summary

Public: `/login`, `/signup`, `/reset-password`, `/book/:slug`, `/book/:slug/status/:code`.
Staff: `/onboarding`, `/today`, `/bookings`, `/bookings/new`, `/bookings/:id`, `/dispatch`, `/drivers`, `/drivers/:id`, `/fleet`, `/pricing`, `/network`, `/customers`, `/customers/:id`, `/reports`, `/team`, `/settings`.
Signed-in non-staff: `/app-only` page from section 3.

## 10. Quality bar

- Every list has loading, empty and error states.
- Every destructive action has a confirm dialog.
- Every form disables its submit button while saving and shows a toast on success or failure.
- No hard-coded operator, currency, timezone or language anywhere.
- No console errors on any page.

## 11. Build order (work in phases; finish and check each before the next)

1. Shared building blocks (section 6), auth, onboarding, app shell with navigation and operator context, translations.
2. Bookings list, new booking with live quote, booking detail with confirm, cancel, record payment and driver pay.
3. Dispatch board with assign and live updates, Drivers (including app access and documents), Fleet.
4. Pricing, Customers, Today page.
5. Public booking portal and status page.
6. Network and partners, Reports, Team, Settings.

At the end of each phase, list what you built and anything you added to `BACKEND_REQUESTS.md`.

## 12. Acceptance test (run after phase 6)

1. Sign up a new user, create a company in Canada (CAD, Ontario HST, metric, 12-hour clock).
2. Pricing shows Sedan, SUV and Van with starter rates. "Try a price": Sedan, one way, 30 km must show 120.00 + 15.60 HST = 135.60 CAD.
3. Create a booking for that trip. It appears in Bookings as confirmed, 135.60 CAD, unpaid.
4. Add a driver with app access for an existing account. Assign the trip. It appears under Assigned on the Dispatch board.
5. Record a payment of 135.60. The booking shows paid.
6. Set driver pay 70.00. Margin shows 50.00 in the booking and in Reports.
7. Open `/book/<slug>` in a private window, request a booking. It appears under Requests; confirm it; the status page shows Confirmed.
8. Switch the language to French; every visible label changes.

=====

## Notes for Sohail (not part of the prompt)

- Run `supabase/migrations/0004_portal_and_team.sql` in Supabase SQL Editor BEFORE pasting this prompt. Lovable's portal, team and live dispatch pages depend on it.
- Lovable may still offer to "create tables". Decline every such offer; the schema is managed in the repo.
- Expect Lovable to stop after a phase or two. Reply "Continue with the next phase in the build order".
- If Lovable writes to `BACKEND_REQUESTS.md`, send the file contents to Claude.
