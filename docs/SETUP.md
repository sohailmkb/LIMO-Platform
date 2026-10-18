# Setup: first run on Supabase (about 15 minutes)

Do this in the Supabase dashboard for your project. Keep the service role key out of chat and out of the repo.

## 1. Run the database

1. Open SQL Editor and create a new query.
2. Paste `supabase/migrations/0001_core.sql` and run it.
3. Paste `0002_operations.sql` and run it.
4. Paste `0003_security_and_actions.sql` and run it.
5. Paste `supabase/seed.sql` and run it.
6. Paste `0004_portal_and_team.sql` and run it (booking portal, team invites, live dispatch).
7. Paste `0005_driver_app_access.sql` and run it (app access for existing drivers).
8. Paste `0006_platform_admin.sql` and run it (super admin, company status and type).
9. Paste `0007_stripe.sql` and run it (card payments). Then follow `docs/STRIPE_SETUP.md`.
10. Paste `0008_tax_precision.sql` and run it (exact Quebec tax rate).
11. Paste `0009_ops_depth.sql` and run it (customer web sign-in, re-price, cancel with reason).
12. Paste `0010_booking_depth.sql` and run it (round trips, stops, extras, promo codes, quotes, branding). For address search see `docs/MAPS_SETUP.md`.
13. Make yourself super admin: `insert into platform_admins (user_id) select id from auth.users where email = 'YOUR_EMAIL';`

If any step errors, copy the full error text back to Claude. Do not edit the SQL yourself.

## 2. Check it

In Authentication, create two test users (one will be the operator, one a driver). Then in SQL Editor run:

```sql
select count(*) from plans;          -- expect 3
select count(*) from tax_presets;    -- expect 13
```

## 3. Connect the mobile app

1. In Project Settings, API: copy the Project URL and the anon public key.
2. In `apps/mobile`, copy `.env.example` to `.env` and paste both values.
3. From the repo root run `npm install`, then `cd apps/mobile && npx expo start`.
4. Open the app in Expo Go on your phone and scan the code.

## 4. Connect Lovable

In Lovable, link the project to this Supabase project and this repo. Then paste the prompts in `docs/lovable/prompt-pack-1.md` one at a time, in order.

## Database tests (optional, no Supabase needed)

From the repo root: `npm run test:db`.
