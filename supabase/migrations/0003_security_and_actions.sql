-- 0003_security_and_actions: row-level security, ownership helpers,
-- totals triggers, app actions (RPC), margin view.

-- ---------------------------------------------------------------
-- Ownership helpers (SECURITY DEFINER so they are not filtered by RLS)
-- ---------------------------------------------------------------
create function app.owns_contact(p_contact uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from contacts c where c.id = p_contact and c.user_id = auth.uid());
$$;

create function app.owns_booking(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from bookings b join contacts c on c.id = b.booker_id
    where b.id = p_booking and c.user_id = auth.uid()
  );
$$;

create function app.drives_trip(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from trips t join drivers d on d.id = t.driver_id
    where t.id = p_trip and d.user_id = auth.uid()
  );
$$;

create function app.is_partner_staff(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from farm_outs f
    where f.trip_id = p_trip and f.status in ('offered','accepted')
      and app.is_staff(f.to_org_id)
  );
$$;

-- ---------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------
alter table plans            enable row level security;
alter table currencies       enable row level security;
alter table locales          enable row level security;
alter table tax_presets      enable row level security;
alter table orgs             enable row level security;
alter table profiles         enable row level security;
alter table memberships      enable row level security;
alter table tax_rates        enable row level security;
alter table audit_log        enable row level security;
alter table vehicle_classes  enable row level security;
alter table vehicles         enable row level security;
alter table drivers          enable row level security;
alter table driver_documents enable row level security;
alter table accounts         enable row level security;
alter table contacts         enable row level security;
alter table rate_cards       enable row level security;
alter table surcharges       enable row level security;
alter table bookings         enable row level security;
alter table booking_lines    enable row level security;
alter table trips            enable row level security;
alter table trip_costs       enable row level security;
alter table trip_events      enable row level security;
alter table driver_locations enable row level security;
alter table payments         enable row level security;
alter table farm_outs        enable row level security;

-- Reference data: readable by everyone, writable by no client.
create policy ref_read on plans       for select using (true);
create policy ref_read on currencies  for select using (true);
create policy ref_read on locales     for select using (true);
create policy ref_read on tax_presets for select using (true);

-- Tenancy
create policy orgs_read   on orgs for select using (app.is_member(id));
create policy orgs_update on orgs for update using (app.has_role(id, array['owner','admin']))
  with check (app.has_role(id, array['owner','admin']));

create policy profiles_own on profiles for all using (id = auth.uid()) with check (id = auth.uid());

create policy memberships_read on memberships for select
  using (user_id = auth.uid() or app.is_staff(org_id));
create policy memberships_write on memberships for all
  using (app.has_role(org_id, array['owner','admin']))
  with check (app.has_role(org_id, array['owner','admin']));

-- Staff-only tables
create policy staff_all on tax_rates        for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on audit_log        for select using (app.is_staff(org_id));
create policy staff_all on vehicles         for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on driver_documents for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on accounts         for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on contacts         for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on rate_cards       for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on surcharges       for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on payments         for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on trip_costs       for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));

-- Vehicle classes: staff manage, customers of the org can read (to choose a car)
create policy staff_all on vehicle_classes for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy member_read on vehicle_classes for select using (app.is_member(org_id));

-- Drivers: staff manage, a driver sees and updates own row
create policy staff_all on drivers for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy driver_self_read   on drivers for select using (user_id = auth.uid());
create policy driver_self_update on drivers for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Bookings and lines: staff manage, customers read their own
create policy staff_all on bookings for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy customer_read on bookings for select using (app.owns_contact(booker_id));
create policy staff_all on booking_lines for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy customer_read on booking_lines for select using (app.owns_booking(booking_id));

-- Trips: staff manage; driver reads assigned trips; customer reads own; partner reads farmed-out trip
create policy staff_all on trips for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy driver_read on trips for select using (app.drives_trip(id));
create policy customer_read on trips for select using (app.owns_booking(booking_id));
create policy partner_read on trips for select using (app.is_partner_staff(id));

create policy staff_all on trip_events for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy driver_read on trip_events for select using (app.drives_trip(trip_id));
create policy customer_read on trip_events for select using (
  exists (select 1 from trips t where t.id = trip_events.trip_id and app.owns_booking(t.booking_id))
);

-- Live location: staff read; a driver writes own position
create policy staff_read on driver_locations for select using (app.is_staff(org_id));
create policy driver_write on driver_locations for all
  using (exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid()))
  with check (exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid()));

-- Network
create policy farm_read   on farm_outs for select using (app.is_staff(from_org_id) or app.is_staff(to_org_id));
create policy farm_create on farm_outs for insert with check (app.is_staff(from_org_id));
create policy farm_update on farm_outs for update
  using (app.is_staff(from_org_id) or app.is_staff(to_org_id))
  with check (app.is_staff(from_org_id) or app.is_staff(to_org_id));

-- ---------------------------------------------------------------
-- Totals: bookings.subtotal / tax_total / total follow booking_lines
-- ---------------------------------------------------------------
create function app.recalc_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update bookings b set
    subtotal  = coalesce(s.sub, 0),
    tax_total = coalesce(s.tax, 0),
    total     = coalesce(s.sub, 0) + coalesce(s.tax, 0)
  from (select sum(amount) sub, sum(tax_amount) tax from booking_lines where booking_id = p_booking) s
  where b.id = p_booking;
end $$;

create function app.booking_lines_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.recalc_booking(coalesce(new.booking_id, old.booking_id));
  return null;
end $$;

create trigger booking_lines_totals
  after insert or update or delete on booking_lines
  for each row execute function app.booking_lines_changed();

create function app.payments_changed() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_booking uuid := coalesce(new.booking_id, old.booking_id); v_paid numeric(12,2); v_total numeric(12,2);
begin
  select coalesce(sum(amount), 0) into v_paid from payments where booking_id = v_booking and status = 'succeeded';
  select total into v_total from bookings where id = v_booking;
  update bookings set
    paid_amount = v_paid,
    payment_status = case
      when v_paid <= 0 then 'unpaid'
      when v_paid >= v_total then 'paid'
      else 'partial' end
  where id = v_booking;
  return null;
end $$;

create trigger payments_totals
  after insert or update or delete on payments
  for each row execute function app.payments_changed();

-- ---------------------------------------------------------------
-- Actions (called as RPC from web and mobile)
-- ---------------------------------------------------------------

-- Sign-up: one call provisions the operator with working defaults.
create function public.create_operator(
  p_name text, p_slug text, p_country text, p_currency text, p_locale text,
  p_timezone text default 'UTC', p_unit_system text default 'metric',
  p_clock_24h boolean default true, p_tax_preset text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_org  uuid;
  v_class uuid;
  v_mult numeric;
  r record;
begin
  if v_user is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  insert into profiles (id) values (v_user) on conflict do nothing;

  insert into orgs (name, slug, country, timezone, default_currency, default_locale,
                    unit_system, clock_24h, plan_id, trial_ends_at)
  values (p_name, p_slug, p_country, p_timezone, p_currency, p_locale,
          p_unit_system, p_clock_24h, 'starter', now() + interval '14 days')
  returning id into v_org;

  insert into memberships (org_id, user_id, role) values (v_org, v_user, 'owner');

  insert into tax_rates (org_id, code, label, rate, kind, is_default)
  select v_org, code, label, rate, kind, (code = p_tax_preset)
  from tax_presets where country = p_country;

  if not exists (select 1 from tax_rates where org_id = v_org and is_default) then
    insert into tax_rates (org_id, code, label, rate, kind, is_default)
    values (v_org, 'NONE', 'No tax', 0, 'NONE', true)
    on conflict (org_id, code) do update set is_default = true;
  end if;

  -- Starter fleet classes and rate cards. Placeholder prices the operator edits.
  for r in select * from (values
    ('Sedan', 3, 2, 1.0, 1), ('SUV', 6, 4, 1.4, 2), ('Van', 10, 8, 2.0, 3)
  ) as t(name, seats, luggage, mult, ord)
  loop
    insert into vehicle_classes (org_id, name, seats, luggage, sort_order)
    values (v_org, r.name, r.seats, r.luggage, r.ord) returning id into v_class;

    insert into rate_cards (org_id, class_id, service_type, currency, base_amount, per_distance, per_hour, minimum_amount)
    values
      (v_org, v_class, 'one_way', p_currency, round(60 * r.mult, 2), round(2 * r.mult, 2), 0, round(80 * r.mult, 2)),
      (v_org, v_class, 'hourly',  p_currency, 0, 0, round(75 * r.mult, 2), round(150 * r.mult, 2));
  end loop;

  insert into audit_log (org_id, actor_id, action, entity, entity_id)
  values (v_org, v_user, 'create', 'org', v_org);

  return v_org;
end $$;

-- Price a trip. Returns lines, subtotal, tax and total as jsonb.
create function public.quote_price(
  p_org uuid, p_class uuid, p_service text,
  p_distance numeric default 0, p_hours numeric default 0, p_tax_rate uuid default null
) returns jsonb
language plpgsql stable as $$
declare
  v_cur text;
  v_card rate_cards;
  v_tax tax_rates;
  v_fare numeric(12,2);
  v_lines jsonb := '[]'::jsonb;
  v_sub numeric(12,2) := 0;
  v_taxsum numeric(12,2) := 0;
  v_amt numeric(12,2);
  v_tax_amt numeric(12,2);
  s record;
begin
  select default_currency into v_cur from orgs where id = p_org;
  if v_cur is null then raise exception 'unknown operator'; end if;

  select * into v_card from rate_cards
   where org_id = p_org and class_id = p_class and service_type = p_service and currency = v_cur;
  if not found then raise exception 'no rate card for this vehicle class and service'; end if;

  if p_tax_rate is not null then
    select * into v_tax from tax_rates where id = p_tax_rate and org_id = p_org;
  else
    select * into v_tax from tax_rates where org_id = p_org and is_default;
  end if;
  if v_tax.id is null then raise exception 'no tax rate configured'; end if;

  v_fare := greatest(
    v_card.minimum_amount,
    round(v_card.base_amount
          + case when p_service = 'one_way' then v_card.per_distance * coalesce(p_distance, 0) else 0 end
          + case when p_service = 'hourly'  then v_card.per_hour * coalesce(p_hours, 0) else 0 end, 2));

  v_tax_amt := round(v_fare * v_tax.rate, 2);
  v_lines := v_lines || jsonb_build_object('kind','fare','description','Fare','amount',v_fare,'tax_amount',v_tax_amt);
  v_sub := v_fare; v_taxsum := v_tax_amt;

  for s in select * from surcharges where org_id = p_org and active order by name loop
    v_amt := case s.amount_type when 'fixed' then round(s.amount, 2) else round(v_fare * s.amount, 2) end;
    v_tax_amt := round(v_amt * v_tax.rate, 2);
    v_lines := v_lines || jsonb_build_object('kind','surcharge','description',s.name,'amount',v_amt,'tax_amount',v_tax_amt);
    v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_tax_amt;
  end loop;

  return jsonb_build_object(
    'currency', v_cur, 'tax_rate_id', v_tax.id, 'tax_label', v_tax.label,
    'lines', v_lines, 'subtotal', v_sub, 'tax_total', v_taxsum, 'total', v_sub + v_taxsum);
end $$;

-- Create a confirmed booking with its fare lines and one trip.
create function public.create_booking(
  p_org uuid, p_booker uuid, p_passenger_name text, p_passenger_phone text,
  p_service text, p_class uuid, p_pickup_at timestamptz, p_pickup_address text,
  p_dropoff_address text default null, p_distance numeric default 0, p_hours numeric default 0
) returns uuid
language plpgsql as $$
declare
  v_quote jsonb;
  v_booking uuid;
  v_tax uuid;
  l jsonb;
begin
  v_quote := public.quote_price(p_org, p_class, p_service, p_distance, p_hours);
  v_tax := (v_quote->>'tax_rate_id')::uuid;

  insert into bookings (org_id, booker_id, passenger_name, passenger_phone, service_type,
                        class_id, status, currency)
  values (p_org, p_booker, p_passenger_name, p_passenger_phone, p_service,
          p_class, 'confirmed', v_quote->>'currency')
  returning id into v_booking;

  for l in select * from jsonb_array_elements(v_quote->'lines') loop
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (p_org, v_booking, l->>'kind', l->>'description',
            (l->>'amount')::numeric, v_tax, (l->>'tax_amount')::numeric);
  end loop;

  insert into trips (org_id, booking_id, pickup_at, pickup_address, dropoff_address, distance, duration_hours)
  values (p_org, v_booking, p_pickup_at, p_pickup_address, p_dropoff_address,
          nullif(p_distance, 0), nullif(p_hours, 0));

  return v_booking;
end $$;

-- Assign a driver and vehicle to a trip.
create function public.assign_trip(p_trip uuid, p_driver uuid, p_vehicle uuid default null) returns void
language plpgsql as $$
declare v_org uuid;
begin
  update trips set driver_id = p_driver, vehicle_id = p_vehicle, status = 'assigned'
   where id = p_trip and status in ('unassigned','offered','assigned')
   returning org_id into v_org;
  if v_org is null then raise exception 'trip not found or not assignable'; end if;

  insert into trip_events (org_id, trip_id, status, actor_id) values (v_org, p_trip, 'assigned', auth.uid());
end $$;

-- Move a trip along its status flow. Staff or the assigned driver only.
create function public.update_trip_status(
  p_trip uuid, p_status text, p_lat numeric default null, p_lng numeric default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  t trips;
  v_staff boolean;
  v_driver boolean;
  v_ok boolean;
begin
  select * into t from trips where id = p_trip for update;
  if not found then raise exception 'trip not found'; end if;

  v_staff  := app.is_staff(t.org_id);
  v_driver := exists (select 1 from drivers d where d.id = t.driver_id and d.user_id = auth.uid());
  if not (v_staff or v_driver) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status = 'cancelled' and not v_staff then
    raise exception 'only staff can cancel' using errcode = '42501';
  end if;

  v_ok := case t.status
    when 'unassigned' then p_status = 'cancelled'
    when 'offered'    then p_status = 'cancelled'
    when 'assigned'   then p_status in ('en_route','cancelled')
    when 'en_route'   then p_status in ('arrived','cancelled')
    when 'arrived'    then p_status in ('on_board','no_show','cancelled')
    when 'on_board'   then p_status = 'completed'
    else false end;
  if not v_ok then
    raise exception 'cannot move trip from % to %', t.status, p_status;
  end if;

  update trips set status = p_status where id = p_trip;
  insert into trip_events (org_id, trip_id, status, actor_id, lat, lng)
  values (t.org_id, p_trip, p_status, auth.uid(), p_lat, p_lng);

  if p_status = 'en_route' then
    update bookings set status = 'in_progress' where id = t.booking_id and status = 'confirmed';
  elsif p_status in ('completed','no_show') then
    update bookings set status = 'completed' where id = t.booking_id;
  elsif p_status = 'cancelled' then
    update bookings set status = 'cancelled' where id = t.booking_id;
  end if;
end $$;

-- Public directory of operators that opted into the network (no private columns).
create function public.network_directory() returns table (id uuid, name text, slug text, country text)
language sql stable security definer set search_path = public as $$
  select id, name, slug, country from orgs where listed_in_network order by name;
$$;

-- Quote for the public booking portal (no sign-in), keyed by operator slug.
create function public.public_quote(
  p_org_slug text, p_class uuid, p_service text, p_distance numeric default 0, p_hours numeric default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select id into v_org from orgs where slug = p_org_slug;
  if v_org is null then raise exception 'unknown operator'; end if;
  return public.quote_price(v_org, p_class, p_service, p_distance, p_hours);
end $$;

-- ---------------------------------------------------------------
-- Margin per trip. Staff only, because trip_costs is staff only.
-- Revenue is the booking subtotal (tax excluded), split across its trips.
-- ---------------------------------------------------------------
create view trip_margin with (security_invoker = true) as
select
  t.id as trip_id,
  t.org_id,
  t.booking_id,
  b.currency,
  round(b.subtotal / count(*) over (partition by t.booking_id), 2) as revenue,
  c.driver_pay,
  c.partner_cost,
  round(b.subtotal / count(*) over (partition by t.booking_id), 2) - c.driver_pay - c.partner_cost as margin
from trips t
join bookings b on b.id = t.booking_id
join trip_costs c on c.trip_id = t.id;

-- ---------------------------------------------------------------
-- Grants (Supabase roles). RLS decides what rows each role sees.
-- ---------------------------------------------------------------
grant usage on schema app to anon, authenticated;
grant select on plans, currencies, locales, tax_presets to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on function public.create_operator(text,text,text,text,text,text,text,boolean,text) to authenticated;
grant execute on function public.quote_price(uuid,uuid,text,numeric,numeric,uuid) to authenticated;
grant execute on function public.create_booking(uuid,uuid,text,text,text,uuid,timestamptz,text,text,numeric,numeric) to authenticated;
grant execute on function public.assign_trip(uuid,uuid,uuid) to authenticated;
grant execute on function public.update_trip_status(uuid,text,numeric,numeric) to authenticated;
grant execute on function public.network_directory() to anon, authenticated;
grant execute on function public.public_quote(text,uuid,text,numeric,numeric) to anon, authenticated;
