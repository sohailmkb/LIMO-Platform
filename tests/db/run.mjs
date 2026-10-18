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
async function fails(user, sql, params = []) {
  try { await as(user, sql, params); return false; } catch { return true; }
}

// --- Supabase shim -------------------------------------------------
await db.exec(`
  create schema auth;
  create table auth.users (id uuid primary key);
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

for (const id of Object.values(U)) await db.query('insert into auth.users (id) values ($1)', [id]);

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

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
