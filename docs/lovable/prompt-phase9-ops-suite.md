# Lovable prompt: Phase 9, operations and money suite

Before pasting: run `supabase/migrations/0012_ops_suite.sql` in the Supabase SQL Editor. Paste after 8B has finished. Normal mode, one message.

---

```
Build all 12 items below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, pick the simplest option that fits the existing code and log it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or database functions. All of it exists (migration 0012). Prices, fees, invoices and pay are calculated by the database; never compute money in the browser except for display.
- Touch only the files named here plus new files. No reformatting or refactoring elsewhere.
- Reuse: primitives.tsx, states.tsx, StatusBadge, useActiveOrg, useFormat, friendlyError, useT, can() from permissions.ts, AddressField, RouteMap, price-breakdown.tsx, invoice-view.tsx, csv.ts, the luxury tokens (font-display, eyebrow, bg-gold only for the one main action).
- All new text through useT() in BOTH en.json and fr.json. Proper French. No em dashes.
- Respect roles: hide what can() denies; the database refuses it anyway.
- No screenshots while working. At the end run the type check and vitest once, fix failures, stop.

1. PRICING RULES (src/routes/_authenticated/_staff/pricing.tsx, new src/components/app/pricing-zones.tsx and pricing-rules.tsx)
- Zones section: table zones (name, kind area or airport, centre, radius km). Add or edit in a dialog: name, kind, centre picked with AddressField (stores lat and lng), radius slider 0.5 to 50 km, and a small RouteMap-style MapLibre preview drawing the circle. Delete with confirm.
- Flat rates section: table zone_rates (vehicle class, from zone, to zone, amount, both directions). Add or edit in a dialog. Explain: "A flat rate replaces the distance fare when pickup is in the first zone and drop-off in the second."
- Time and date rules section: table price_rules (name, days as weekday chips Sun to Sat, start and end time (may cross midnight), date from and to (holidays), percent or fixed, amount, active). Examples as placeholders: Night 22:00 to 06:00 +20%, Weekend +10%, New Year's Eve +25.
- Policies section (owners and admins), columns on orgs: airport_fee, wait_per_minute, cancel_free_hours, cancel_fee_percent, no_show_fee_percent.
- The "Try a price" box: add pickup and drop-off AddressFields and a pickup time so zones and rules can be tested; show which zone rate or rules applied (lines with code fare, rule, airport; price_trip also returns zone {from, to} and min_hours).
- In src/lib/trip.ts add pickup_airport and dropoff_airport (from the AddressField airport flag) and accept_terms to the payload builder AND to tripPayloadSchema (otherwise the server strips them).

2. CHARGES AFTER THE TRIP AND CANCELLATION FEES (bookings/$id.tsx, new src/components/app/charges-dialog.tsx)
- "Add charges" (owners, admins, dispatchers, accountants), available on any booking that is not cancelled: rows of type Waiting time (minutes; amount computed by the database from wait_per_minute unless typed), Tolls, Parking, Overtime, Other (description), amount, taxable (tolls and parking default off). Calls add_trip_charges(p_booking, p_items jsonb [{kind, description, amount, minutes, taxable}]). Show the new total in the toast.
- Before cancelling, show cancellation_terms(p_booking) -> {free_until, late, late_fee, no_show_fee, currency}: "Free cancellation until {time}" or "Late cancellation: fee {amount}". After cancelling a late booking, offer "Charge late cancellation fee" which calls charge_cancellation(p_booking, 'late_cancel'). When a trip is marked no-show, offer "Charge no-show fee" (charge_cancellation(p_booking, 'no_show')). Both with confirm dialogs that state the amount.

3. VEHICLE SHOWCASE (src/routes/_authenticated/_staff/fleet.tsx, vehicle-classes.tsx, book.$slug.tsx)
- Vehicle class editor: description (600 chars), amenities as tag chips (suggestions: Wi-Fi, Water, Phone chargers, Leather seats, Child seat available, Wheelchair accessible), up to 6 photos uploaded to storage bucket "vehicles" at `${orgId}/classes/${classId}/${Date.now()}.${ext}` (jpg, png or webp, max 3 MB, resize in the browser to 1600 px wide before upload), saved as public URLs in photo_urls. Reorder and remove photos.
- Vehicles: make, model, year, colour, plate, one photo (same bucket, `${orgId}/vehicles/${id}/...`).
- Portal vehicle step: each class card shows the first photo (16:10, object-cover, rounded), name in serif, seats and luggage icons, amenities as small chips, description on "Details", a photo carousel in the details sheet, and the price for the trip.

4. CUSTOMER RECORDS (customers/$id.tsx, customers/index.tsx, bookings/$id.tsx, bookings/new.tsx)
- Customer page: VIP toggle (champagne star badge everywhere the name shows on staff screens), tags (chips, free text), preferences (textarea), preferred vehicle class, preferred driver.
- Private notes (table notes; contact_id or booking_id; author_id, created_at): a notes panel on the customer page and on the booking page, newest first, with author email and time. Label it "Private to your team".
- Customers list: VIP filter and tag filter.
- New booking: when a booker is chosen, show their VIP badge, preferences and preferred class and driver as a small info card.

5. CORPORATE BILLING (new src/routes/_authenticated/_staff/billing/invoices.tsx, billing/invoices.$id.tsx, billing/ageing.tsx; nav group "Billing" visible to owners, admins and accountants)
- Invoices list: number, client company, period, issued, due, total, paid, status (draft, sent, paid, void), overdue highlight. Filters by status and company.
- "New invoice": client company, period (default last month), calls create_account_invoice(p_account, p_from, p_to) -> invoice id or null ("Nothing to bill for this period").
- Invoice page: header with the operator logo and invoice details (billing_address, tax_number, invoice_footer), bill-to the client company and billing_email, the bookings on it (date, number, passenger, route, total), subtotal, tax, total, paid, balance. Actions: Mark as sent (set_invoice_status 'sent'), Record payment (amount, method bank_transfer, cheque, card or cash, reference; record_invoice_payment), Back to draft, Void (set_invoice_status), Print or save as PDF (same print approach as the booking invoice), Export CSV of lines.
- Ageing page from account_ageing(p_org): company, current, 1 to 30, 31 to 60, 61 to 90, over 90, total; totals row; CSV export.
- Client company page (accounts.$id.tsx): payment terms days (payment_terms_days) and its invoices.
- Corporate client portal (My trips for client_admin): "Invoices" section listing sent and paid invoices with a printable view.

6. DRIVER PAYROLL (new src/routes/_authenticated/_staff/billing/payroll.tsx and billing/payroll.$id.tsx)
- Pay runs list: period, drivers, total, status. "New pay run": period, calls create_pay_run(p_org, p_from, p_to) -> id or null ("No completed trips to pay in this period").
- Pay run page: one row per driver from pay_run_lines (trips, driver pay, tips, adjustment with note editable while draft, total). Driver statement view per driver listing their trips (trip_costs where pay_run_id = run) for printing. Actions: Mark paid (set_pay_run_paid), Delete draft (delete_pay_run), Export CSV.
- Driver page: field "Pay rate (% of fare)" already exists; add their pay run history.

7. RECURRING BOOKINGS (bookings/new.tsx, bookings/$id.tsx)
- On the staff booking form, a "Repeat" toggle: Daily (every 1 to 4 days) or Weekly (every 1 to 4 weeks, weekday chips), until date; live text "This creates N bookings" computed in the browser for display only (max 60). Submit with create_recurring_bookings(p_org, p_booker, p, p_rule {freq, every, days, until}) -> {series_id, count, booking_ids}. Then open the bookings list filtered to the series.
- Booking page: when series_id is set, a "Part of a series" card with a link to the series list and "Cancel this and later bookings" (cancel_series(p_series, p_from date, p_reason)).
- Bookings list: filter by series_id from the URL.

8. AVAILABILITY (drivers/$id.tsx, fleet.tsx, dispatch.tsx, assign-dialog.tsx)
- Driver page: Shifts and time off (table driver_shifts: kind shift or time_off, start, end, note) as a simple list with add and delete, plus a 2-week strip view.
- Vehicle: Out of service periods (table vehicle_blocks: start, end, reason).
- Assign dialog: after choosing driver and vehicle, call assignment_warnings(p_trip, p_driver, p_vehicle) -> [{level, code, message}] and list each in amber under the clash warning (codes time_off, off_shift, vehicle_blocked, driver_document_expired, vehicle_document_expired). Still allow assigning.
- Dispatch day view: grey out drivers on time off that day in the driver filter.

9. COMPLIANCE (drivers/$id.tsx, fleet.tsx, today.tsx)
- Driver documents (driver_documents: kind, number, expires_on, file) and vehicle documents (vehicle_documents: same) with file upload to the private bucket "documents" at `${orgId}/drivers/${driverId}/...` or `${orgId}/vehicles/${vehicleId}/...`, stored as file_path; open with a signed URL (60 s). Status chip: Valid, Expires in N days (amber within 30), Expired (red).
- Today page: "Compliance" card from compliance_alerts(p_org, 30) listing expired and soon-expiring documents with links.

10. RATINGS (book.$slug_.status.$code.tsx, drivers pages, reports.tsx)
- Status page: when can_rate, show 5 stars and an optional comment, then public_rate_booking(p_slug, p_code, p_rating, p_comment) through a new server function; afterwards "Thank you". Show rating when already rated.
- Status page also shows the driver first name and vehicle (make, model, colour, plate) when public_booking_status returns them, and the operator's cancellation policy line (operator.cancel_free_hours, cancel_fee_percent).
- Drivers list: average rating column from driver_ratings(p_org). Reports: a Ratings tab listing trip_ratings with booking number, rating, comment, date.

11. CUSTOMER NOTIFICATIONS (settings.tsx, new src/components/app/notification-settings.tsx and src/routes/_authenticated/_staff/notifications.tsx)
- Settings "Customer messages": if the company has no templates, a button "Use our default messages" (install_default_templates(p_org)). A table of templates (event, channel email or SMS, language, active toggle). Edit dialog: subject (email), body, a list of placeholders to click-insert ({{passenger_name}}, {{pickup_time}}, {{pickup_address}}, {{dropoff_address}}, {{booking_number}}, {{total}}, {{driver_name}}, {{vehicle}}, {{operator_name}}, {{status_link}}), and a live preview against the most recent booking via preview_template(p_booking, p_text). SMS body shows a character counter (160 per segment).
- Message log page (nav under Settings for owners and admins): notification_outbox rows (time, booking number link, event, channel, to, status queued, sent, failed or skipped) with filters. A notice at the top: "Messages are queued. Sending by email and SMS is switched on by the platform team." Event names translated: Booking confirmed, Quote sent, Driver assigned, Driver on the way, Driver arrived, Trip completed, Booking cancelled.

12. BOOKING TERMS (settings.tsx, book.$slug.tsx)
- Settings "Booking terms": terms text (rich enough as plain text with line breaks), require acceptance toggle, and "Publish new version" which increments terms_version.
- Portal review step: when require_terms, a required checkbox "I accept the booking terms" with a "Read the terms" sheet showing terms_text, and the cancellation policy line; send accept_terms true.

ACCEPTANCE (check in code, then report)
1. A Pearson to Downtown zone rate shows "Flat rate Pearson to Downtown" in Try a price and in a new booking.
2. A Saturday night pickup shows the Weekend and Night lines.
3. Adding 15 minutes of waiting and a toll updates the booking total; a late cancellation can be charged.
4. The portal vehicle step shows photos and amenities.
5. An accountant creates a monthly invoice for a client company, marks it sent, records a payment, and the ageing report updates.
6. A pay run for last month lists each driver with pay and tips, and can be marked paid.
7. A weekly Monday, Wednesday, Friday booking for two weeks creates 6 bookings; cancelling from a date cancels the rest.
8. Assigning a driver on time off shows the warning; Today lists expiring documents.
9. A completed booking can be rated once on its status page.
10. Default messages install, preview shows real booking data, and confirming a booking adds a row to the message log.

When done, reply with only: files changed, anything added to docs/ASSUMPTIONS.md, type check and test results.
```
