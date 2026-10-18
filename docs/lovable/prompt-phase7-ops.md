# Lovable prompt: Phase 7, operations depth

Before pasting: run `0007_stripe.sql`, `0008_tax_precision.sql` and `0009_ops_depth.sql` in the Supabase SQL Editor (see `docs/SETUP.md`). Lovable regenerates its database types from the live project, so the new functions must exist first. Paste the block below as one message, in normal mode (not chat or plan mode).

---

```
Build all 8 items below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, pick the simplest option that fits the existing code and write it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or functions. Everything you need already exists in the database. If something truly is missing, note it in docs/ASSUMPTIONS.md and build the rest.
- Touch only the files named below plus new files. Do not reformat, rename or refactor files you are not changing.
- Reuse what exists: PageHeader, Section, Field, EmptyState, DetailRow (src/components/app/primitives.tsx); ListSkeleton, ErrorRow (src/components/app/states.tsx); StatusBadge; useActiveOrg and useFormat (src/lib/org-context.tsx); formatMoney, formatDateTime, zonedInputToUtc, utcToZonedInput (src/lib/format.ts); lineLabel, taxLabelFromLines (src/lib/price-lines.ts); friendlyError (src/lib/errors.ts); useT (src/i18n). Query keys start with ["org", orgId, ...].
- Every new piece of text goes through useT() with keys in BOTH src/i18n/en.json and src/i18n/fr.json. Proper French, no machine-style phrasing. No em dashes anywhere.
- Do not take screenshots to check your work. When all 8 items are done, run the type check and the vitest suite once, fix any failures, then stop.
- Same look as the rest of the app: calm, clean, generous spacing, works on a phone.

NEW DATABASE FUNCTIONS (already live)
- reprice_booking(p_booking uuid, p_class uuid, p_service text, p_distance numeric, p_hours numeric) returns jsonb {subtotal, tax_total, total, paid, currency}. Staff only. Replaces fare and surcharge lines from the current rate card. Fails if the trip has started.
- cancel_booking(p_booking uuid, p_reason text) returns void. Staff only. Cancels the booking and its open trips and stores the reason in audit_log (action 'cancel_booking', entity_id = booking id, detail.reason).
- link_customer_account() returns integer. For the signed-in user: links every contact with the same email to them, makes them a customer of those companies, returns how many bookings they now have.
- New orgs columns: billing_address, tax_number, invoice_footer (all text, nullable).

1. EDIT, DUPLICATE AND CANCEL A BOOKING
File: src/routes/_authenticated/_staff/bookings/$id.tsx. New: src/components/app/booking-edit-dialog.tsx.
- "Edit" button (only while the trip status is unassigned, offered or assigned). Dialog fields: pickup date and time (operator timezone), pickup address, drop-off address, passenger name, passenger phone, vehicle class, service type (one_way or hourly), distance or hours.
- Save: update trips (pickup_at, pickup_address, dropoff_address) and bookings (passenger_name, passenger_phone) directly. If class, service, distance or hours changed, then call reprice_booking. Show "Price changed from X to Y" in the toast when the total changes. If the booking is already part paid and the new total is lower than paid, show a warning in the dialog before saving.
- "Duplicate" button: small dialog asking only for the new pickup date and time, then create_booking with the same booker, passenger, class, service, addresses, distance and hours. Open the new booking.
- Replace the current cancel action with cancel_booking: dialog with an optional reason (textarea) and a red confirm button. Show the reason on the booking page under the status when the booking is cancelled (read it from audit_log).

2. INVOICE AND RECEIPT
New: src/components/app/invoice-view.tsx (pure display, takes data as props) and src/routes/_authenticated/_staff/bookings/$id_.invoice.tsx.
- Content: company name, billing_address and tax_number (when set); "Invoice" with number = booking number, issue date, due "On receipt"; bill-to booker name and email; trip date, pickup and drop-off; price lines with lineLabel; subtotal, tax with taxLabelFromLines, total; amount paid; balance due. A clear "PAID" mark when payment_status is paid, then the title reads "Receipt". invoice_footer at the bottom.
- "Print or save as PDF" button calls window.print(). Add print styles so the app sidebar, header and buttons are hidden and the invoice fills an A4 or Letter page in black on white.
- Link to it from the booking page ("Invoice").
- Settings (src/routes/_authenticated/_staff/settings.tsx): new Section "Invoice details" with billing address (textarea), tax number, invoice footer. Owners and admins edit; others read only.

3. DISPATCH: WEEK VIEW, FILTERS, CLASH WARNING
Files: src/routes/_authenticated/_staff/dispatch.tsx, src/components/app/assign-dialog.tsx.
- Day / Week toggle and previous / today / next buttons. Week view: 7 columns, trips as compact cards sorted by pickup time, colour by status, click opens the booking. Phone width: the week becomes a vertical list grouped by day.
- Filters: status, driver, vehicle class. Keep the choice in the URL search params.
- In the assign dialog, when the chosen driver or vehicle already has another trip (not cancelled, completed or no_show) whose pickup is within 3 hours of this one (or overlaps using duration_hours when set), show an amber warning naming that trip and time. Still allow assigning.

4. REPORTS: DRIVER EARNINGS, RIDE LOG, ACCOUNTING EXPORT
File: src/routes/_authenticated/_staff/reports.tsx. New: src/lib/csv.ts.
- Tabs: Revenue (existing), Driver earnings, Ride log. Same date-range picker for all.
- Driver earnings: per driver, completed trips count and sum of trip_costs.driver_pay in range. Total row.
- Ride log: trips in range with booking number, passenger, driver, vehicle, and the times of each status from trip_events (en route, arrived, on board, completed). Show "Edited price" when there is a 'repriced' event.
- "Export CSV" on each tab. Plus an "Accounting export" button producing one row per booking in range with columns: Date, Invoice No, Customer, Description, Amount, Tax, Total, Currency, Status (works for QuickBooks and Xero import). src/lib/csv.ts: toCsv(rows, columns) with correct quoting, a UTF-8 BOM so Excel opens accents correctly, and downloadCsv(name, text). Add a vitest test for quoting commas, quotes and new lines.

5. BULK BOOKING IMPORT
New: src/routes/_authenticated/_staff/bookings/import.tsx. Link "Import" next to "New booking" on src/routes/_authenticated/_staff/bookings/index.tsx.
- "Download template" gives a CSV with headers: pickup_date (YYYY-MM-DD), pickup_time (HH:MM, 24h), passenger_name, passenger_phone, booker_name, booker_email, vehicle_class, service (one_way or hourly), pickup_address, dropoff_address, distance, hours. Two example rows.
- Upload a CSV (add a parseCsv to src/lib/csv.ts and test it). Preview table with a check or error per row: missing fields, bad date, unknown vehicle class (match by name, case-insensitive), service not one_way or hourly, hourly without hours.
- "Import N bookings" runs valid rows one at a time: find a contact in this company by email (else by name), otherwise insert one; then create_booking with pickup_at from zonedInputToUtc in the operator timezone. Progress bar, per-row result, link to each new booking. Stop button. Never import a row twice if the user clicks again.

6. EMBEDDABLE BOOKING WIDGET
Files: src/routes/book.$slug.tsx, src/routes/book.$slug_.status.$code.tsx, src/components/app/portal-shell.tsx, settings page.
- When the URL has ?embed=1: hide the portal header and footer, transparent page background, no outer padding, and keep embed=1 on the link to the status page.
- Settings: new Section "Booking widget" showing a ready-to-copy snippet with a Copy button: <iframe src="{origin}/book/{slug}?embed=1" style="width:100%;height:780px;border:0" title="Book a ride"></iframe>, plus the plain booking link and an "Open" button.

7. CUSTOMER WEB PORTAL
New: src/routes/_authenticated/my-trips.tsx and src/routes/_authenticated/my-trips_.$id.tsx. Files: src/routes/login.tsx, src/routes/_authenticated/_staff/route.tsx, src/routes/book.$slug_.status.$code.tsx.
- Login page: a second tab "Book with a company? Get a sign-in link" with just an email field. Use supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: origin + "/my-trips" } }). Show "Check your email" afterwards.
- Booking status page: small link "See all your trips" to /login with the customer tab open.
- My trips: on first load call link_customer_account() once, then list the user's bookings (row-level security already limits them) with org name, trip date and time in that company's timezone, pickup to drop-off, status, total in that company's currency, payment status. Group as Upcoming and Past. Build the format context from each booking's org (formatMoney, formatDateTime), not from useFormat.
- Each card: "Pay now" when there is a balance, linking to /book/{org slug}/status/{public_code} (payment already works there); "Receipt" opening /my-trips/{id}, which shows invoice-view with a Print button.
- Empty state: "We could not find trips for {email}. Use the same email you gave when booking." plus a small "Run a limo company? Create your account" link to /onboarding.
- Redirects in src/routes/_authenticated/_staff/route.tsx: a user with no staff role but a customer role goes to /my-trips; a driver-only user still goes to /app-only; nobody else changes. A brand-new user arriving from the email link must land on /my-trips, not onboarding.
- My trips is reachable from the user menu for anyone who has a customer membership.

8. SMALL FIXES
- Booking detail: a "Send link" copy button for the customer status page (/book/{slug}/status/{public_code}).
- Bookings list: add a pickup date range filter and a "Cancelled" status filter option.

ACCEPTANCE (check these in code, then report)
1. Edit a confirmed booking from Sedan to SUV: total changes and the toast shows old and new totals.
2. Cancel with reason "Client changed plans": booking and trip show cancelled and the reason is visible.
3. Invoice prints on one page with no sidebar, in English and French.
4. Week view shows next week's trips; assigning a driver who has a trip 1 hour later shows the warning.
5. Accounting export opens in Excel with accents intact.
6. Importing the template's two example rows creates two bookings in the operator timezone.
7. /book/demo-toronto?embed=1 shows only the booking form.
8. A customer with a past booking signs in by email link, lands on My trips and sees it with Pay now and Receipt.

When done, reply with only: the list of files changed, anything you wrote in docs/ASSUMPTIONS.md, and the type check and test results. No other summary.
```
