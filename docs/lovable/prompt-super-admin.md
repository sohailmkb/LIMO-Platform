# Lovable prompt: super admin console

Send after phase 6 (or after phase 5 if you want it sooner). Copy everything between the two `=====` lines.

=====

# Build: Super admin console at /platform

The platform owner needs an ERP-style super admin area to run the whole platform: every company account, every user, plans, suspensions and reference data. Companies (limo operators and online travel agencies) still sign themselves up and only ever see their own data. All the hard rules from the original brief still apply: no schema changes, use only the names below, log anything missing in BACKEND_REQUESTS.md.

## How super admin works in the database (already built)

- A user is a super admin if they are in the `platform_admins` table. The app cannot add or remove super admins; that is done in Supabase directly. Check with `supabase.rpc('am_platform_admin')` (returns true or false).
- Row-level security gives a super admin full read and write access to every company's rows in every table (bookings, trips, drivers, vehicles, pricing, contacts, payments, memberships and so on). So the existing operator pages work for any company once the super admin opens it.
- Owners can no longer change their own `plan_id`, `trial_ends_at`, `status`, `status_reason`, `kind` or `stripe_account_id`; only a super admin can (the database raises an error otherwise).

New columns on `orgs`:
- `kind`: `operator` or `travel_agency`
- `status`: `active` or `suspended`
- `status_reason`: text, set when suspended

Changed function:
- `create_operator(...)` now takes an optional last parameter `p_kind` (`operator` default, or `travel_agency`). Travel agencies get tax rates but no starter fleet or prices.

New functions (all raise "platform administrators only" for anyone else):

| Function | Params | Returns |
|---|---|---|
| `am_platform_admin` | none | boolean |
| `platform_overview` | none | jsonb: companies, operators, travel_agencies, suspended, in_trial, trials_ending_7d, users, drivers, signups_30d, bookings_today, bookings_30d, booking_value_30d (object of currency to amount), unassigned_next_24h, requests_waiting_1h, expired_documents |
| `platform_companies` | none | rows: id, name, slug, kind, status, status_reason, country, default_currency, plan_id, trial_ends_at, created_at, owner_email, staff_count, driver_count, vehicle_count, bookings_30d, last_booking_at |
| `platform_users` | p_search (optional text) | rows: user_id, email, full_name, created_at, last_sign_in_at, is_platform_admin, memberships (json array of {membership_id, org_id, org_name, role, active}) |
| `platform_create_company` | p_owner_email, p_name, p_slug, p_country, p_currency, p_locale, p_timezone, p_unit_system, p_clock_24h, p_tax_preset, p_kind | jsonb: {result: 'created', org_id} or {result: 'no_account'} |
| `platform_set_company_status` | p_org, p_status (`active`/`suspended`), p_reason | void |
| `platform_set_company_plan` | p_org, p_plan, p_trial_ends_at | void |
| `platform_audit` | p_limit (default 200), p_org (optional) | rows: id, created_at, org_id, org_name, actor_email, action, entity, entity_id, detail |

Existing functions the console also uses: `add_member_by_email(p_org, p_email, p_role, p_driver_name)` and `team_members(p_org)` work for super admins on any company.

## What to build

### 1. Access and navigation
- After sign-in, call `am_platform_admin`. If true, show a "Platform" section at the top of the sidebar with: Overview, Companies, Users, Plans, Reference data, Audit log. Super admins who have no company membership land on `/platform`.
- Every `/platform/*` route checks `am_platform_admin` and shows "Not available" otherwise.
- Visually distinguish the platform area (a thin dark navy top band reading "Platform administration").

### 2. Overview (`/platform`)
Tiles from `platform_overview`: companies (operators / travel agencies), suspended, in trial, trials ending in 7 days, users, active drivers, sign-ups last 30 days, bookings today, bookings last 30 days, booking value last 30 days per currency. A "Needs attention" panel: unassigned trips next 24 h, booking requests waiting over 1 hour, expired driver documents (each links to the filtered Companies list or the company).

### 3. Companies (`/platform/companies`)
- Table from `platform_companies`: name, type (Operator / Travel agency), status badge, country, currency, plan, trial end (days left or "Ended"), owner email, staff, drivers, vehicles, bookings 30 d, last booking. Search, filters (type, status, plan, country, trial ending soon), sort, CSV export.
- "Create company": owner email, company name, slug, type, country, currency, language, timezone, units, clock, tax preset (from `tax_presets` for the country). Calls `platform_create_company`. On `no_account`, explain the owner must sign up first.
- Company detail (`/platform/companies/:id`): profile (edit name, timezone, language, units, clock, listed_in_network directly on `orgs`), plan and trial (change via `platform_set_company_plan`; plan options from `plans`), status (Suspend with a required reason, or Reactivate, via `platform_set_company_status`; confirm dialog), team (`team_members`, add member via `add_member_by_email`, deactivate via `memberships.active`), recent activity (`platform_audit` with p_org).
- "Open as this company": sets the active company in the operator app to this company so the super admin can use every operator page (bookings, dispatch, drivers, fleet, pricing, customers) for it. While doing so, show a persistent amber banner: "Super admin: you are managing <company name>. Changes are real." with an "Exit" button back to `/platform/companies/:id`. Extend `useActiveOrg()` so a super admin can select any company, not only their memberships.

### 4. Users (`/platform/users`)
- Table from `platform_users` with search: email, name, created, last sign-in, super admin badge, companies and roles as chips.
- User detail drawer: memberships with company and role; deactivate or reactivate a membership (update `memberships.active`); add the user to a company with a role (pick company, role; call `add_member_by_email` with that company id and the user's email).

### 5. Plans (`/platform/plans`)
Edit the `plans` table: name, seat_limit (blank = unlimited), sort_order. Show how many companies are on each plan (from `platform_companies`). Do not delete plans that are in use.

### 6. Reference data (`/platform/reference`)
Tabs to view and edit `currencies` (code, symbol, minor_unit), `locales` (code, name, status live/review) and `tax_presets` (code, country, region, label, rate as percent with up to 3 decimals, kind). Add and edit. Warn before deleting anything.

### 7. Audit log (`/platform/audit`)
`platform_audit` feed: time, company, who, action, entity, details (pretty JSON on expand). Filter by company and action. Load 200, "Load more" raises the limit.

### 8. Changes to the operator side
- Onboarding: add "Account type" first: "Limo / chauffeur operator" or "Travel agency". Pass `p_kind` to `create_operator`. Keep all other fields the same for both types.
- Travel agency accounts: after sign-in they get Settings, Team and a "Bookings with partner operators" page that says "Coming soon" (the travel agency booking flow is week 2). Hide Dispatch, Drivers, Fleet and Pricing for travel agencies.
- Suspended company: a staff member's membership row comes back but its joined `org` is null (row-level security hides suspended companies). Show a full-page message: "Your company account is suspended. Please contact support." with sign out. Do not show a blank app.

## Acceptance test
1. As the super admin: Platform appears in the menu; Overview numbers match the database.
2. Companies lists every company with owner email; create a company for an existing user; it appears.
3. Change a company's plan and trial; the owner signed in elsewhere sees the new plan in Settings and cannot change it.
4. Suspend a company with a reason; its staff see the suspended message; its booking page shows "not found"; reactivate and access returns.
5. "Open as this company" shows the amber banner and the company's bookings; Exit returns to the platform.
6. Audit log shows the plan change and the suspension with your email.
7. Everything works in English and French.

=====

## Notes for Sohail (not part of the prompt)

Before sending: run `0006_platform_admin.sql` in Supabase SQL Editor, then make yourself super admin with:

```sql
insert into platform_admins (user_id)
select id from auth.users where email = 'sohailmkb@gmail.com';
```
