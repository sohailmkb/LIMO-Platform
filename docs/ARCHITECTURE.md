# Architecture: Limo Platform, week 1

Status: Day 1, Sunday 18 Oct 2026. Target: one working end-to-end slice by Saturday 24 Oct.

## 1. What this is

A multi-operator platform for chauffeur, limo and shuttle businesses in the US, Canada, UK and EU. One database serves many operators. Each operator sees only its own data. Three roles use it: operators and dispatchers (Admin), drivers, and customers.

Week 1 delivers one loop: an operator signs up, prices and books a trip, assigns a driver, the driver runs the trip on a phone, the customer pays, and the operator sees margin.

## 2. Components

| Part | Technology | Built by | Lives in |
|---|---|---|---|
| Database, security, business actions | Supabase Postgres | Claude | `supabase/` |
| Operator web app and public booking portal | Lovable (React, Supabase client) | Lovable, from prompts Claude writes | Lovable project, synced to this repo |
| Driver, Customer and Admin mobile apps | One Expo (React Native) app, three role modes | Claude | `apps/mobile` |
| Shared locale, money and status logic | TypeScript package | Claude | `packages/shared` |
| Database tests | Postgres in WebAssembly (PGlite) | Claude | `tests/db` |

All clients talk to Supabase directly with the anon key. There is no custom API server in week 1. Business rules sit in database functions (RPC), so web and mobile behave identically.

## 3. Data model (week-1 slice, 25 tables)

Tenancy: `orgs`, `profiles`, `memberships` (a user can hold several roles in several orgs), `plans`.
Reference: `currencies`, `locales`, `tax_presets`.
Per operator: `tax_rates`, `vehicle_classes`, `vehicles`, `drivers`, `driver_documents`, `accounts`, `contacts`, `rate_cards`, `surcharges`, `audit_log`.
Orders: `bookings` (the order and the bill), `booking_lines`, `trips` (one car movement), `trip_events`, `trip_costs` (staff only), `driver_locations`, `payments`.
Network: `farm_outs`.

Every operator-owned row carries `org_id`. Money is `numeric(12,2)`. Tax is computed per line and rounded to cents.

## 4. Business actions (RPC)

| Function | Who | What it does |
|---|---|---|
| `create_operator` | any signed-in user | Creates the org, owner membership, 14-day trial, tax rates for the country, three vehicle classes with starter rate cards |
| `quote_price` | staff | Prices a trip from rate card, surcharges and tax |
| `create_booking` | staff | Quote, booking, fare lines and one trip in one call |
| `assign_trip` | staff | Sets driver and vehicle, status `assigned` |
| `update_trip_status` | staff or the assigned driver | Moves a trip along the allowed flow and keeps the booking status in step |
| `public_quote` | anyone | Quote by operator slug for the public portal |
| `network_directory` | anyone | Operators that opted into the network (name, slug, country only) |

Trip flow: `assigned` to `en_route` to `arrived` to `on_board` to `completed`, with `no_show` from `arrived`. Only staff can cancel. The same table lives in `packages/shared/src/trip.ts`; change both together.

## 5. Security

Row-level security is on for every table.

- Staff (owner, admin, dispatcher) manage their own operator's rows.
- A driver sees only trips assigned to them and their own driver row.
- A customer sees only bookings, lines and trips tied to their own contact record.
- Driver pay, partner cost and margin are staff only. Drivers and customers read zero rows from `trip_costs` and `trip_margin`.
- A partner operator sees a trip only while a farm-out to it is `offered` or `accepted`, and never the booking behind it.
- Ownership checks run in `SECURITY DEFINER` helpers in schema `app`, so policies do not recurse.

## 6. Locale, currency and tax

- Currencies: USD, CAD, GBP, EUR. Each operator has one default currency; rate cards are per currency.
- Languages: English and French live. Spanish, German and Italian stay off until native review. The i18n framework is in place from day 1.
- Units and clock: `orgs.unit_system` (km or miles) and `orgs.clock_24h`, applied by the formatters in `packages/shared/src/locale.ts`.
- Tax: presets per country are copied into the operator on sign-up. They are standard rates only. Passenger transport can qualify for reduced rates in some countries, so each operator must confirm rates with an accountant.

## 7. Verified so far

`tests/db/run.mjs` applies the three migrations and the seed to an in-process Postgres and runs 29 checks, all passing:

- Sample booking: 120.00 plus 15.60 HST totals 135.60 CAD.
- UK quote: 120.00 GBP plus 20% VAT totals 144.00.
- Full trip flow as a driver, booking and payment status follow, margin 50.00.
- Cross-operator isolation for staff, driver and customer, including blocked writes.
- Farm-out visibility.

Run with `npm run test:db`.

## 8. Not verified, not built

- **Not run on real Supabase.** PGlite matches Postgres closely but is not Supabase. First run on the hosted project may surface differences (grants, the `auth` schema). Treat the first migration run as a test.
- **Differs from the earlier 79-table data model.** That artifact's SQL could not be found, so this schema was written fresh and covers the week-1 loop only. Reconcile in week 2. PostGIS, recurring bookings, compliance and wake-ups, GDPR tools and EU data residency are not here.
- **Payments are stubbed.** The `payments` table and paid-status logic work. No Stripe call exists yet. Stripe Connect comes when testing starts.
- **Public booking creation** (`public_create_booking`, Day 4) is not written. Only `public_quote` exists.
- **Mobile app** typechecks but has not run on a device. It needs the Supabase URL and anon key in `apps/mobile/.env`. No live GPS yet (Day 3).
- **Types are hand-written** in `packages/shared/src/types.ts`; replace with generated types once the project exists.
- **Placeholders:** product name, domain, bundle ID `com.limoplatform.app`, plan names and prices.

## 9. Repo layout

```
supabase/migrations/   0001_core, 0002_operations, 0003_security_and_actions
supabase/seed.sql      plans, currencies, locales, tax presets
apps/mobile/           Expo app: Driver, Customer, Admin modes
packages/shared/       locale, money, status helpers, types
tests/db/              database tests
docs/                  this file, setup steps, Lovable prompt pack
```
