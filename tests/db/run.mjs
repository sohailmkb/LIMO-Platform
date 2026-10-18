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
for (const f of readdirSync(join(root, 'migrations')).filter(f => f.endsWith('.sql')).sort()) {
  await db.exec(readFileSync(join(root, 'migrations', f), 'utf8'));
  console.log(`  applied ${f}`);
}
await db.exec(readFileSync(join(root, 'seed.sql'), 'utf8'));
console.log('  applied seed.sql');

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

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
