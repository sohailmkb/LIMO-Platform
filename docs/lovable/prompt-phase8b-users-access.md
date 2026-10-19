# Lovable prompt: Phase 8B, users and access

Paste after the Phase 8 prompt has finished (it reuses the trip builder). Before pasting, run `0011_access.sql` (see `docs/SETUP.md`). Normal mode, one message.

---

```
Build all 8 items below in one pass. Read AGENTS.md first and follow it.

HOW TO WORK (keeps cost down)
- Do not ask me questions. If something is unclear, choose the simplest option that fits the existing code and log it in docs/ASSUMPTIONS.md.
- Do not create or alter tables, policies or database functions. Everything below already exists. The database enforces every permission; the UI only hides what a role cannot do.
- Touch only the files named here plus new files. Do not reformat or refactor anything else.
- Reuse primitives.tsx, states.tsx, StatusBadge, useActiveOrg, useFormat, friendlyError, useT, the Phase 8 trip builder (src/lib/trip.ts, price-breakdown.tsx, address-field.tsx) and the luxury tokens (font-display, eyebrow, bg-gold for the single main action).
- All new text through useT() in BOTH en.json and fr.json. Proper French. No em dashes.
- No screenshots while working. At the end run the type check and vitest once, fix failures, stop.

THE ACCESS MODEL (already in the database)
Portals and roles:
- Platform console: platform owner, platform admin (my_access().platform_role).
- Operator console: owner, admin, dispatcher, accountant.
- Travel agency (OTA) console: owner, admin, dispatcher (show it as "Agent"), accountant.
- Corporate client portal: client_admin (sees every booking of their company), client_booker (sees own bookings). Both book on the company account.
- Direct customer portal: customer.
- Driver: driver (phone app only).
Database functions:
- my_access() -> {platform_role: "owner"|"admin"|null, suspended: bool, portals: [{org_id, org_name, org_kind, org_slug, role, account_id, account_name}]}
- claim_invitations() -> [{org_id, org_name, role}] (accepts every open invitation for the signed-in email)
- invite_user(p_org uuid|null, p_email, p_role, p_account uuid|null, p_name) -> {status: "added"|"invited", token, invitation_id}. p_org null with role platform_admin or platform_owner invites to the platform console. "added" means the person already had an account and has access now.
- invitation_preview(p_token) -> {email, role, full_name, org_name, org_kind, account_name, state: open|accepted|expired|revoked} (works signed out)
- revoke_invitation(p_invitation), renew_invitation(p_invitation) -> token
- org_access(p_org) -> {members: [{membership_id, user_id, email, full_name, role, active, account_id, account_name, last_sign_in_at, suspended, is_me}], invitations: [{invitation_id, email, full_name, role, account_name, token, created_at, expires_at, expired}]}
- update_member(p_membership, p_action: "pause"|"resume"|"remove"|"role", p_role)
- platform_users(p_search) rows gain platform_role, suspended, memberships[].org_kind, memberships[].account_name
- platform_invitations() -> same shape as org_access invitations plus org_id, org_name
- platform_set_user_suspended(p_user, p_suspended, p_reason), platform_set_admin(p_user, p_role "owner"|"admin"|null)
- client_create_booking(p_org, p_account, p jsonb) -> booking id (same p as create_booking_v2; confirmed when the account has auto_confirm, otherwise a quote)
- Table accounts (corporate clients) now has billing_email, auto_confirm, active.
Invite link format: {origin}/invite/{token}

1. SIGN-IN ROUTING
New: src/lib/access.ts. Files: src/routes/_authenticated/route.tsx, src/routes/_authenticated/_staff/route.tsx, src/lib/memberships.ts, src/lib/org-context.tsx, src/routes/login.tsx.
- In the _authenticated beforeLoad, once per user per browser session: call claim_invitations() and link_customer_account(); if either granted anything, invalidate the memberships and access queries. Then load my_access() (query key ["access", userId]).
- access.ts exports destinationsFor(access): platform console (/platform) if platform_role; each operator or agency staff portal (/today, or /partner-bookings for agencies, after selecting that org as active); /my-trips if any customer, client_admin or client_booker portal; /app-only if only driver. No destination at all: /onboarding (create a company). suspended: show a full-page "Your access is paused. Contact the platform team." with Sign out.
- After sign-in, and whenever a page needs a home: one destination, go there; several, go to a new page /choose (src/routes/_authenticated/choose.tsx) listing each portal as a card (company name in serif, role label, portal type), remembering the last choice per user in localStorage. The user menu gets "Switch portal" when there is more than one.
- Add "accountant" to STAFF_ROLES so accountants enter the staff console.

2. PERMISSIONS IN THE UI
New: src/lib/permissions.ts with can(role, permission) for the staff roles and these permissions: dispatch, bookings.edit, pricing, fleet, drivers.manage, customers.edit, payments.record, reports, settings, team, invoices.
owner and admin: everything (team: owners manage admins; admins manage dispatchers, accountants, drivers and clients).
dispatcher: dispatch, bookings.edit, customers.edit, invoices.
accountant: reports, payments.record, invoices, and read-only bookings and customers.
Use it to filter the sidebar nav (app-shell.tsx) and to hide edit and action buttons on bookings, customers, pricing, fleet, drivers, settings and team pages. A role that opens a page it cannot use by URL sees "You do not have access to this page" (EmptyState) instead of an error.

3. PEOPLE AND ACCESS (operator and agency)
Files: src/routes/_authenticated/_staff/team.tsx (rename the nav label to "People and access"), src/components/app/team-panel.tsx (rewrite), new src/components/app/invite-dialog.tsx.
- Data from org_access(orgId). Tabs with counts: Staff, Drivers (operators only), Client companies (operators only), Customers (operators only), Invitations.
- Each member row: name or email, role chip, client company (for client roles), last sign-in ("Never" if null), status (Active, Paused, Suspended by platform). Row menu: Change role (staff roles only), Pause or Resume, Remove (confirm dialog). Hide actions the viewer cannot take (owner rows only by owners; admin rows only by owners; never yourself).
- Invite dialog: email, name (optional), role as a grouped select with a one-line description under each option, client company select when a client role is picked (with "New client company" inline: name, billing email, auto-confirm toggle, inserting into accounts). Agencies only see staff roles.
- After invite_user: if status "added", toast "{email} now has access". If "invited": show the invite link with Copy, and a checkbox (on by default) "Also email a sign-in link" that calls supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: origin + "/invite/" + token, shouldCreateUser: true } }). If that call fails (email rate limit), say "Email could not be sent. Copy the link and send it yourself."
- Invitations tab: email, role, sent, expires, Copy link, Resend (renew_invitation then the same email call), Revoke.
- A collapsible card "What each role can do" built from permissions.ts.

4. CLIENT COMPANIES (operators)
File: src/routes/_authenticated/_staff/customers/index.tsx (new tab "Client companies"), new src/routes/_authenticated/_staff/customers/accounts.$id.tsx.
- List accounts with name, billing email, auto-confirm, active, number of portal users, bookings this month. Add and edit. The detail page shows its portal users (filter org_access members by account_id) with Invite (role preselected client_booker, company fixed), and its bookings.
- On the staff booking form, when the booker contact belongs to an account, show the company name next to the booker.

5. INVITATION PAGE
New: src/routes/invite.$token.tsx (public, like the booking portal; call invitation_preview through a new server function in portal.functions.ts).
- Shows "{org_name} has invited you" (or "You have been invited to run the platform" for platform roles), the role with its one-line description, the company for client roles, and the email it was sent to.
- Signed in with that email: "Accept" calls claim_invitations(), then routes with destinationsFor.
- Signed in with another email: explain and offer Sign out.
- Signed out: three choices: "Email me a sign-in link" (signInWithOtp to the invitation email, emailRedirectTo this page), "Create a password" (signUp with the email fixed, emailRedirectTo this page; then "Check your email to confirm"), "I already have a password" (sign in form with the email fixed). After any sign-in, claim and route.
- States accepted, expired and revoked each get a clear message and a link to sign in.

6. CORPORATE CLIENT PORTAL
Files: src/routes/_authenticated/my-trips.tsx, new src/routes/_authenticated/my-trips_.book.tsx.
- If the person has client_admin or client_booker portals: a header with the company name, and "Book a ride" (gold) opening my-trips_.book.tsx: the Phase 8 trip builder in portal mode (price from public_price_trip with the org slug), booker fields prefilled and hidden, submit with client_create_booking(p_org, p_account, p). Then show the status page link and go back to My trips.
- client_admin: a "Company trips" section listing every booking of the account (passenger, date, route, status, total) with filters Upcoming and Past and an Export CSV.
- Customers keep the current My trips.

7. PLATFORM CONSOLE: USERS AND ACCESS
File: src/routes/_authenticated/platform/users.tsx (rewrite), platform shell nav label "Users and access".
- Search, and filter chips: All, Platform, Operator staff, Agency staff, Clients, Customers, Drivers, No access, Suspended.
- Each person: email, name, created, last sign-in, platform role chip, and every access chip "Company · Role" (client roles also show the client company). Row menu: Add access (company select, role select, client company when needed, then invite_user with that org), Suspend or Restore (reason required to suspend), and for platform owners only: Make platform admin, Make platform owner, Remove platform access.
- "Invite platform admin" button (owners only): email, role (admin or owner), invite_user(null, ...), same link and email handling as item 3.
- Invitations tab from platform_invitations() with Copy link and Revoke.

8. SMALL FIXES
- Login page: after password sign-in, route with destinationsFor instead of a fixed page.
- The /app-only page also lists any other portals the person has.

ACCEPTANCE (check in code, then report)
1. Inviting a new email shows a copyable /invite link; opening it signed out and creating a password lands the person in the right portal after confirming.
2. Inviting an email that already has an account gives access at once.
3. A dispatcher sees no Pricing, Settings or People; an accountant sees Reports and bookings without edit buttons.
4. An admin cannot change or remove the owner, and nobody can remove their own access.
5. A client_admin books on the company account and sees colleagues' bookings; a client_booker sees only their own.
6. A person with two portals sees the chooser and can switch from the user menu.
7. Platform owners can invite a platform admin and suspend a user; a suspended user sees the paused page.

When done, reply with only: files changed, anything added to docs/ASSUMPTIONS.md, type check and test results.
```
