-- Demo data: one operator in Toronto, a driver, and two bookings.
-- 1. Create the user(s) first in Supabase: Authentication > Users > Add user (tick Auto Confirm).
-- 2. Put their emails below. Owner and driver can be the SAME email; the app then
--    offers "Operator" and "Driver" on its workspace screen.
-- 3. Run this whole file once in SQL Editor.

do $$
declare
  owner_email  text := 'OWNER_EMAIL_HERE';
  driver_email text := 'DRIVER_EMAIL_HERE';
  v_owner uuid; v_driver uuid; v_org uuid; v_sedan uuid; v_drv uuid;
  v_contact uuid; v_booking uuid; v_trip uuid;
begin
  select id into v_owner  from auth.users where lower(email) = lower(owner_email);
  select id into v_driver from auth.users where lower(email) = lower(driver_email);
  if v_owner is null then
    raise exception 'No Supabase user with email %. Create it under Authentication > Users first.', owner_email;
  end if;
  if v_driver is null then
    raise exception 'No Supabase user with email %. Create it under Authentication > Users first.', driver_email;
  end if;
  if exists (select 1 from orgs where slug = 'demo-toronto') then
    raise exception 'The demo operator already exists. Nothing changed.';
  end if;

  -- Act as the owner so create_operator sets them up as owner.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  v_org := public.create_operator('Demo Limo Toronto', 'demo-toronto', 'CA', 'CAD', 'en',
                                  'America/Toronto', 'metric', false, 'CA-ON-HST');

  select id into v_sedan from vehicle_classes where org_id = v_org and name = 'Sedan';

  insert into drivers (org_id, user_id, full_name) values (v_org, v_driver, 'Demo Driver')
  returning id into v_drv;
  insert into memberships (org_id, user_id, role) values (v_org, v_driver, 'driver')
  on conflict do nothing;

  insert into contacts (org_id, full_name, email) values (v_org, 'Demo Customer', 'customer@example.com')
  returning id into v_contact;

  -- Booking 1: 30 km airport run, assigned to the demo driver. Should total 135.60 CAD.
  v_booking := public.create_booking(v_org, v_contact, 'Pat Passenger', '+14165550100', 'one_way', v_sedan,
                 now() + interval '2 hours', 'Toronto Pearson Airport, Terminal 1', 'CN Tower, 290 Bremner Blvd', 30, 0);
  select id into v_trip from trips where booking_id = v_booking;
  perform public.assign_trip(v_trip, v_drv, null);

  -- Booking 2: short hop, left unassigned for the operator to dispatch.
  perform public.create_booking(v_org, v_contact, 'Sam Traveller', '+14165550101', 'one_way', v_sedan,
                 now() + interval '1 day', 'Union Station', 'Billy Bishop Airport', 5, 0);
end $$;

-- Check: expect two rows, the first with total 135.60 CAD.
select b.number, b.passenger_name, b.subtotal, b.tax_total, b.total, b.currency, t.status as trip_status
from bookings b join trips t on t.booking_id = b.id
where b.org_id = (select id from orgs where slug = 'demo-toronto')
order by b.number;
