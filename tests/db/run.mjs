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
  create table auth.users (id uuid primary key, email text);
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

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
