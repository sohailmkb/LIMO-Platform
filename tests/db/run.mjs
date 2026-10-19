// Runs the real migrations and seed in an in-process Postgres (PGlite),
// then checks pricing, the booking flow and cross-operator isolation.
// Supabase's auth schema and roles are shimmed below.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'supabase');
const db = new PGlite();

const U = {
  alpha: '00000000-0000-0000-0000-00000000000a',
  bravo: '00000000-0000-0000-0000-00000000000b',
  driver: '00000000-0000-0000-0000-0000000000d1',
  customer: '00000000-0000-0000-0000-0000000000c1',
};

let passed = 0, failed = 0;
const check = (name, ok, extra = '') => {
  if (ok) { passed++; console.log(`  ok   ${name}`); }
  else { failed++; console.log(`  FAIL ${name} ${extra}`); }
};

async function as(user, sql, params = []) {
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user]);
  await db.exec('set role authenticated');
  try { return await db.query(sql, params); }
  finally { await db.exec('reset role'); }
}
async function asAnon(sql, params = []) {
  await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
  await db.exec('set role anon');
  try { return await db.query(sql, params); }
  finally { await db.exec('reset role'); }
}
async function fails(user, sql, params = []) {
  try { await as(user, sql, params); return false; } catch { return true; }
}

// --- Supabase shim -------------------------------------------------
await db.exec(`
  create schema auth;
  create table auth.users (id uuid primary key, email text, created_at timestamptz default now(), last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create role anon nologin;
  create role authenticated nologin;
  grant usage on schema public, auth to anon, authenticated;
  grant execute on function auth.uid() to anon, authenticated;
`);

console.log('Applying migrations');
// seed.sql only touches tables 0001_core.sql creates (plans, currencies, locales, tax_presets)
// and is meant to run once, early — on the real project it was applied right after 0001, long
// before any later migration, so currencies/tax_presets/etc. are already there by the time any
// of them runs. Applying it after every migration (the old order here) doesn't match that: it
// let a later migration's own seed data (0015's fx_rates, seeded from currencies) silently race
// against an empty currencies table that only this test harness would ever see.
for (const f of readdirSync(join(root, 'migrations')).filter(f => f.endsWith('.sql')).sort()) {
  await db.exec(readFileSync(join(root, 'migrations', f), 'utf8'));
  console.log(`  applied ${f}`);
  if (f === '0001_core.sql') {
    await db.exec(readFileSync(join(root, 'seed.sql'), 'utf8'));
    console.log('  applied seed.sql');
  }
}

for (const [k, id] of Object.entries(U)) await db.query('insert into auth.users (id, email) values ($1, $2)', [id, `${k}@test.com`]);
await db.query(`insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000d2', 'newdriver@test.com')`);

console.log('Sign-up');
const a = (await as(U.alpha, `select create_operator('Alpha Limo','alpha','CA','CAD','en','America/Toronto','metric',false,'CA-ON-HST') id`)).rows[0].id;
const b = (await as(U.bravo, `select create_operator('Bravo Cars','bravo','GB','GBP','en','Europe/London','imperial',true,'GB-VAT-20') id`)).rows[0].id;
check('operators created', !!a && !!b);
check('alpha has 3 vehicle classes', (await as(U.alpha, `select count(*)::int n from vehicle_classes`)).rows[0].n === 3);
check('alpha default tax is HST 13%', (await as(U.alpha, `select rate::float r from tax_rates where is_default`)).rows[0].r === 0.13);

console.log('Quote and booking (the Day 1 gate: 135.60 CAD)');
const sedanA = (await as(U.alpha, `select id from vehicle_classes where name='Sedan'`)).rows[0].id;
const contact = (await as(U.alpha, `insert into contacts (org_id, user_id, full_name) values ($1,$2,'Casey Customer') returning id`, [a, U.customer])).rows[0].id;
const bk = (await as(U.alpha, `select create_booking($1,$2,'Pat Passenger','+14165550100','one_way',$3, now() + interval '1 day','Pearson Airport T1','CN Tower',30,0) id`, [a, contact, sedanA])).rows[0].id;
const bRow = (await as(U.alpha, `select subtotal::float s, tax_total::float t, total::float tot, currency from bookings where id=$1`, [bk])).rows[0];
check('subtotal is 120.00', bRow.s === 120, JSON.stringify(bRow));
check('HST is 15.60', bRow.t === 15.6, JSON.stringify(bRow));
check('total is 135.60 CAD', bRow.tot === 135.6 && bRow.currency === 'CAD', JSON.stringify(bRow));

const sedanB = (await as(U.bravo, `select id from vehicle_classes where name='Sedan'`)).rows[0].id;
const qb = (await as(U.bravo, `select quote_price($1,$2,'one_way',30,0) q`, [b, sedanB])).rows[0].q;
check('GBP quote is 144.00 with 20% VAT', qb.total === 144 && qb.currency === 'GBP', JSON.stringify(qb));

console.log('Dispatch and driver flow');
const driverId = (await as(U.alpha, `insert into drivers (org_id, user_id, full_name) values ($1,$2,'Dana Driver') returning id`, [a, U.driver])).rows[0].id;
await db.query(`insert into memberships (org_id, user_id, role) values ($1,$2,'driver'), ($1,$3,'customer')`, [a, U.driver, U.customer]);
const trip = (await as(U.alpha, `select id from trips where booking_id=$1`, [bk])).rows[0].id;
check('driver cannot see unassigned trip', (await as(U.driver, `select count(*)::int n from trips`)).rows[0].n === 0);
await as(U.alpha, `select assign_trip($1,$2,null)`, [trip, driverId]);
check('driver sees assigned trip', (await as(U.driver, `select count(*)::int n from trips`)).rows[0].n === 1);
for (const s of ['en_route', 'arrived', 'on_board', 'completed']) {
  await as(U.driver, `select update_trip_status($1,$2,43.65,-79.38)`, [trip, s]);
}
check('trip completed and booking completed',
  (await as(U.alpha, `select b.status from bookings b where b.id=$1`, [bk])).rows[0].status === 'completed');
check('driver cannot skip the status flow', await fails(U.driver, `select update_trip_status($1,'en_route')`, [trip]));
check('driver cannot cancel', await fails(U.driver, `select update_trip_status($1,'cancelled')`, [trip]));

console.log('Payments and margin');
await as(U.alpha, `insert into payments (org_id, booking_id, amount, currency, status) values ($1,$2,135.60,'CAD','succeeded')`, [a, bk]);
const paid = (await as(U.alpha, `select payment_status, paid_amount::float p from bookings where id=$1`, [bk])).rows[0];
check('booking marked paid', paid.payment_status === 'paid' && paid.p === 135.6, JSON.stringify(paid));
await as(U.alpha, `insert into trip_costs (trip_id, org_id, driver_pay) values ($1,$2,70)`, [trip, a]);
const m = (await as(U.alpha, `select margin::float m from trip_margin`)).rows[0];
check('margin is 50.00 (120 revenue less 70 driver pay)', m && m.m === 50, JSON.stringify(m));

console.log('Isolation');
check('driver cannot read rate cards', (await as(U.driver, `select count(*)::int n from rate_cards`)).rows[0].n === 0);
check('driver cannot read driver pay', (await as(U.driver, `select count(*)::int n from trip_costs`)).rows[0].n === 0);
check('driver cannot read margin', (await as(U.driver, `select count(*)::int n from trip_margin`)).rows[0].n === 0);
check('customer sees own booking only', (await as(U.customer, `select count(*)::int n from bookings`)).rows[0].n === 1);
check('customer cannot read driver pay', (await as(U.customer, `select count(*)::int n from trip_costs`)).rows[0].n === 0);
check('customer cannot read payments', (await as(U.customer, `select count(*)::int n from payments`)).rows[0].n === 0);
check('bravo sees no alpha bookings', (await as(U.bravo, `select count(*)::int n from bookings`)).rows[0].n === 0);
check('bravo sees only its own org', (await as(U.bravo, `select count(*)::int n from orgs`)).rows[0].n === 1);
check('bravo sees no alpha trips', (await as(U.bravo, `select count(*)::int n from trips`)).rows[0].n === 0);
check('bravo cannot book on alpha', await fails(U.bravo, `select create_booking($1,null,'X',null,'one_way',$2, now(),'A','B',1,0)`, [a, sedanA]));
check('bravo cannot move alpha trip', await fails(U.bravo, `select update_trip_status($1,'cancelled')`, [trip]));
check('bravo cannot insert into alpha', await fails(U.bravo, `insert into vehicles (org_id, class_id, label) values ($1,$2,'x')`, [a, sedanA]));

console.log('Farm-out');
await as(U.alpha, `insert into farm_outs (from_org_id, to_org_id, trip_id, partner_price) values ($1,$2,$3,90)`, [a, b, trip]);
check('bravo sees the farmed-out trip', (await as(U.bravo, `select count(*)::int n from trips`)).rows[0].n === 1);
check('bravo still cannot see alpha bookings', (await as(U.bravo, `select count(*)::int n from bookings`)).rows[0].n === 0);

console.log('Public');
check('directory lists both operators', (await db.query(`select count(*)::int n from network_directory()`)).rows[0].n === 2);

console.log('Public portal (signed out)');
const op = (await asAnon(`select public_operator('alpha') p`)).rows[0].p;
check('portal reads operator and 3 classes', op.name === 'Alpha Limo' && op.classes.length === 3 && op.currency === 'CAD');
check('portal reads no private columns', op.stripe_account_id === undefined && op.id === undefined);
const pq = (await asAnon(`select public_quote('alpha',$1,'one_way',30,0) q`, [sedanA])).rows[0].q;
check('portal quote is 135.60', pq.total === 135.6);
const pb = (await asAnon(`select public_create_booking('alpha',$1,'one_way', now() + interval '2 days','Pearson T3','Yorkville',30,0,'Robin Rider','Robin@Example.com','+14165550123') r`, [sedanA])).rows[0].r;
check('portal booking created as quoted for 135.60', pb.status === 'quoted' && pb.total === 135.6 && pb.public_code?.length === 8, JSON.stringify(pb));
const st = (await asAnon(`select public_booking_status('alpha',$1) s`, [pb.public_code])).rows[0].s;
check('portal status page works', st && st.status === 'quoted' && st.pickup_address === 'Pearson T3');
check('status needs the right operator', (await asAnon(`select public_booking_status('bravo',$1) s`, [pb.public_code])).rows[0].s === null);
check('portal rejects past pickup', await (async () => { try { await asAnon(`select public_create_booking('alpha',$1,'one_way', now(),'A','B',5,0,'X','x@y.z',null)`, [sedanA]); return false; } catch { return true; } })());
check('portal rejects another operator class', await (async () => { try { await asAnon(`select public_create_booking('bravo',$1,'one_way', now() + interval '2 days','A','B',5,0,'X','x@y.z',null)`, [sedanA]); return false; } catch { return true; } })());
check('anon cannot read bookings table', await (async () => { try { await asAnon(`select count(*) from bookings`); return false; } catch { return true; } })());
check('alpha staff sees the portal booking', (await as(U.alpha, `select count(*)::int n from bookings where status='quoted'`)).rows[0].n === 1);
const pb2 = (await asAnon(`select public_create_booking('alpha',$1,'hourly', now() + interval '3 days','Hotel X',null,0,3,'Robin Rider','robin@example.com',null) r`, [sedanA])).rows[0].r;
check('repeat customer reuses one contact', (await as(U.alpha, `select count(*)::int n from contacts where email='robin@example.com'`)).rows[0].n === 1 && !!pb2.public_code);

console.log('Team');
check('owner adds driver by email', (await as(U.alpha, `select add_member_by_email($1,'NewDriver@test.com','driver','Nia Driver') r`, [a])).rows[0].r === 'added');
check('driver row created and linked', (await as(U.alpha, `select count(*)::int n from drivers where full_name='Nia Driver' and user_id is not null`)).rows[0].n === 1);
check('unknown email returns no_account', (await as(U.alpha, `select add_member_by_email($1,'nobody@test.com','driver') r`, [a])).rows[0].r === 'no_account');
check('repeat add returns already_member', (await as(U.alpha, `select add_member_by_email($1,'newdriver@test.com','driver') r`, [a])).rows[0].r === 'already_member');
check('driver cannot add members', await fails(U.driver, `select add_member_by_email($1,'x@test.com','admin')`, [a]));
check('bravo cannot add to alpha', await fails(U.bravo, `select add_member_by_email($1,'x@test.com','admin')`, [a]));
const tm = (await as(U.alpha, `select email, role from team_members($1)`, [a])).rows;
check('team list shows emails', tm.some(r => r.email === 'newdriver@test.com' && r.role === 'driver'));
check('bravo cannot list alpha team', (await as(U.bravo, `select count(*)::int n from team_members($1)`, [a])).rows[0].n === 0);

console.log('Driver app access');
await db.query(`insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000d3', 'later@test.com')`);
const dl = (await as(U.alpha, `insert into drivers (org_id, full_name) values ($1, 'Lee Later') returning id`, [a])).rows[0].id;
check('link existing driver', (await as(U.alpha, `select grant_driver_app_access($1,'LATER@test.com') r`, [dl])).rows[0].r === 'linked');
check('no duplicate driver row', (await as(U.alpha, `select count(*)::int n from drivers where full_name='Lee Later'`)).rows[0].n === 1);
check('driver membership created', (await db.query(`select count(*)::int n from memberships where user_id='00000000-0000-0000-0000-0000000000d3' and role='driver'`)).rows[0].n === 1);
check('repeat returns already_linked', (await as(U.alpha, `select grant_driver_app_access($1,'later@test.com') r`, [dl])).rows[0].r === 'already_linked');
check('unknown email returns no_account', (await as(U.alpha, `select grant_driver_app_access($1,'ghost@test.com') r`, [dl])).rows[0].r === 'no_account');
const d2 = (await as(U.alpha, `insert into drivers (org_id, full_name) values ($1, 'Other Driver') returning id`, [a])).rows[0].id;
check('account already used by another driver', (await as(U.alpha, `select grant_driver_app_access($1,'later@test.com') r`, [d2])).rows[0].r === 'account_used_by_other_driver');
check('driver cannot grant access', await fails(U.driver, `select grant_driver_app_access($1,'x@test.com')`, [d2]));
check('bravo cannot grant on alpha driver', await fails(U.bravo, `select grant_driver_app_access($1,'later@test.com')`, [d2]));

console.log('Super admin');
const BOSS = '00000000-0000-0000-0000-0000000000ff';
await db.query(`insert into auth.users (id, email) values ($1, 'boss@test.com')`, [BOSS]);
check('non-admin cannot open overview', await fails(U.alpha, `select platform_overview()`));
check('non-admin is not admin', (await as(U.alpha, `select am_platform_admin() a`)).rows[0].a === false);
await db.query(`insert into platform_admins (user_id) values ($1)`, [BOSS]);
check('admin is admin', (await as(BOSS, `select am_platform_admin() a`)).rows[0].a === true);
check('admin sees every company', (await as(BOSS, `select count(*)::int n from orgs`)).rows[0].n === 2);
check('admin reads all bookings', (await as(BOSS, `select count(*)::int n from bookings`)).rows[0].n >= 3);
check('admin reads driver pay', (await as(BOSS, `select count(*)::int n from trip_costs`)).rows[0].n === 1);
await as(BOSS, `update vehicle_classes set name = 'Executive Sedan' where org_id = $1 and name = 'Sedan'`, [b]);
check('admin edits another company data', (await as(U.bravo, `select count(*)::int n from vehicle_classes where name = 'Executive Sedan'`)).rows[0].n === 1);
check('admin books for a company', !!(await as(BOSS, `select create_booking($1,null,'Admin Test',null,'one_way',$2, now() + interval '3 days','A','B',10,0) id`, [a, sedanA])).rows[0].id);
check('owner cannot change own plan', await fails(U.alpha, `update orgs set plan_id = 'scale' where id = $1`, [a]));
check('owner cannot extend own trial', await fails(U.alpha, `update orgs set trial_ends_at = now() + interval '1 year' where id = $1`, [a]));
await as(U.alpha, `update orgs set name = 'Alpha Limo Inc' where id = $1`, [a]);
check('owner can still rename company', (await as(U.alpha, `select name from orgs where id = $1`, [a])).rows[0].name === 'Alpha Limo Inc');
await as(BOSS, `select platform_set_company_plan($1, 'growth', now() + interval '30 days')`, [a]);
check('admin changes plan', (await as(U.alpha, `select plan_id from orgs`)).rows[0].plan_id === 'growth');
const ov = (await as(BOSS, `select platform_overview() o`)).rows[0].o;
check('overview counts', ov.companies === 2 && ov.operators === 2 && ov.users >= 6 && ov.booking_value_30d.CAD > 0, JSON.stringify(ov));
const comps = (await as(BOSS, `select * from platform_companies()`)).rows;
check('company list with owner emails', comps.length === 2 && comps.some(c => c.owner_email === 'alpha@test.com' && Number(c.driver_count) >= 2));
const us = (await as(BOSS, `select * from platform_users('newdriver')`)).rows;
check('user search with memberships', us.length === 1 && us[0].memberships.length === 1 && us[0].memberships[0].role === 'driver');
const cc = (await as(BOSS, `select platform_create_company('newdriver@test.com','Globe Travel','globe-travel','GB','GBP','en','Europe/London','imperial',true,'GB-VAT-20','travel_agency') r`)).rows[0].r;
check('admin creates travel agency for a user', cc.result === 'created');
check('travel agency gets no fleet', (await as(BOSS, `select count(*)::int n from vehicle_classes where org_id = $1`, [cc.org_id])).rows[0].n === 0);
check('travel agency not in operator directory', (await as(BOSS, `select count(*)::int n from network_directory() where slug = 'globe-travel'`)).rows[0].n === 0);
check('create for unknown email returns no_account', (await as(BOSS, `select platform_create_company('ghost@test.com','X','x-co','CA','CAD','en') r`)).rows[0].r.result === 'no_account');
check('non-admin cannot create company for others', await fails(U.alpha, `select platform_create_company('alpha@test.com','X','x2','CA','CAD','en')`));
await as(BOSS, `select platform_set_company_status($1, 'suspended', 'Unpaid invoice')`, [b]);
check('suspended staff lose access', (await as(U.bravo, `select count(*)::int n from orgs`)).rows[0].n === 0);
check('suspended company hidden from portal', (await asAnon(`select public_operator('bravo') p`)).rows[0].p === null);
check('suspended company cannot take bookings', await (async () => { try { await asAnon(`select public_create_booking('bravo',$1,'one_way', now() + interval '2 days','A','B',5,0,'X','x@y.z',null)`, [sedanB]); return false; } catch { return true; } })());
check('suspended company hidden from network', (await as(U.alpha, `select count(*)::int n from network_directory() where slug = 'bravo'`)).rows[0].n === 0);
check('admin still sees suspended company', (await as(BOSS, `select status from orgs where id = $1`, [b])).rows[0].status === 'suspended');
await as(BOSS, `select platform_set_company_status($1, 'active')`, [b]);
check('reactivated staff regain access', (await as(U.bravo, `select count(*)::int n from orgs`)).rows[0].n === 1);
const au = (await as(BOSS, `select * from platform_audit(50)`)).rows;
check('audit feed shows admin actions', au.some(r => r.action === 'platform_set_status' && r.actor_email === 'boss@test.com'));
check('non-admin cannot read audit feed', await fails(U.alpha, `select * from platform_audit(10)`));
await db.query(`insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a7', 'ota@test.com')`);
const ota = (await as('00000000-0000-0000-0000-0000000000a7', `select create_operator('Trip Agency','trip-agency','FR','EUR','fr','Europe/Paris','metric',true,'FR-VAT-20','travel_agency') id`)).rows[0].id;
check('travel agency can self sign-up', (await as('00000000-0000-0000-0000-0000000000a7', `select kind from orgs where id = $1`, [ota])).rows[0].kind === 'travel_agency');
check('self sign-up still defaults to operator', (await as(BOSS, `select kind from orgs where id = $1`, [a])).rows[0].kind === 'operator');
check('admin cannot be added by app users', await fails(U.alpha, `insert into platform_admins (user_id) values ($1)`, [U.alpha]));

console.log('Stripe payments');
check('owner cannot mark own Stripe as ready', await fails(U.alpha, `update orgs set stripe_charges_enabled = true where id = $1`, [a]));
await as(U.alpha, `update orgs set deposit_percent = 30 where id = $1`, [a]);
const due0 = (await as(U.alpha, `select booking_amount_due($1) d`, [bk])).rows[0].d;
check('amount due on a paid booking is zero', Number(due0.balance) === 0 && Number(due0.deposit_due) === 0, JSON.stringify(due0));
const nb = (await as(U.alpha, `select create_booking($1,$2,'Card Payer',null,'one_way',$3, now() + interval '4 days','A','B',30,0) id`, [a, contact, sedanA])).rows[0].id;
const due1 = (await as(U.alpha, `select booking_amount_due($1) d`, [nb])).rows[0].d;
check('30% deposit of 135.60 is 40.68', Number(due1.deposit_due) === 40.68 && Number(due1.balance) === 135.6 && due1.card_payments_ready === false, JSON.stringify(due1));
// Server (service role, no auth.uid) marks Stripe ready and records a pending checkout, then the webhook settles it.
await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
await db.query(`update orgs set stripe_account_id = 'acct_test', stripe_charges_enabled = true where id = $1`, [a]);
await db.query(`insert into payments (org_id, booking_id, provider, provider_ref, amount, currency, status, kind) values ($1,$2,'stripe','cs_test_1',40.68,'CAD','pending','deposit')`, [a, nb]);
check('pending payment does not count as paid', (await as(U.alpha, `select payment_status from bookings where id = $1`, [nb])).rows[0].payment_status === 'unpaid');
await db.query(`update payments set status = 'succeeded' where provider_ref = 'cs_test_1'`);
const after = (await as(U.alpha, `select payment_status, paid_amount::float p from bookings where id = $1`, [nb])).rows[0];
check('webhook success marks deposit paid', after.payment_status === 'partial' && after.p === 40.68, JSON.stringify(after));
check('duplicate checkout reference rejected', await (async () => { try { await db.query(`insert into payments (org_id, booking_id, provider, provider_ref, amount, currency) values ($1,$2,'stripe','cs_test_1',1,'CAD')`, [a, nb]); return false; } catch { return true; } })());
const nbCode = (await as(U.alpha, `select public_code from bookings where id = $1`, [nb])).rows[0].public_code;
const pst = (await asAnon(`select public_booking_status('alpha', $1) s`, [nbCode])).rows[0].s;
check('status page shows balance and card readiness', pst && Number(pst.balance) === 94.92 && pst.card_payments_ready === true, JSON.stringify(pst));
check('non-admin cannot change platform fee', (await as(U.alpha, `update platform_settings set platform_fee_bps = 500 returning 1`)).rows.length === 0);
await as(BOSS, `update platform_settings set platform_fee_bps = 100`);
check('super admin sets platform fee', (await db.query(`select platform_fee_bps from platform_settings`)).rows[0].platform_fee_bps === 100);

console.log('Tax precision');
check('Quebec preset keeps 14.975%', (await db.query(`select rate::text r from tax_presets where code = 'CA-QC-GSTQST'`)).rows[0].r === '0.149750');
const qc = (await as(BOSS, `select create_operator('QC Limo','qc-limo','CA','CAD','fr','America/Montreal','metric',true,'CA-QC-GSTQST') id`)).rows[0].id;
const qcSedan = (await as(BOSS, `select id from vehicle_classes where org_id = $1 and name = 'Sedan'`, [qc])).rows[0].id;
const qq = (await as(BOSS, `select quote_price($1,$2,'one_way',30,0) q`, [qc, qcSedan])).rows[0].q;
check('Quebec quote: 120.00 + 17.97 = 137.97', qq.tax_total === 17.97 && qq.total === 137.97, JSON.stringify(qq));

console.log('Ops depth');
const CUST2 = '00000000-0000-0000-0000-0000000000c2';
await db.query(`insert into auth.users (id, email) values ($1, 'ROBIN@example.com')`, [CUST2]);
const linked = (await as(CUST2, `select link_customer_account() n`)).rows[0].n;
check('customer links portal bookings by email', linked === 2, String(linked));
check('customer now sees own bookings only', (await as(CUST2, `select count(*)::int n from bookings`)).rows[0].n === 2);
check('customer membership created', (await db.query(`select count(*)::int n from memberships where user_id = $1 and role = 'customer'`, [CUST2])).rows[0].n === 1);
check('linking again is safe', (await as(CUST2, `select link_customer_account() n`)).rows[0].n === 2);
const rb = (await as(U.alpha, `select create_booking($1,$2,'Reprice Me',null,'one_way',$3, now() + interval '5 days','A','B',30,0) id`, [a, contact, sedanA])).rows[0].id;
const suvA = (await as(U.alpha, `select id from vehicle_classes where org_id = $1 and name = 'SUV'`, [a])).rows[0].id;
const qSuv = (await as(U.alpha, `select quote_price($1,$2,'one_way',30,0) q`, [a, suvA])).rows[0].q;
const rp = (await as(U.alpha, `select reprice_booking($1,$2,'one_way',30,0) r`, [rb, suvA])).rows[0].r;
check('reprice matches a fresh SUV quote', Number(rp.total) === Number(qSuv.total) && Number(rp.subtotal) === Number(qSuv.subtotal), JSON.stringify({rp, qSuv}));
check('reprice keeps one fare line', (await as(U.alpha, `select count(*)::int n from booking_lines where booking_id = $1 and kind = 'fare'`, [rb])).rows[0].n === 1);
check('driver cannot reprice', await fails(U.driver, `select reprice_booking($1,$2,'one_way',10,0)`, [rb, suvA]));
check('bravo cannot reprice alpha', await fails(U.bravo, `select reprice_booking($1,$2,'one_way',10,0)`, [rb, suvA]));
await as(U.alpha, `select cancel_booking($1, 'Client changed plans')`, [rb]);
check('cancel sets booking and trip cancelled', (await as(U.alpha, `select b.status bs, t.status ts from bookings b join trips t on t.booking_id = b.id where b.id = $1`, [rb])).rows[0].ts === 'cancelled');
check('cancel reason in audit log', (await as(U.alpha, `select detail->>'reason' r from audit_log where action = 'cancel_booking' and entity_id = $1`, [rb])).rows[0].r === 'Client changed plans');
check('cannot cancel twice', await fails(U.alpha, `select cancel_booking($1)`, [rb]));
check('cannot reprice a cancelled booking', await fails(U.alpha, `select reprice_booking($1,$2,'one_way',10,0)`, [rb, suvA]));
await as(U.alpha, `update orgs set billing_address = '1 King St W, Toronto', tax_number = '123456789 RT0001' where id = $1`, [a]);
check('owner saves invoice details', (await as(U.alpha, `select tax_number from orgs where id = $1`, [a])).rows[0].tax_number === '123456789 RT0001');
check('customer reads tax label for receipt', (await as(CUST2, `select count(*)::int n from tax_rates`)).rows[0].n >= 1);
check('customer reads own trips, lines and company for My trips',
  (await as(CUST2, `select count(*)::int n from trips`)).rows[0].n === 2 &&
  (await as(CUST2, `select count(*)::int n from booking_lines`)).rows[0].n >= 2 &&
  (await as(CUST2, `select count(*)::int n from orgs`)).rows[0].n >= 1);
check('customer cannot read other customers contacts or payments',
  (await as(CUST2, `select count(*)::int n from contacts`)).rows[0].n === 0 &&
  (await as(CUST2, `select count(*)::int n from payments`)).rows[0].n === 0);
check('bravo cannot cancel alpha', await fails(U.bravo, `select cancel_booking($1)`, [bk]));

console.log('Booking depth (0010)');
{
  const near = (x, y) => Math.abs(Number(x) - Number(y)) < 0.001;
  const sumOk = (q) => near(q.total, q.lines.reduce((s, l) => s + Number(l.amount) + Number(l.tax_amount), 0));
  const P = (o) => JSON.stringify({ class_id: sedanA, service: 'one_way', distance: 30, ...o });
  const pr = async (o) => (await as(U.alpha, `select price_trip($1,$2::jsonb) q`, [a, P(o)])).rows[0].q;

  let q = await pr({});
  check('price_trip one way 30 km: 120 + 15.60 HST', near(q.subtotal, 120) && near(q.tax_total, 15.6) && sumOk(q), JSON.stringify(q));
  q = await pr({ round_trip: true });
  check('round trip doubles the fare', near(q.subtotal, 240) && q.lines.filter(l => l.kind === 'fare').length === 2);
  await as(U.alpha, `update rate_cards set per_stop = 15 where class_id = $1 and service_type = 'one_way'`, [sedanA]);
  await as(U.alpha, `update rate_cards set min_hours = 3 where class_id = $1 and service_type = 'hourly'`, [sedanA]);
  q = await pr({ stops: 2 });
  check('two extra stops add 30', near(q.subtotal, 150) && q.lines.some(l => l.code === 'stops' && near(l.amount, 30)));
  q = await pr({ service: 'hourly', hours: 2, distance: 0 });
  check('hourly bills the 3 hour minimum (225)', near(q.subtotal, 225), JSON.stringify(q.lines));

  const seat = (await as(U.alpha, `insert into extras (org_id, name, price, max_qty) values ($1,'Child seat',20,3) returning id`, [a])).rows[0].id;
  const greet = (await as(U.alpha, `insert into extras (org_id, name, price, taxable) values ($1,'Meet and greet',25,false) returning id`, [a])).rows[0].id;
  q = await pr({ extras: [{ id: seat, qty: 2 }, { id: greet, qty: 5 }] });
  check('extras: 2 seats taxed, meet and greet untaxed and capped at 1',
    near(q.subtotal, 185) && near(q.tax_total, 15.6 + 5.2) && sumOk(q), JSON.stringify(q.lines));

  await as(U.alpha, `insert into promo_codes (org_id, code, kind, value) values ($1,'Save10','percent',10), ($1,'OLD','fixed',5)`, [a]);
  await as(U.alpha, `update promo_codes set ends_at = now() - interval '1 day' where code = 'OLD'`);
  q = await pr({ stops: 1, promo_code: 'save10', extras: [{ id: seat, qty: 1 }] });
  check('promo 10% on fare and stops only (13.50 off)', q.promo.applied && near(q.subtotal, 120 + 15 + 20 - 13.5) && sumOk(q), JSON.stringify(q));
  q = await pr({ promo_code: 'OLD' });
  check('expired promo is reported, not applied', q.promo.applied === false && q.promo.reason === 'expired' && near(q.subtotal, 120));
  q = await pr({ promo_code: 'NOPE' });
  check('unknown promo is reported as invalid', q.promo.reason === 'invalid');
  q = await pr({ tip_percent: 15 });
  check('15% gratuity on the fare, not taxed', near(q.subtotal, 138) && near(q.tax_total, 15.6));
  const bravoSedan = (await as(U.bravo, `select id from vehicle_classes where name = 'Sedan' limit 1`)).rows[0]?.id;
  check('extra from another company is rejected', await fails(U.alpha, `select price_trip($1,$2::jsonb)`,
    [a, P({ extras: [{ id: (await db.query(`select gen_random_uuid() id`)).rows[0].id }] })]));
  const pub = (await asAnon(`select public_price_trip('alpha', $1::jsonb) q`, [P({ round_trip: true })])).rows[0].q;
  check('public price check works signed out', near(pub.subtotal, 240));

  // Staff booking: round trip, 2 stops, flight, promo
  const when = new Date(Date.now() + 3 * 864e5).toISOString();
  const back = new Date(Date.now() + 4 * 864e5).toISOString();
  const spec = P({ round_trip: true, promo_code: 'SAVE10', passenger_name: 'Robin Rider', passenger_phone: '+14165550111',
    pickup_at: when, return_at: back, pickup_address: 'Pearson T1', dropoff_address: 'Fairmont Royal York',
    stops_list: [{ address: 'CN Tower' }, { address: 'Union Station' }], flight_number: 'ac 101', meet_greet: true,
    passenger_count: 3, luggage_count: 4, extras: [{ id: greet }] });
  const expected = (await as(U.alpha, `select price_trip($1, ($2::jsonb) || '{"stops":2}') q`, [a, spec])).rows[0].q;
  const used0 = (await db.query(`select used_count from promo_codes where code = 'Save10'`)).rows[0].used_count;
  const nb = (await as(U.alpha, `select create_booking_v2($1,$2,$3::jsonb) id`, [a, contact, spec])).rows[0].id;
  const nbRow = (await as(U.alpha, `select total, status, round_trip, promo_code, passenger_count from bookings where id = $1`, [nb])).rows[0];
  check('create_booking_v2 total matches price_trip', near(nbRow.total, expected.total) && nbRow.status === 'confirmed' && nbRow.round_trip, JSON.stringify({ nbRow, t: expected.total }));
  const legs = (await as(U.alpha, `select leg, pickup_address, dropoff_address, flight_number, meet_greet from trips where booking_id = $1 order by pickup_at`, [nb])).rows;
  check('round trip makes an outbound and a reversed return leg',
    legs.length === 2 && legs[1].leg === 'return' && legs[1].pickup_address === 'Fairmont Royal York' && legs[1].dropoff_address === 'Pearson T1');
  check('flight number is stored upper case with meet and greet', legs[0].flight_number === 'AC 101' && legs[0].meet_greet === true);
  check('stops saved in order', (await as(U.alpha, `select string_agg(address, '>' order by seq) s from trip_stops s join trips t on t.id = s.trip_id where t.booking_id = $1`, [nb])).rows[0].s === 'CN Tower>Union Station');
  check('promo use is counted', (await db.query(`select used_count from promo_codes where code = 'Save10'`)).rows[0].used_count === used0 + 1);
  check('return before pickup is rejected', await fails(U.alpha, `select create_booking_v2($1,$2,$3::jsonb)`, [a, contact, P({ round_trip: true, passenger_name: 'X', pickup_at: back, return_at: when, pickup_address: 'A' })]));
  check('driver cannot use create_booking_v2', await fails(U.driver, `select create_booking_v2($1,$2,$3::jsonb)`, [a, contact, spec]));
  check('bravo cannot book on alpha with v2', await fails(U.bravo, `select create_booking_v2($1,null,$2::jsonb)`, [a, spec]));
  check('customer sees stops of own booking', (await as(U.customer, `select count(*)::int n from trip_stops`)).rows[0].n === 2);
  check('bravo sees no alpha stops', (await as(U.bravo, `select count(*)::int n from trip_stops`)).rows[0].n === 0);

  // Customer request and online quote acceptance
  const req = (await asAnon(`select public_create_booking_v2('alpha', $1::jsonb) r`, [P({
    booker_name: 'Quinn Quote', booker_email: 'Quinn@Example.com', pickup_at: when, pickup_address: 'Union Station',
    dropoff_address: 'Pearson T3', extras: [{ id: seat }], passenger_count: 2 })])).rows[0].r;
  check('portal request lands as a quote', !!req.public_code && near(req.total, 158.2), JSON.stringify(req));
  check('portal request with a bad email is rejected', await (async () => { try { await asAnon(`select public_create_booking_v2('alpha', $1::jsonb)`, [P({ booker_name: 'Q', booker_email: 'nope', pickup_at: when, pickup_address: 'A' })]); return false; } catch { return true; } })());
  let st = (await asAnon(`select public_booking_status('alpha', $1) s`, [req.public_code])).rows[0].s;
  check('status shows price lines and cannot accept yet', st.lines.length === 2 && st.can_accept === false && st.status === 'quoted');
  check('accepting before it is sent fails', await (async () => { try { await asAnon(`select public_accept_quote('alpha', $1)`, [req.public_code]); return false; } catch { return true; } })());
  const reqId = (await db.query(`select id from bookings where public_code = $1`, [req.public_code])).rows[0].id;
  check('driver cannot send a quote', await fails(U.driver, `select send_quote($1)`, [reqId]));
  await as(U.alpha, `select send_quote($1)`, [reqId]);
  st = (await asAnon(`select public_booking_status('alpha', $1) s`, [req.public_code])).rows[0].s;
  check('sent quote can be accepted', st.can_accept === true && !!st.quote_expires_at);
  check('customer accepts the quote', (await asAnon(`select public_accept_quote('alpha', $1) r`, [req.public_code])).rows[0].r === 'confirmed');
  check('accepting twice is harmless', (await asAnon(`select public_accept_quote('alpha', $1) r`, [req.public_code])).rows[0].r === 'confirmed');
  const req2 = (await asAnon(`select public_create_booking_v2('alpha', $1::jsonb) r`, [P({ booker_name: 'Quinn Quote', booker_email: 'quinn@example.com', pickup_at: when, pickup_address: 'A' })])).rows[0].r;
  check('same email reuses the customer', (await db.query(`select count(*)::int n from contacts where lower(email) = 'quinn@example.com'`)).rows[0].n === 1);
  const req2Id = (await db.query(`select id from bookings where public_code = $1`, [req2.public_code])).rows[0].id;
  await as(U.alpha, `select send_quote($1)`, [req2Id]);
  await db.query(`update bookings set quote_expires_at = now() - interval '1 hour' where id = $1`, [req2Id]);
  check('expired quote cannot be accepted', await (async () => { try { await asAnon(`select public_accept_quote('alpha', $1)`, [req2.public_code]); return false; } catch { return true; } })());
  await as(U.alpha, `select confirm_booking($1)`, [req2Id]);
  check('staff can confirm a quote directly', (await db.query(`select status from bookings where id = $1`, [req2Id])).rows[0].status === 'confirmed');

  // Driver pay
  await as(U.alpha, `update drivers set pay_percent = 40 where id = $1`, [driverId]);
  const out = (await as(U.alpha, `select id from trips where booking_id = $1 and leg = 'outbound'`, [nb])).rows[0].id;
  await as(U.alpha, `update trips set driver_id = $2, status = 'assigned' where id = $1`, [out, driverId]);
  await as(U.alpha, `update trips set status = 'completed' where id = $1`, [out]);
  const fares = (await as(U.alpha, `select sum(amount) s from booking_lines where booking_id = $1 and kind in ('fare','surcharge','discount')`, [nb])).rows[0].s;
  const pay = (await as(U.alpha, `select driver_pay from trip_costs where trip_id = $1`, [out])).rows[0]?.driver_pay;
  check('completed trip gets 40% of its fare share as driver pay', near(pay, Math.round(Number(fares) / 2 * 0.4 * 100) / 100), `${pay} vs ${fares}`);
  const op = (await asAnon(`select public_operator('alpha') o`)).rows[0].o;
  check('public operator lists extras and promo flag', op.extras.length === 2 && op.has_promos === true && op.classes[0].services.length === 2);
  check('promo codes are staff only', (await as(U.customer, `select count(*)::int n from promo_codes`)).rows[0].n === 0);
}

console.log('Users and access (0011)');
{
  const uid = (n) => `00000000-0000-0000-0000-0000000001${String(n).padStart(2, '0')}`;
  const signup = (n, email) => db.query(`insert into auth.users (id, email) values ($1, $2)`, [uid(n), email]);
  const failsAnon = async (sql, params = []) => { try { await asAnon(sql, params); return false; } catch { return true; } };

  // Invite someone with no account yet, then they sign up and sign in
  const inv = (await as(U.alpha, `select invite_user($1,'Dispo@Test.com','dispatcher',null,'Dee Dispatcher') r`, [a])).rows[0].r;
  check('invite for a new person waits for sign-in', inv.status === 'invited' && inv.token.length === 64);
  const pv = (await asAnon(`select invitation_preview($1) p`, [inv.token])).rows[0].p;
  if (!(pv && pv.org_name === 'Alpha Limo')) console.log('DEBUG preview', JSON.stringify(pv), inv.token);
  check('invite link preview shows company, role and state', pv.org_name.startsWith('Alpha Limo') && pv.role === 'dispatcher' && pv.state === 'open' && pv.email === 'dispo@test.com');
  check('preview of a wrong token shows nothing', (await asAnon(`select invitation_preview('x') p`)).rows[0].p === null);
  await signup(1, 'dispo@test.com');
  check('nothing before claiming', (await as(uid(1), `select count(*)::int n from bookings`)).rows[0].n === 0);
  const got = (await as(uid(1), `select claim_invitations() r`)).rows[0].r;
  if (!(got.length === 1)) console.log('DEBUG claim', JSON.stringify(got));
  check('sign-in accepts the invitation', got.length === 1 && got[0].role === 'dispatcher' && got[0].org_name.startsWith('Alpha Limo'));
  check('dispatcher now works in the company', (await as(uid(1), `select count(*)::int n from bookings`)).rows[0].n > 0);
  check('claiming again grants nothing new', (await as(uid(1), `select claim_invitations() r`)).rows[0].r.length === 0);
  check('my_access lists the portal', (await as(uid(1), `select my_access() r`)).rows[0].r.portals.some(p => p.role === 'dispatcher' && p.org_slug === 'alpha'));
  check('accepted link shows accepted', (await asAnon(`select invitation_preview($1) p`, [inv.token])).rows[0].p.state === 'accepted');

  // Who may invite whom
  check('dispatcher cannot invite', await fails(uid(1), `select invite_user($1,'x@test.com','driver')`, [a]));
  check('another company cannot invite into alpha', await fails(U.bravo, `select invite_user($1,'x@test.com','driver')`, [a]));
  const adm = (await as(U.alpha, `select invite_user($1,'adm@test.com','admin') r`, [a])).rows[0].r;
  await signup(2, 'adm@test.com'); await as(uid(2), `select claim_invitations()`);
  check('admin cannot invite another admin', await fails(uid(2), `select invite_user($1,'adm2@test.com','admin')`, [a]));
  check('admin can invite a driver', (await as(uid(2), `select invite_user($1,'drv@test.com','driver',null,'Sam Driver') r`, [a])).rows[0].r.status === 'invited');
  await signup(3, 'drv@test.com'); await as(uid(3), `select claim_invitations()`);
  check('driver invite creates the driver record', (await db.query(`select full_name from drivers where user_id = $1`, [uid(3)])).rows[0]?.full_name === 'Sam Driver');

  // Existing account: access is immediate
  const acc = (await as(U.alpha, `select invite_user($1,'bravo@test.com','accountant') r`, [a])).rows[0].r;
  check('existing account is added at once', acc.status === 'added');
  check('accountant reads bookings and payments', (await as(U.bravo, `select count(*)::int n from bookings where org_id = $1`, [a])).rows[0].n > 0
    && (await as(U.bravo, `select count(*)::int n from payments where org_id = $1`, [a])).rows.length === 1);
  check('accountant cannot edit bookings', (await as(U.bravo, `update bookings set passenger_name = 'X' where org_id = $1 returning id`, [a])).rows.length === 0);
  check('accountant cannot change prices', (await as(U.bravo, `update rate_cards set base_amount = 1 where org_id = $1 returning id`, [a])).rows.length === 0);
  check('accountant cannot dispatch', await fails(U.bravo, `select assign_trip((select id from trips where org_id = $1 limit 1), null)`, [a]));

  // Owner protection and member changes
  const ownerRow = (await db.query(`select id from memberships where org_id = $1 and role = 'owner'`, [a])).rows[0].id;
  const dispoRow = (await db.query(`select id from memberships where user_id = $1`, [uid(1)])).rows[0].id;
  const admRow = (await db.query(`select id from memberships where user_id = $1`, [uid(2)])).rows[0].id;
  check('admin cannot pause the owner', await fails(uid(2), `select update_member($1,'pause')`, [ownerRow]));
  check('admin cannot demote the owner directly', await fails(uid(2), `update memberships set role = 'dispatcher' where id = $1`, [ownerRow]));
  check('admin cannot make an owner directly', await fails(uid(2), `insert into memberships (org_id, user_id, role) values ($1,$2,'owner')`, [a, uid(1)]));
  check('owner cannot remove own access', await fails(U.alpha, `select update_member($1,'remove')`, [ownerRow]));
  await as(uid(2), `select update_member($1,'role','accountant')`, [dispoRow]);
  check('admin changes dispatcher to accountant', (await db.query(`select role from memberships where id = $1`, [dispoRow])).rows[0].role === 'accountant');
  check('admin cannot change another admin', await fails(uid(2), `select update_member($1,'role','dispatcher')`, [admRow]));
  await as(U.alpha, `select update_member($1,'pause')`, [dispoRow]);
  check('paused member loses access', (await as(uid(1), `select count(*)::int n from bookings`)).rows[0].n === 0);
  await as(U.alpha, `select update_member($1,'resume')`, [dispoRow]);
  check('resumed member regains access', (await as(uid(1), `select count(*)::int n from bookings`)).rows[0].n > 0);
  const oa = (await as(U.alpha, `select org_access($1) r`, [a])).rows[0].r;
  check('org_access lists members and open invitations', oa.members.length >= 5 && Array.isArray(oa.invitations));
  check('dispatcher cannot see org_access', await fails(uid(1), `select org_access($1)`, [a]));

  // Revoke and renew
  const rv = (await as(U.alpha, `select invite_user($1,'late@test.com','dispatcher') r`, [a])).rows[0].r;
  await as(U.alpha, `select revoke_invitation($1)`, [rv.invitation_id]);
  await signup(4, 'late@test.com');
  check('revoked invitation grants nothing', (await as(uid(4), `select claim_invitations() r`)).rows[0].r.length === 0);
  const ex = (await as(U.alpha, `select invite_user($1,'exp@test.com','dispatcher') r`, [a])).rows[0].r;
  await db.query(`update invitations set expires_at = now() - interval '1 day' where id = $1`, [ex.invitation_id]);
  await signup(5, 'exp@test.com');
  check('expired invitation grants nothing', (await as(uid(5), `select claim_invitations() r`)).rows[0].r.length === 0);
  await as(U.alpha, `select renew_invitation($1)`, [ex.invitation_id]);
  check('renewed invitation works', (await as(uid(5), `select claim_invitations() r`)).rows[0].r.length === 1);

  // Corporate client portal
  const acme = (await as(U.alpha, `insert into accounts (org_id, name) values ($1,'Acme Corp') returning id`, [a])).rows[0].id;
  check('client role needs a client company', await fails(U.alpha, `select invite_user($1,'ca@acme.com','client_admin')`, [a]));
  await as(U.alpha, `select invite_user($1,'ca@acme.com','client_admin',$2,'Cara Admin')`, [a, acme]);
  await as(U.alpha, `select invite_user($1,'cb@acme.com','client_booker',$2)`, [a, acme]);
  await signup(6, 'ca@acme.com'); await signup(7, 'cb@acme.com');
  await as(uid(6), `select claim_invitations()`); await as(uid(7), `select claim_invitations()`);
  const when = new Date(Date.now() + 2 * 864e5).toISOString();
  const trip = (o) => JSON.stringify({ class_id: sedanA, service: 'one_way', distance: 20, pickup_at: when, pickup_address: 'Acme HQ', passenger_name: 'Exec', ...o });
  const cb1 = (await as(uid(7), `select client_create_booking($1,$2,$3::jsonb) id`, [a, acme, trip({})])).rows[0].id;
  const cbRow = (await db.query(`select status, account_id from bookings where id = $1`, [cb1])).rows[0];
  check('client booking is on the account and waits as a quote', cbRow.account_id === acme && cbRow.status === 'quoted');
  await as(U.alpha, `update accounts set auto_confirm = true where id = $1`, [acme]);
  const ca1 = (await as(uid(6), `select client_create_booking($1,$2,$3::jsonb) id`, [a, acme, trip({ passenger_name: 'CEO' })])).rows[0].id;
  check('auto-confirm accounts skip the quote', (await db.query(`select status from bookings where id = $1`, [ca1])).rows[0].status === 'confirmed');
  check('client admin sees every company booking', (await as(uid(6), `select count(*)::int n from bookings`)).rows[0].n === 2);
  check('client admin sees trips and lines of colleagues', (await as(uid(6), `select count(*)::int n from booking_lines where booking_id = $1`, [cb1])).rows[0].n >= 1
    && (await as(uid(6), `select count(*)::int n from trips where booking_id = $1`, [cb1])).rows[0].n === 1);
  check('client booker sees only own bookings', (await as(uid(7), `select count(*)::int n from bookings`)).rows[0].n === 1);
  check('client reads own company record', (await as(uid(7), `select name from accounts`)).rows[0]?.name === 'Acme Corp');
  check('client cannot book on another account', await fails(uid(7), `select client_create_booking($1,$2,$3::jsonb)`, [a, (await as(U.alpha, `insert into accounts (org_id, name) values ($1,'Other') returning id`, [a])).rows[0].id, trip({})]));
  check('clients cannot see other customers', (await as(uid(6), `select count(*)::int n from contacts`)).rows[0].n === 0);
  check('travel agency cannot invite drivers', await fails(BOSS, `select invite_user($1,'d@test.com','driver')`, [cc.org_id]));

  // Platform console
  const pa = (await as(BOSS, `select invite_user(null,'pa@test.com','platform_admin') r`)).rows[0].r;
  await signup(8, 'pa@test.com'); await as(uid(8), `select claim_invitations()`);
  check('platform admin invite works', (await as(uid(8), `select am_platform_admin() r`)).rows[0].r === true);
  check('platform admin (not owner) cannot add platform admins', await fails(uid(8), `select invite_user(null,'x@test.com','platform_admin')`));
  check('platform admin cannot suspend the platform owner', await fails(uid(8), `select platform_set_user_suspended($1,true)`, [BOSS]));
  await as(uid(8), `select platform_set_user_suspended($1,true,'test')`, [uid(1)]);
  check('suspended person loses all access', (await as(uid(1), `select count(*)::int n from bookings`)).rows[0].n === 0
    && (await as(uid(1), `select my_access() r`)).rows[0].r.suspended === true);
  check('suspended person cannot lift it', await fails(uid(1), `delete from user_suspensions`));
  await as(uid(8), `select platform_set_user_suspended($1,false)`, [uid(1)]);
  check('restored person works again', (await as(uid(1), `select count(*)::int n from bookings`)).rows[0].n > 0);
  check('last platform owner cannot be removed', await fails(BOSS, `select platform_set_admin($1,null)`, [BOSS]));
  const pu = (await as(BOSS, `select * from platform_users('acme')`)).rows;
  check('platform users shows client access with company', pu.length === 2 && pu.some(r => r.memberships[0].account_name === 'Acme Corp'));
  check('platform sees open invitations', Array.isArray((await as(BOSS, `select platform_invitations() r`)).rows[0].r));
  let boot; try { boot = (await db.query(`select app.bootstrap_platform_owner('Boot@Test.com') r`)).rows[0].r; } catch (e) { boot = 'ERR ' + e.message; }
  check('bootstrap before sign-up', String(boot).startsWith('will be granted'), boot);
  await signup(9, 'boot@test.com'); await as(uid(9), `select claim_invitations()`);
  check('bootstrap grants platform owner on first sign-in', (await as(uid(9), `select my_access() r`)).rows[0].r.platform_role === 'owner');
  check('clients cannot call bootstrap', await fails(U.alpha, `select app.bootstrap_platform_owner('x@test.com')`));
  check('company sign-up still makes the founder owner', !!(await as(uid(4), `select create_operator('Late Limo','late-limo','CA','CAD','en','America/Toronto','metric',false,'CA-ON-HST') id`)).rows[0].id);
}

console.log('Operations suite (0012)');
{
  const near = (x, y) => Math.abs(Number(x) - Number(y)) < 0.011;
  const local = async (d) => (await db.query(`select (($1)::timestamp at time zone 'America/Toronto') t`, [d])).rows[0].t.toISOString();
  const P = (o) => JSON.stringify({ class_id: sedanA, service: 'one_way', distance: 27, ...o });
  const pr = async (o) => (await as(U.alpha, `select price_trip($1,$2::jsonb) q`, [a, P(o)])).rows[0].q;
  const OUT = 'x0000000-0000-0000-0000-0000000001ee'.replace('x', '0');
  await db.query(`insert into auth.users (id, email) values ($1, 'outsider@test.com')`, [OUT]);
  const book = async (o) => (await as(U.alpha, `select create_booking_v2($1,$2,$3::jsonb) id`, [a, contact,
    P({ passenger_name: 'Robin Rider', passenger_phone: '+14165550123', pickup_address: 'Pearson T1', dropoff_address: 'Union Station', ...o })])).rows[0].id;

  // 1. Pricing rules
  const pz = (await as(U.alpha, `insert into zones (org_id, name, kind, lat, lng, radius_km) values ($1,'Pearson','airport',43.6777,-79.6248,3) returning id`, [a])).rows[0].id;
  const dz = (await as(U.alpha, `insert into zones (org_id, name, lat, lng, radius_km) values ($1,'Downtown',43.6487,-79.3817,3) returning id`, [a])).rows[0].id;
  await as(U.alpha, `insert into zone_rates (org_id, class_id, from_zone, to_zone, amount) values ($1,$2,$3,$4,95)`, [a, sedanA, pz, dz]);
  const AP = { pickup_lat: 43.68, pickup_lng: -79.62, dropoff_lat: 43.65, dropoff_lng: -79.38 };
  let q = await pr(AP);
  check('zone flat rate replaces the distance fare', near(q.lines[0].amount, 95) && q.lines[0].description === 'Flat rate Pearson to Downtown' && q.zone.from === 'Pearson', JSON.stringify(q.lines[0]));
  q = await pr({ pickup_lat: 43.65, pickup_lng: -79.38, dropoff_lat: 43.68, dropoff_lng: -79.62 });
  check('flat rate works in the other direction', near(q.lines[0].amount, 95));
  q = await pr({ pickup_lat: 43.9, pickup_lng: -79.0, dropoff_lat: 43.65, dropoff_lng: -79.38 });
  check('outside the zones the distance fare applies', near(q.lines[0].amount, 114));
  q = await pr({ service: 'hourly', hours: 4, distance: 0 });
  check('hourly quotes still work and report the minimum', near(q.lines[0].amount, 300) && Number(q.min_hours) === 3, JSON.stringify(q.lines));
  await as(U.alpha, `update orgs set airport_fee = 10 where id = $1`, [a]);
  q = await pr(AP);
  check('airport zone adds the airport fee', q.lines.some(l => l.code === 'airport' && near(l.amount, 10)));
  q = await pr({ ...AP, round_trip: true });
  check('round trip pays the airport fee twice', q.lines.some(l => l.code === 'airport' && near(l.amount, 20)));
  q = await pr({ pickup_airport: true });
  check('airport flag from address search adds the fee', q.lines.some(l => l.code === 'airport'));
  await as(U.alpha, `update orgs set airport_fee = 0 where id = $1`, [a]);
  await as(U.alpha, `insert into price_rules (org_id, name, start_time, end_time, adjust_type, amount) values ($1,'Night',  '22:00','06:00','percent',20)`, [a]);
  await as(U.alpha, `insert into price_rules (org_id, name, date_from, date_to, adjust_type, amount) values ($1,'New Year''s Eve','2026-12-31','2026-12-31','fixed',25)`, [a]);
  await as(U.alpha, `insert into price_rules (org_id, name, days, adjust_type, amount) values ($1,'Weekend',array[0,6],'percent',10)`, [a]);
  q = await pr({ pickup_at: await local('2026-12-02 23:30') });
  check('night rule applies at 23:30 local (wraps midnight)', q.lines.some(l => l.code === 'rule' && l.description === 'Night' && near(l.amount, 22.8)), JSON.stringify(q.lines));
  q = await pr({ pickup_at: await local('2026-12-03 05:59') });
  check('night rule applies at 05:59', q.lines.some(l => l.description === 'Night'));
  q = await pr({ pickup_at: await local('2026-12-02 12:00') });
  check('no rule at noon on a weekday', !q.lines.some(l => l.code === 'rule'));
  q = await pr({ pickup_at: await local('2026-12-31 12:00') });
  check('holiday date adds its fixed amount', q.lines.some(l => l.description === "New Year's Eve" && near(l.amount, 25)));
  q = await pr({ pickup_at: await local('2026-12-05 12:00') });
  check('weekend rule on a Saturday', q.lines.some(l => l.description === 'Weekend' && near(l.amount, 11.4)));
  await as(U.alpha, `update price_rules set active = false where org_id = $1`, [a]);

  // Charges after the trip
  await as(U.alpha, `update orgs set wait_per_minute = 1.5, cancel_fee_percent = 50 where id = $1`, [a]);
  const b1 = await book({ pickup_at: new Date(Date.now() + 5 * 864e5).toISOString() });
  const t0 = Number((await db.query(`select total from bookings where id = $1`, [b1])).rows[0].total);
  const after = (await as(U.alpha, `select add_trip_charges($1, $2::jsonb) r`, [b1, JSON.stringify([{ kind: 'wait', minutes: 15 }, { kind: 'toll', amount: 6.25 }])])).rows[0].r;
  check('waiting time (taxed) and tolls (untaxed) are added', near(Number(after.total) - t0, 22.5 * 1.13 + 6.25), `${after.total} vs ${t0}`);
  check('accountant can add charges', !(await fails(U.bravo, `select add_trip_charges($1,'[{"kind":"parking","amount":10}]'::jsonb)`, [b1])));
  check('driver cannot add charges', await fails(U.driver, `select add_trip_charges($1,'[{"kind":"toll","amount":5}]'::jsonb)`, [b1]));
  check('a charge needs an amount', await fails(U.alpha, `select add_trip_charges($1,'[{"kind":"other"}]'::jsonb)`, [b1]));

  // Cancellation fees
  const late = await book({ pickup_at: new Date(Date.now() + 2 * 3600e3).toISOString() });
  const terms = (await as(U.alpha, `select cancellation_terms($1) r`, [late])).rows[0].r;
  check('cancellation terms say it is late, fee 50% of fare', terms.late === true && near(terms.late_fee, 57));
  check('fee needs the booking cancelled first', await fails(U.alpha, `select charge_cancellation($1,'late_cancel')`, [late]));
  await as(U.alpha, `select cancel_booking($1,'Client cancelled late')`, [late]);
  const fee = (await as(U.alpha, `select charge_cancellation($1,'late_cancel') r`, [late])).rows[0].r;
  check('late cancellation leaves only the fee plus tax', near(fee.total, 57 * 1.13), JSON.stringify(fee));
  check('no-show fee needs a no-show trip', await fails(U.alpha, `select charge_cancellation($1,'no_show')`, [b1]));

  // 2. Vehicle showcase
  await as(U.alpha, `update vehicle_classes set description = 'Mercedes E-Class or similar', amenities = array['Wi-Fi','Water'], photo_urls = array['https://x/e.jpg'] where id = $1`, [sedanA]);
  const op = (await asAnon(`select public_operator('alpha') o`)).rows[0].o;
  const sedanPub = op.classes.find(c => c.id === sedanA);
  check('booking page shows class description, amenities and photos', sedanPub.description.startsWith('Mercedes') && sedanPub.amenities.length === 2 && sedanPub.photo_urls.length === 1);
  check('too many photos rejected', await fails(U.alpha, `update vehicle_classes set photo_urls = array['1','2','3','4','5','6','7'] where id = $1`, [sedanA]));

  // 3. Customer records
  await as(U.alpha, `update contacts set tags = array['corporate'], vip = true, preferences = 'Still water, no talking' where id = $1`, [contact]);
  await as(U.alpha, `insert into notes (org_id, contact_id, body) values ($1,$2,'Prefers Dana as driver')`, [a, contact]);
  await as(U.alpha, `insert into notes (org_id, booking_id, body) values ($1,$2,'Gate code 4412')`, [a, b1]);
  check('staff read private notes', (await as(U.alpha, `select count(*)::int n from notes`)).rows[0].n === 2);
  check('accountant reads notes', (await as(U.bravo, `select count(*)::int n from notes where org_id = $1`, [a])).rows[0].n === 2);
  check('customer never sees notes', (await as(U.customer, `select count(*)::int n from notes`)).rows[0].n === 0);
  check('driver never sees notes', (await as(U.driver, `select count(*)::int n from notes`)).rows[0].n === 0);

  // 4. Corporate billing
  const globex = (await as(U.alpha, `insert into accounts (org_id, name, payment_terms_days) values ($1,'Globex',15) returning id`, [a])).rows[0].id;
  const g1 = await book({ pickup_at: await local('2026-11-10 09:00') });
  const g2 = await book({ pickup_at: await local('2026-11-20 18:00') });
  const g3 = await book({ pickup_at: await local('2026-12-02 09:00') });
  await as(U.alpha, `update bookings set account_id = $1 where id in ($2,$3,$4)`, [globex, g1, g2, g3]);
  const inv = (await as(U.bravo, `select create_account_invoice($1,'2026-11-01','2026-11-30') id`, [globex])).rows[0].id;
  const invRow = (await db.query(`select * from invoices where id = $1`, [inv])).rows[0];
  const expect2 = (await db.query(`select sum(total) s from bookings where id in ($1,$2)`, [g1, g2])).rows[0].s;
  check('accountant invoices November: 2 bookings, totals add up', near(invRow.total, expect2) && (await db.query(`select count(*)::int n from invoice_items where invoice_id = $1`, [inv])).rows[0].n === 2);
  check('due date follows the client payment terms', (invRow.due_on - invRow.issued_on) / 864e5 === 15);
  check('same period again has nothing left to bill', (await as(U.bravo, `select create_account_invoice($1,'2026-11-01','2026-11-30') id`, [globex])).rows[0].id === null);
  check('dispatcher cannot invoice', await fails(U.driver, `select create_account_invoice($1,'2026-11-01','2026-11-30')`, [globex]));
  check('payment before sending is refused', await fails(U.bravo, `select record_invoice_payment($1, 10)`, [inv]));
  await as(U.bravo, `select set_invoice_status($1,'sent')`, [inv]);
  const age = (await as(U.bravo, `select * from account_ageing($1)`, [a])).rows;
  check('ageing shows the sent invoice as current', age.some(r => r.account_name === 'Globex' && near(r.current_due, expect2)));
  check('overpayment refused', await fails(U.bravo, `select record_invoice_payment($1, $2)`, [inv, Number(expect2) + 1]));
  await as(U.bravo, `select record_invoice_payment($1, 100, 'cheque', 'CHQ-1001')`, [inv]);
  check('part payment is spread to the first booking', near((await db.query(`select paid_amount from bookings where id = $1`, [g1])).rows[0].paid_amount, 100));
  const rest = (await as(U.bravo, `select record_invoice_payment($1, $2, 'bank_transfer', 'WIRE-77') r`, [inv, Number(expect2) - 100])).rows[0].r;
  check('full payment marks the invoice paid and both bookings paid', rest.status === 'paid'
    && (await db.query(`select count(*)::int n from bookings where id in ($1,$2) and payment_status = 'paid'`, [g1, g2])).rows[0].n === 2, JSON.stringify(rest));
  check('paid invoice cannot be voided', await fails(U.bravo, `select set_invoice_status($1,'void')`, [inv]));

  // 5. Payroll
  await as(U.alpha, `update drivers set pay_percent = 30 where id = $1`, [driverId]);
  const p1 = await book({ pickup_at: await local('2026-10-05 10:00'), tip_percent: 10 });
  const pt = (await db.query(`select id from trips where booking_id = $1`, [p1])).rows[0].id;
  await as(U.alpha, `update trips set driver_id = $2, status = 'assigned' where id = $1`, [pt, driverId]);
  await as(U.alpha, `update trips set status = 'completed' where id = $1`, [pt]);
  const run = (await as(U.bravo, `select create_pay_run($1,'2026-10-01','2026-10-31') id`, [a])).rows[0].id;
  const line = (await db.query(`select * from pay_run_lines where pay_run_id = $1 and driver_id = $2`, [run, driverId])).rows[0];
  const tc = (await db.query(`select driver_pay, pay_run_id from trip_costs where trip_id = $1`, [pt])).rows[0];
  check('auto pay is 30% of the fare and the trip joins the run', near(tc.driver_pay, 34.2) && tc.pay_run_id === run, JSON.stringify(tc));
  check('pay run line adds tips to pay', near(line.tips, 11.4) && near(line.total, Number(line.driver_pay) + Number(line.tips)), JSON.stringify(line));
  check('trips are not paid twice', (await as(U.bravo, `select create_pay_run($1,'2026-10-01','2026-10-31') id`, [a])).rows[0].id === null);
  check('driver sees own pay line', (await as(U.driver, `select count(*)::int n from pay_run_lines`)).rows[0].n >= 1);
  await as(U.bravo, `select delete_pay_run($1)`, [run]);
  const run2 = (await as(U.bravo, `select create_pay_run($1,'2026-10-01','2026-10-31') id`, [a])).rows[0].id;
  check('deleting a draft run releases its trips', run2 !== null);
  await as(U.bravo, `select set_pay_run_paid($1)`, [run2]);
  check('paid run cannot be deleted', await fails(U.bravo, `select delete_pay_run($1)`, [run2]));

  // 6. Recurring (crosses the end of daylight saving on 1 Nov 2026)
  const series = (await as(U.alpha, `select create_recurring_bookings($1,$2,$3::jsonb,$4::jsonb) r`, [a, contact,
    P({ passenger_name: 'Commuter', pickup_address: 'Home', pickup_at: await local('2026-10-26 08:30') }),
    JSON.stringify({ freq: 'weekly', days: [1, 3, 5], until: '2026-11-06' })])).rows[0].r;
  check('weekly Mon/Wed/Fri for two weeks makes 6 bookings', series.count === 6);
  const hours = (await db.query(`select distinct to_char(t.pickup_at at time zone 'America/Toronto','HH24:MI') h from trips t join bookings b on b.id = t.booking_id where b.series_id = $1`, [series.series_id])).rows;
  check('local pickup time stays 08:30 across the clock change', hours.length === 1 && hours[0].h === '08:30');
  check('daily every 2 days', (await as(U.alpha, `select create_recurring_bookings($1,$2,$3::jsonb,$4::jsonb) r`, [a, contact,
    P({ passenger_name: 'D', pickup_address: 'H', pickup_at: await local('2026-11-10 07:00') }), JSON.stringify({ freq: 'daily', every: 2, until: '2026-11-16' })])).rows[0].r.count === 4);
  check('more than 60 is refused', await fails(U.alpha, `select create_recurring_bookings($1,$2,$3::jsonb,$4::jsonb)`, [a, contact,
    P({ passenger_name: 'D', pickup_address: 'H', pickup_at: await local('2026-11-10 07:00') }), JSON.stringify({ freq: 'daily', until: '2027-06-01' })]));
  const cancelled = (await as(U.alpha, `select cancel_series($1,'2026-11-02') n`, [series.series_id])).rows[0].n;
  check('cancel the rest of a series from a date', cancelled === 3);

  // 7. Availability and 8. compliance
  const at = (await db.query(`select id, pickup_at from trips where booking_id = $1`, [g3])).rows[0];
  const veh = (await as(U.alpha, `insert into vehicles (org_id, class_id, label, plate) values ($1,$2,'Sedan 7','ABC 123') returning id`, [a, sedanA])).rows[0].id;
  await as(U.alpha, `insert into driver_shifts (org_id, driver_id, kind, starts_at, ends_at, note) values ($1,$2,'time_off',$3::timestamptz - interval '1 hour',$3::timestamptz + interval '1 day','Vacation')`, [a, driverId, at.pickup_at]);
  await as(U.alpha, `insert into vehicle_blocks (org_id, vehicle_id, starts_at, ends_at, reason) values ($1,$2,$3::timestamptz - interval '2 hours',$3::timestamptz + interval '2 hours','Brakes')`, [a, veh, at.pickup_at]);
  await as(U.alpha, `insert into vehicle_documents (org_id, vehicle_id, kind, expires_on) values ($1,$2,'Insurance', current_date - 1)`, [a, veh]);
  await as(U.alpha, `insert into driver_documents (org_id, driver_id, kind, expires_on) values ($1,$2,'Chauffeur licence', current_date + 10)`, [a, driverId]);
  const warns = (await as(U.alpha, `select assignment_warnings($1,$2,$3) w`, [at.id, driverId, veh])).rows[0].w.map(w => w.code).sort();
  check('assign warnings: time off, vehicle blocked, expired insurance', ['time_off', 'vehicle_blocked', 'vehicle_document_expired'].every(c => warns.includes(c)), JSON.stringify(warns));
  const free = (await as(U.alpha, `select assignment_warnings($1,null,null) w`, [at.id])).rows[0].w;
  check('no warnings when nobody is chosen', free.length === 0);
  const alerts = (await as(U.alpha, `select * from compliance_alerts($1, 30)`, [a])).rows;
  check('compliance lists expired and soon-expiring documents', alerts.some(r => r.kind === 'Insurance' && r.days_left === -1) && alerts.some(r => r.kind === 'Chauffeur licence' && r.days_left === 10));
  check('outsider cannot read compliance', await fails(OUT, `select * from compliance_alerts($1)`, [a]));

  // 9. Ratings
  const done = await book({ pickup_at: new Date(Date.now() + 864e5).toISOString() });
  const code = (await db.query(`select public_code from bookings where id = $1`, [done])).rows[0].public_code;
  check('cannot rate before the trip is done', await (async () => { try { await asAnon(`select public_rate_booking('alpha',$1,5)`, [code]); return false; } catch { return true; } })());
  const dt = (await db.query(`select id from trips where booking_id = $1`, [done])).rows[0].id;
  await as(U.alpha, `update trips set driver_id = $2, status = 'completed' where id = $1`, [dt, driverId]);
  await as(U.alpha, `update bookings set status = 'completed' where id = $1`, [done]);
  check('status page offers rating', (await asAnon(`select public_booking_status('alpha',$1) s`, [code])).rows[0].s.can_rate === true);
  await asAnon(`select public_rate_booking('alpha',$1,5,'Immaculate car')`, [code]);
  check('rating once only', await (async () => { try { await asAnon(`select public_rate_booking('alpha',$1,4)`, [code]); return false; } catch { return true; } })());
  check('driver average rating', (await as(U.alpha, `select * from driver_ratings($1)`, [a])).rows.some(r => r.driver_name === 'Dana Driver' && Number(r.average) === 5));

  // 10. Notifications
  await as(U.alpha, `update contacts set email = 'casey@test.com', phone = '+14165550999' where id = $1`, [contact]);
  check('default templates install (16)', (await as(U.alpha, `select install_default_templates($1) n`, [a])).rows[0].n === 16);
  check('installing again adds none', (await as(U.alpha, `select install_default_templates($1) n`, [a])).rows[0].n === 0);
  await db.query(`update platform_settings set app_url = 'https://velvet.example/'`);
  const nb = await book({ pickup_at: await local('2026-12-10 14:15') });
  const conf = (await db.query(`select * from notification_outbox where booking_id = $1 and event = 'booking_confirmed' order by channel`, [nb])).rows;
  check('confirmation email and SMS queued on booking', conf.length === 2 && conf[0].to_address === 'casey@test.com' && conf[1].to_address === '+14165550123', JSON.stringify(conf.map(c => c.to_address)));
  check('placeholders filled, time in operator timezone, link built', !conf[0].body.includes('{{') && conf[0].body.includes('02:15 PM') && conf[0].body.includes('https://velvet.example/book/alpha/status/'), conf[0].body);
  const nt = (await db.query(`select id from trips where booking_id = $1`, [nb])).rows[0].id;
  await as(U.alpha, `select assign_trip($1,$2,$3)`, [nt, driverId, veh]);
  const asg = (await db.query(`select body from notification_outbox where booking_id = $1 and event = 'driver_assigned'`, [nb])).rows[0];
  check('driver assigned SMS names driver and car', asg && asg.body.includes('Dana Driver') && asg.body.includes('ABC 123'), asg?.body);
  await as(U.alpha, `select cancel_booking($1)`, [nb]);
  check('cancellation email queued', (await db.query(`select count(*)::int n from notification_outbox where booking_id = $1 and event = 'booking_cancelled'`, [nb])).rows[0].n === 1);
  check('preview fills a template', (await as(U.alpha, `select preview_template($1,'Hi {{passenger_name}}') t`, [nb])).rows[0].t === 'Hi Robin Rider');
  check('customer cannot read the outbox', (await as(U.customer, `select count(*)::int n from notification_outbox`)).rows[0].n === 0);
  check('dispatcher cannot edit templates', (await as('00000000-0000-0000-0000-000000000101', `update notification_templates set body = 'x' returning id`)).rows.length === 0);

  // 11. Terms
  await as(U.alpha, `update orgs set require_terms = true, terms_text = 'Cancellations within 24 hours are charged 50%.', terms_version = 2 where id = $1`, [a]);
  const req = P({ booker_name: 'Terry', booker_email: 'terry@test.com', pickup_at: new Date(Date.now() + 3 * 864e5).toISOString(), pickup_address: 'A' });
  check('booking page refuses without accepting terms', await (async () => { try { await asAnon(`select public_create_booking_v2('alpha',$1::jsonb)`, [req]); return false; } catch { return true; } })());
  const okReq = (await asAnon(`select public_create_booking_v2('alpha',$1::jsonb) r`, [JSON.stringify({ ...JSON.parse(req), accept_terms: true })])).rows[0].r;
  check('accepted terms version is stored', (await db.query(`select terms_version from bookings where public_code = $1`, [okReq.public_code])).rows[0].terms_version === 2);
  check('booking page shows the terms', (await asAnon(`select public_operator('alpha') o`)).rows[0].o.terms_text.startsWith('Cancellations'));
  await as(U.alpha, `update orgs set require_terms = false where id = $1`, [a]);
}

console.log('Moovs parity (0013)');
{
  const near = (x, y) => Math.abs(Number(x) - Number(y)) < 0.011;
  const P = (o) => JSON.stringify({ class_id: sedanA, service: 'one_way', distance: 10, ...o });
  const pr = async (o) => (await as(U.alpha, `select price_trip($1,$2::jsonb) q`, [a, P(o)])).rows[0].q;

  // 1. Zone polygons
  const pz2 = (await db.query(`select id from zones where org_id = $1 and name = 'Pearson'`, [a])).rows[0].id;
  const poly = [[43.70, -79.42], [43.70, -79.30], [43.60, -79.30], [43.60, -79.42]];
  const coreZone = (await as(U.alpha, `insert into zones (org_id, name, kind, lat, lng, radius_km, boundary) values ($1,'Core','area',43.65,-79.36,1,$2::jsonb) returning id`, [a, JSON.stringify(poly)])).rows[0].id;
  await as(U.alpha, `insert into zone_rates (org_id, class_id, from_zone, to_zone, amount) values ($1,$2,$3,$4,77)`, [a, sedanA, pz2, coreZone]);
  let qz = await pr({ pickup_lat: 43.68, pickup_lng: -79.62, dropoff_lat: 43.65, dropoff_lng: -79.35 });
  check('polygon zone matches a point inside the ring', near(qz.lines[0].amount, 77) && qz.lines[0].description === 'Flat rate Pearson to Core', JSON.stringify(qz.lines[0]));
  qz = await pr({ pickup_lat: 43.68, pickup_lng: -79.62, dropoff_lat: 43.9, dropoff_lng: -79.0 });
  check('polygon zone does not match a point outside the ring', !qz.lines.some((l) => near(l.amount, 77)));
  const upsertId = (await as(U.alpha, `select upsert_zone($1,'Core','area',43.65,-79.36,1,$2::jsonb) id`, [a, JSON.stringify(poly)])).rows[0].id;
  check('upsert_zone updates the existing zone by name', upsertId === coreZone);

  // A drawn-boundary zone has no radius (the frontend sends radius_km = null for these); the
  // column must accept that, matching app.zone_fare's coalesce(radius_km, 0) treatment (0014).
  const noRadiusId = (await as(U.alpha, `select upsert_zone($1,'Core 2','area',43.65,-79.36,null,$2::jsonb) id`, [a, JSON.stringify(poly)])).rows[0].id;
  check('a drawn zone saves with no radius', !!noRadiusId);

  // 2. Driver scorecards and penalties folded into pay runs
  const lateBooking = (await as(U.alpha, `select create_booking_v2($1,$2,$3::jsonb) id`, [a, contact,
    P({ passenger_name: 'Late Rider', pickup_address: 'A', pickup_at: new Date(Date.now() + 2 * 864e5).toISOString() })])).rows[0].id;
  const lateTrip = (await db.query(`select id, pickup_at from trips where booking_id = $1`, [lateBooking])).rows[0];
  await as(U.alpha, `update trips set driver_id = $2, status = 'completed' where id = $1`, [lateTrip.id, driverId]);
  await as(U.alpha, `insert into trip_events (org_id, trip_id, status, created_at) values ($1,$2,'arrived',$3::timestamptz + interval '20 minutes')`, [a, lateTrip.id, lateTrip.pickup_at]);
  await as(U.alpha, `insert into trip_costs (trip_id, org_id, driver_pay) values ($1,$2,50) on conflict (trip_id) do update set driver_pay = 50`, [lateTrip.id, a]);

  const card = (await as(U.alpha, `select driver_scorecard($1,$2) c`, [a, driverId])).rows[0].c;
  check('scorecard reports trips and on-time percentage', card.trips_90d >= 1 && card.on_time_pct !== null, JSON.stringify(card));
  check('outsider cannot read a scorecard', await fails(U.customer, `select driver_scorecard($1,$2)`, [a, driverId]));

  const ruleId = (await as(U.alpha, `insert into penalty_rules (org_id, name, trigger, late_minutes, percent) values ($1,'Late 10%','late',10,10) returning id`, [a])).rows[0].id;
  const nCreated = (await as(U.alpha, `select apply_penalty_rules($1) n`, [a])).rows[0].n;
  check('apply_penalty_rules creates a pending penalty for the late trip', nCreated >= 1);
  const pending = (await db.query(`select amount, status from driver_penalties where trip_id = $1`, [lateTrip.id])).rows[0];
  check('penalty amount is 10% of that trip\'s driver pay', near(pending.amount, 5) && pending.status === 'pending', JSON.stringify(pending));
  check('apply_penalty_rules does not duplicate an existing penalty', (await as(U.alpha, `select apply_penalty_rules($1) n`, [a])).rows[0].n === 0);

  const period = (await db.query(`select ((pickup_at::timestamptz) at time zone 'America/Toronto')::date d from trips where id = $1`, [lateTrip.id])).rows[0].d;
  const run3 = (await as(U.alpha, `select create_pay_run($1,$2,$2) r`, [a, period])).rows[0].r;
  const line = (await db.query(`select adjustment, adjustment_note from pay_run_lines where pay_run_id = $1 and driver_id = $2`, [run3, driverId])).rows[0];
  check('pay run folds the pending penalty in as a negative adjustment', line && near(line.adjustment, -5) && line.adjustment_note === 'Penalties this period', JSON.stringify(line));
  check('the penalty is marked applied and linked to the pay run', (await db.query(`select status, pay_run_id from driver_penalties where trip_id = $1`, [lateTrip.id])).rows[0].status === 'applied');

  const ruleId2 = (await as(U.alpha, `insert into penalty_rules (org_id, name, trigger, amount) values ($1,'Manual','other',15) returning id`, [a])).rows[0].id;
  const manualPenalty = (await as(U.alpha, `select add_driver_penalty($1,$2,20,'Phone off during shift') id`, [a, driverId])).rows[0].id;
  await as(U.alpha, `select void_driver_penalty($1)`, [manualPenalty]);
  check('a voided penalty is excluded from the next pay run', (await db.query(`select status from driver_penalties where id = $1`, [manualPenalty])).rows[0].status === 'voided');

  // 3. Disputes
  const payId = (await as(U.alpha, `insert into payments (org_id, booking_id, provider, provider_ref, amount, currency, status) values ($1,$2,'stripe','sess_t1',150,'CAD','succeeded') returning id`, [a, lateBooking])).rows[0].id;
  const disputeId = (await as(U.alpha, `insert into disputes (org_id, payment_id, booking_id, stripe_dispute_id, amount, currency, reason) values ($1,$2,$3,'dp_t1',150,'CAD','fraudulent') returning id`, [a, payId, lateBooking])).rows[0].id;
  const ev = (await as(U.alpha, `select dispute_evidence($1) e`, [disputeId])).rows[0].e;
  check('dispute evidence bundles the booking and trip timeline', ev.booking.passenger_name === 'Late Rider' && ev.trips.length >= 1 && ev.trips[0].timeline.some((t) => t.status === 'arrived'), JSON.stringify(ev).slice(0, 300));
  await as(U.alpha, `select set_dispute_status($1,'won')`, [disputeId]);
  check('dispute status updates and resolves', (await db.query(`select status, resolved_at is not null r from disputes where id = $1`, [disputeId])).rows[0].status === 'won');
  check('a customer cannot read disputes', (await as(U.customer, `select count(*)::int n from disputes`)).rows[0].n === 0);

  // 4. Ranked driver suggestions
  const freshBooking = (await as(U.alpha, `select create_booking_v2($1,$2,$3::jsonb) id`, [a, contact,
    P({ passenger_name: 'Suggest Me', pickup_address: 'Pearson T1', pickup_lat: 43.68, pickup_lng: -79.62, pickup_at: new Date(Date.now() + 6 * 864e5).toISOString() })])).rows[0].id;
  const freshTrip = (await db.query(`select id from trips where booking_id = $1`, [freshBooking])).rows[0].id;
  const sugg = (await as(U.alpha, `select suggest_drivers($1,5) s`, [freshTrip])).rows[0].s;
  const dana = sugg.find((s) => s.driver_id === driverId);
  // Dana has real history by this point (one late arrival earlier in this suite), so she's scored
  // on her actual 50% on-time record rather than the 90% default other untested drivers get —
  // ranking below them here is correct, not a bug. Check she's present with reasons reflecting it.
  check('suggest_drivers includes the driver with real history, scored on their actual record',
    !!dana && dana.reasons.length > 0 && dana.on_time_pct === 50, JSON.stringify(sugg));
  check('suggest_drivers returns results sorted by score, highest first',
    sugg.every((s, i) => i === 0 || sugg[i - 1].score >= s.score));
  check('a customer cannot call suggest_drivers', await fails(U.customer, `select suggest_drivers($1,5)`, [freshTrip]));

  // 5. Global search
  const gs = (await as(U.alpha, `select global_search($1,'Robin') s`, [a])).rows[0].s;
  check('global search finds a booking by passenger name', gs.bookings.some((b) => b.passenger_name === 'Robin Rider'));
  const gs2 = (await as(U.alpha, `select global_search($1,'Casey') s`, [a])).rows[0].s;
  check('global search finds a contact by name', gs2.contacts.some((c) => c.name === 'Casey Customer'));
  check('a one-character query returns empty, not an error', (await as(U.alpha, `select global_search($1,'a') s`, [a])).rows[0].s.bookings.length === 0);
  // Use a brand-new user who was never invited anywhere (bravo is, by this point in the suite,
  // a legitimate accountant member of alpha via the "existing account added at once" test above).
  const outsiderId = '00000000-0000-0000-0000-000000009999';
  await db.query(`insert into auth.users (id, email) values ($1, 'outsider@test.com')`, [outsiderId]);
  check('a non-member cannot search alpha\'s data', await fails(outsiderId, `select global_search($1,'Robin')`, [a]));
}

console.log('Currency and FX (0015)');
{
  // Alpha Limo (a) is CAD; the farm-out inserted earlier (line 122) carried no currency, so the
  // trigger must have stamped it from the originating org, not left it null or copied the partner's.
  const stamped = (await db.query(`select currency from farm_outs where from_org_id = $1 and to_org_id = $2`, [a, b])).rows[0];
  check('an untagged farm-out is stamped with the originating org\'s currency', stamped?.currency === 'CAD', JSON.stringify(stamped));

  // A farm-out that does specify a currency is left alone by the trigger.
  const explicit = (await as(U.alpha, `insert into farm_outs (from_org_id, to_org_id, trip_id, partner_price, currency) values ($1,$2,$3,120,'EUR') returning currency`, [a, b, trip])).rows[0];
  check('a farm-out that names its own currency keeps it', explicit.currency === 'EUR');

  check('to_usd converts using the seeded rate', Number((await db.query(`select to_usd('CAD', 100) v`)).rows[0].v) === 73);
  check('to_usd on an unknown currency code falls back to 1:1', (await db.query(`select to_usd('ZZZ', 50) v`)).rows[0].v == 50);

  check('a non-admin cannot set an exchange rate', await fails(U.alpha, `select set_fx_rate('CAD', 0.80)`));
  await as(BOSS, `select set_fx_rate('CAD', 0.80)`);
  check('a platform admin can set an exchange rate, and to_usd picks it up', (await db.query(`select to_usd('CAD', 100) v`)).rows[0].v == 80);
  check('set_fx_rate rejects a non-positive rate', await fails(BOSS, `select set_fx_rate('CAD', 0)`));

  const ov = (await as(BOSS, `select platform_overview() o`)).rows[0].o;
  check('platform_overview adds a combined USD total alongside the per-currency breakdown', typeof ov.booking_value_30d === 'object' && typeof ov.booking_value_30d_usd === 'number', JSON.stringify(ov.booking_value_30d_usd));

  const companies = (await as(BOSS, `select * from platform_companies()`)).rows;
  check('platform_companies reports a USD-converted revenue figure per company', companies.every((c) => Number.isFinite(Number(c.revenue_30d_usd))), JSON.stringify(companies.map((c) => c.revenue_30d_usd)));

  check('a non-admin cannot change a company\'s currency', await fails(U.alpha, `select platform_set_org_currency($1, 'USD')`, [a]));
  check('platform_set_org_currency rejects an unknown currency', await fails(BOSS, `select platform_set_org_currency($1, 'ZZZ')`, [a]));
  await as(BOSS, `select platform_set_org_currency($1, 'USD')`, [a]);
  check('a platform admin can change a company\'s currency after signup', (await db.query(`select default_currency from orgs where id = $1`, [a])).rows[0].default_currency === 'USD');
  // Put it back so later-numbered checks elsewhere in this file that assume CAD still pass.
  await as(BOSS, `select platform_set_org_currency($1, 'CAD')`, [a]);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
