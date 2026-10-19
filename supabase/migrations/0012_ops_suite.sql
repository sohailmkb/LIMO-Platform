-- 0012_ops_suite: Phase 9, closing the Moovs gap on operations and money.
--  1. Pricing rules: zones with flat zone-to-zone rates, time and date rules, airport fee,
--     cancellation and no-show fees, charges added after the trip (wait, tolls, parking).
--  2. Vehicle showcase: descriptions, amenities and photos per class.
--  3. Customer records: tags, VIP, preferences, private notes on customers and bookings.
--  4. Corporate billing: invoices per client company, payments, ageing.
--  5. Driver payroll: pay runs with statements.
--  6. Recurring bookings.
--  7. Availability: driver shifts and time off, vehicles out of service, conflict check.
--  8. Compliance: driver and vehicle documents with expiry alerts.
--  9. Ratings and reviews.
-- 10. Customer notifications: templates and an outbox filled automatically (sending comes later).
-- 11. Booking terms customers accept.

-- ---------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------
create function app.km_between(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric) returns numeric
language sql immutable as $$
  select (6371 * 2 * asin(sqrt(
    power(sin(radians((lat2 - lat1) / 2)), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians((lng2 - lng1) / 2)), 2))))::numeric;
$$;
grant execute on function app.km_between(numeric, numeric, numeric, numeric) to anon, authenticated;

-- ---------------------------------------------------------------
-- 1. Pricing rules
-- ---------------------------------------------------------------
create table zones (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  kind        text not null default 'area' check (kind in ('area', 'airport')),
  lat         numeric(9,6) not null check (lat between -90 and 90),
  lng         numeric(9,6) not null check (lng between -180 and 180),
  radius_km   numeric(7,2) not null check (radius_km > 0 and radius_km <= 300),
  unique (org_id, name)
);

create table zone_rates (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  class_id        uuid not null references vehicle_classes(id) on delete cascade,
  from_zone       uuid not null references zones(id) on delete cascade,
  to_zone         uuid not null references zones(id) on delete cascade,
  amount          numeric(12,2) not null check (amount >= 0),
  both_directions boolean not null default true,
  unique (org_id, class_id, from_zone, to_zone)
);

create table price_rules (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  days        integer[] check (days <@ array[0,1,2,3,4,5,6]),    -- 0 Sunday ... 6 Saturday; null = every day
  start_time  time,                                              -- local pickup time window; wraps past midnight
  end_time    time,
  date_from   date,                                              -- holidays and events
  date_to     date,
  adjust_type text not null check (adjust_type in ('percent', 'fixed')),
  amount      numeric(12,2) not null,
  active      boolean not null default true,
  check ((start_time is null) = (end_time is null)),
  check (date_to is null or date_from is null or date_to >= date_from)
);

alter table orgs
  add column airport_fee numeric(12,2) not null default 0 check (airport_fee >= 0),
  add column wait_per_minute numeric(12,2) not null default 0 check (wait_per_minute >= 0),
  add column cancel_free_hours integer not null default 24 check (cancel_free_hours between 0 and 720),
  add column cancel_fee_percent numeric(5,2) not null default 0 check (cancel_fee_percent between 0 and 100),
  add column no_show_fee_percent numeric(5,2) not null default 100 check (no_show_fee_percent between 0 and 100),
  add column terms_text text check (length(terms_text) <= 20000),
  add column terms_version integer not null default 1,
  add column require_terms boolean not null default false;

alter table zones       enable row level security;
alter table zone_rates  enable row level security;
alter table price_rules enable row level security;
create policy staff_all on zones       for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on zone_rates  for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy staff_all on price_rules for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));

-- Which flat zone rate applies to a one-way trip, if any. Smallest matching zones win.
create function app.zone_fare(p_org uuid, p_class uuid, plat numeric, plng numeric, dlat numeric, dlng numeric)
returns table (amount numeric, from_name text, to_name text)
language sql stable security definer set search_path = public as $$
  select zr.amount, fz.name, tz.name
  from zone_rates zr join zones fz on fz.id = zr.from_zone join zones tz on tz.id = zr.to_zone
  where zr.org_id = p_org and zr.class_id = p_class
    and plat is not null and dlat is not null
    and ((app.km_between(fz.lat, fz.lng, plat, plng) <= fz.radius_km and app.km_between(tz.lat, tz.lng, dlat, dlng) <= tz.radius_km)
      or (zr.both_directions and app.km_between(fz.lat, fz.lng, dlat, dlng) <= fz.radius_km
          and app.km_between(tz.lat, tz.lng, plat, plng) <= tz.radius_km))
  order by fz.radius_km + tz.radius_km, zr.amount
  limit 1;
$$;

create function app.in_airport_zone(p_org uuid, plat numeric, plng numeric) returns boolean
language sql stable security definer set search_path = public as $$
  select plat is not null and exists (select 1 from zones z where z.org_id = p_org and z.kind = 'airport'
                                      and app.km_between(z.lat, z.lng, plat, plng) <= z.radius_km);
$$;

-- price_trip, extended. Same input as 0010 plus pickup_at, pickup_lat/lng, dropoff_lat/lng,
-- pickup_airport, dropoff_airport. Lines carry a code: fare, return_fare, stops, surcharge, rule, airport,
-- extra, promo, tip.
create or replace function public.price_trip(p_org uuid, p jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_org orgs; v_card rate_cards; v_tax tax_rates;
  v_service text := coalesce(p->>'service', 'one_way');
  v_class uuid := (p->>'class_id')::uuid;
  v_dist numeric := greatest(coalesce((p->>'distance')::numeric, 0), 0);
  v_hours numeric := greatest(coalesce((p->>'hours')::numeric, 0), 0);
  v_round boolean := coalesce((p->>'round_trip')::boolean, false) and coalesce(p->>'service', 'one_way') = 'one_way';
  v_stops integer := least(greatest(coalesce((p->>'stops')::integer, 0), 0), 10);
  v_tip numeric := least(greatest(coalesce((p->>'tip_percent')::numeric, 0), 0), 50);
  v_code text := nullif(upper(trim(coalesce(p->>'promo_code', ''))), '');
  v_plat numeric := nullif(p->>'pickup_lat', '')::numeric;  v_plng numeric := nullif(p->>'pickup_lng', '')::numeric;
  v_dlat numeric := nullif(p->>'dropoff_lat', '')::numeric; v_dlng numeric := nullif(p->>'dropoff_lng', '')::numeric;
  v_pickup timestamptz := nullif(p->>'pickup_at', '')::timestamptz;
  v_local timestamp; v_leg numeric(12,2); v_fares numeric(12,2) := 0; v_base numeric(12,2);
  v_desc text; v_zone_amount numeric; v_zone_from text; v_zone_to text;
  v_lines jsonb := '[]'::jsonb; v_sub numeric(12,2) := 0; v_taxsum numeric(12,2) := 0;
  v_amt numeric(12,2); v_t numeric(12,2); v_legs integer;
  s record; x record; r record; e jsonb; v_qty integer; pc promo_codes; v_promo jsonb := null;
begin
  if v_service not in ('one_way', 'hourly') then raise exception 'service must be one_way or hourly'; end if;
  select * into v_org from orgs where id = p_org;
  if v_org.id is null then raise exception 'unknown operator'; end if;
  select * into v_card from rate_cards
   where org_id = p_org and class_id = v_class and service_type = v_service and currency = v_org.default_currency;
  if not found then raise exception 'no rate card for this vehicle class and service'; end if;
  select * into v_tax from tax_rates where org_id = p_org and is_default;
  if v_tax.id is null then raise exception 'no tax rate configured'; end if;
  v_legs := case when v_round then 2 else 1 end;

  v_leg := greatest(v_card.minimum_amount, round(v_card.base_amount
             + case when v_service = 'one_way' then v_card.per_distance * v_dist else 0 end
             + case when v_service = 'hourly' then v_card.per_hour * greatest(v_hours, v_card.min_hours) else 0 end, 2));
  v_desc := case when v_service = 'hourly' then 'Hourly fare' else 'Fare' end;

  if v_service = 'one_way' then
    select z.amount, z.from_name, z.to_name into v_zone_amount, v_zone_from, v_zone_to
      from app.zone_fare(p_org, v_class, v_plat, v_plng, v_dlat, v_dlng) z;
    if v_zone_amount is not null then
      v_leg := round(v_zone_amount, 2);
      v_desc := format('Flat rate %s to %s', v_zone_from, v_zone_to);
    end if;
  end if;

  v_t := round(v_leg * v_tax.rate, 2);
  v_lines := v_lines || jsonb_build_object('kind', 'fare', 'code', 'fare', 'description', v_desc, 'amount', v_leg, 'tax_amount', v_t);
  v_sub := v_sub + v_leg; v_taxsum := v_taxsum + v_t; v_fares := v_leg;
  if v_round then
    v_lines := v_lines || jsonb_build_object('kind', 'fare', 'code', 'return_fare', 'description', 'Return fare', 'amount', v_leg, 'tax_amount', v_t);
    v_sub := v_sub + v_leg; v_taxsum := v_taxsum + v_t; v_fares := v_fares + v_leg;
  end if;

  if v_stops > 0 and v_service = 'one_way' and v_card.per_stop > 0 then
    v_amt := round(v_card.per_stop * v_stops, 2); v_t := round(v_amt * v_tax.rate, 2);
    v_lines := v_lines || jsonb_build_object('kind', 'surcharge', 'code', 'stops',
                 'description', format('Extra stops (%s)', v_stops), 'amount', v_amt, 'tax_amount', v_t);
    v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_t;
  end if;

  for s in select * from surcharges where org_id = p_org and active order by name loop
    v_amt := case s.amount_type when 'fixed' then round(s.amount, 2) else round(v_fares * s.amount, 2) end;
    v_t := round(v_amt * v_tax.rate, 2);
    v_lines := v_lines || jsonb_build_object('kind', 'surcharge', 'code', 'surcharge', 'description', s.name, 'amount', v_amt, 'tax_amount', v_t);
    v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_t;
  end loop;

  -- Time and date rules use the pickup time in the operator's timezone.
  if v_pickup is not null then
    v_local := v_pickup at time zone v_org.timezone;
    for r in select * from price_rules where org_id = p_org and active order by name loop
      if (r.days is null or extract(dow from v_local)::integer = any (r.days))
         and (r.date_from is null or v_local::date >= r.date_from)
         and (r.date_to is null or v_local::date <= r.date_to)
         and (r.start_time is null
              or (r.start_time <= r.end_time and v_local::time >= r.start_time and v_local::time < r.end_time)
              or (r.start_time > r.end_time and (v_local::time >= r.start_time or v_local::time < r.end_time))) then
        v_amt := case r.adjust_type when 'fixed' then round(r.amount, 2) else round(v_fares * r.amount / 100, 2) end;
        v_t := round(v_amt * v_tax.rate, 2);
        v_lines := v_lines || jsonb_build_object('kind', 'surcharge', 'code', 'rule', 'description', r.name, 'amount', v_amt, 'tax_amount', v_t);
        v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_t;
      end if;
    end loop;
  end if;

  if v_org.airport_fee > 0 and (coalesce((p->>'pickup_airport')::boolean, false) or coalesce((p->>'dropoff_airport')::boolean, false)
      or app.in_airport_zone(p_org, v_plat, v_plng) or app.in_airport_zone(p_org, v_dlat, v_dlng)) then
    v_amt := round(v_org.airport_fee * v_legs, 2); v_t := round(v_amt * v_tax.rate, 2);
    v_lines := v_lines || jsonb_build_object('kind', 'surcharge', 'code', 'airport', 'description', 'Airport fee', 'amount', v_amt, 'tax_amount', v_t);
    v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_t;
  end if;
  v_base := v_sub;

  for e in select * from jsonb_array_elements(coalesce(p->'extras', '[]'::jsonb)) loop
    select * into x from extras where id = (e->>'id')::uuid and org_id = p_org and active;
    if not found then raise exception 'unknown extra'; end if;
    v_qty := least(greatest(coalesce((e->>'qty')::integer, 1), 1), x.max_qty);
    v_amt := round(x.price * v_qty, 2);
    v_t := case when x.taxable then round(v_amt * v_tax.rate, 2) else 0 end;
    v_lines := v_lines || jsonb_build_object('kind', 'extra', 'code', 'extra', 'extra_id', x.id,
                 'description', case when v_qty > 1 then format('%s x%s', x.name, v_qty) else x.name end,
                 'amount', v_amt, 'tax_amount', v_t, 'tax_rate', x.taxable);
    v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_t;
  end loop;

  if v_code is not null then
    select * into pc from promo_codes where org_id = p_org and upper(code) = v_code;
    v_promo := jsonb_build_object('code', v_code, 'applied', false, 'reason',
      case
        when pc.id is null or not pc.active then 'invalid'
        when pc.starts_at is not null and now() < pc.starts_at then 'not_started'
        when pc.ends_at is not null and now() > pc.ends_at then 'expired'
        when pc.max_uses is not null and pc.used_count >= pc.max_uses then 'used_up'
        else null end);
    if v_promo->>'reason' is null then
      v_amt := least(v_base, case pc.kind when 'percent' then round(v_base * least(pc.value, 100) / 100, 2) else round(pc.value, 2) end);
      v_t := round(-v_amt * v_tax.rate, 2);
      v_lines := v_lines || jsonb_build_object('kind', 'discount', 'code', 'promo', 'description', format('Promo %s', pc.code), 'amount', -v_amt, 'tax_amount', v_t);
      v_sub := v_sub - v_amt; v_taxsum := v_taxsum + v_t;
      v_promo := jsonb_build_object('code', pc.code, 'applied', true, 'reason', null, 'amount', v_amt);
    end if;
  end if;

  if v_tip > 0 then
    v_amt := round(v_fares * v_tip / 100, 2);
    v_lines := v_lines || jsonb_build_object('kind', 'tip', 'code', 'tip',
                 'description', format('Gratuity (%s%%)', trim(to_char(v_tip, 'FM990.##'))), 'amount', v_amt, 'tax_amount', 0);
    v_sub := v_sub + v_amt;
  end if;

  return jsonb_build_object('currency', v_org.default_currency, 'tax_rate_id', v_tax.id, 'tax_label', v_tax.label,
    'lines', v_lines, 'subtotal', v_sub, 'tax_total', v_taxsum, 'total', v_sub + v_taxsum, 'promo', v_promo,
    'min_hours', case when v_service = 'hourly' then v_card.min_hours end,
    'zone', case when v_zone_amount is not null then jsonb_build_object('from', v_zone_from, 'to', v_zone_to) end);
end $$;

-- Charges added after the trip: waiting time, tolls, parking, overtime, other. Staff and accountants.
-- p_items: [{kind: wait|toll|parking|overtime|other, description, amount, minutes, taxable}]
create function public.add_trip_charges(p_booking uuid, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings; o orgs; it jsonb; v_amt numeric(12,2); v_taxable boolean; v_tax tax_rates; v_desc text; v_kind text;
begin
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'booking not found'; end if;
  if not app.has_role(b.org_id, array['owner','admin','dispatcher','accountant']) then raise exception 'not allowed' using errcode = '42501'; end if;
  if b.status = 'cancelled' then raise exception 'this booking is cancelled'; end if;
  select * into o from orgs where id = b.org_id;
  select * into v_tax from tax_rates where org_id = b.org_id and is_default;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_kind := coalesce(it->>'kind', 'other');
    if v_kind not in ('wait','toll','parking','overtime','other') then raise exception 'unknown charge type %', v_kind; end if;
    v_amt := coalesce(nullif(it->>'amount', '')::numeric,
                      case when v_kind = 'wait' then round(coalesce((it->>'minutes')::numeric, 0) * o.wait_per_minute, 2) end);
    if v_amt is null or v_amt <= 0 then raise exception 'each charge needs an amount above zero'; end if;
    v_taxable := coalesce((it->>'taxable')::boolean, v_kind not in ('toll','parking'));
    v_desc := coalesce(nullif(trim(coalesce(it->>'description', '')), ''),
                case v_kind when 'wait' then format('Waiting time (%s min)', coalesce(it->>'minutes', '?'))
                            when 'toll' then 'Tolls' when 'parking' then 'Parking' when 'overtime' then 'Overtime' else 'Additional charge' end);
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (b.org_id, b.id, 'surcharge', left(v_desc, 120), v_amt,
            case when v_taxable then v_tax.id end, case when v_taxable then round(v_amt * v_tax.rate, 2) else 0 end);
  end loop;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (b.org_id, auth.uid(), 'add_charges', 'booking', b.id, jsonb_build_object('items', p_items));
  return (select jsonb_build_object('total', total, 'paid', paid_amount) from bookings where id = b.id);
end $$;

-- What cancelling now would cost the customer under the operator's policy.
create function public.cancellation_terms(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b bookings; o orgs; v_pickup timestamptz; v_fares numeric;
begin
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'booking not found'; end if;
  if not app.is_member(b.org_id) and not app.sees_booking(b.id) then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into o from orgs where id = b.org_id;
  select min(pickup_at) into v_pickup from trips where booking_id = b.id;
  select coalesce(sum(amount), 0) into v_fares from booking_lines where booking_id = b.id and kind in ('fare','surcharge','discount');
  return jsonb_build_object(
    'free_until', v_pickup - make_interval(hours => o.cancel_free_hours),
    'late', now() > v_pickup - make_interval(hours => o.cancel_free_hours),
    'late_fee', round(v_fares * o.cancel_fee_percent / 100, 2),
    'no_show_fee', round(v_fares * o.no_show_fee_percent / 100, 2),
    'currency', b.currency);
end $$;

-- Charge a late-cancellation or no-show fee: the bill becomes the fee alone.
create function public.charge_cancellation(p_booking uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings; o orgs; v_fares numeric; v_fee numeric(12,2); v_tax tax_rates; v_old numeric;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'booking not found'; end if;
  if not app.is_staff(b.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_kind = 'late_cancel' and b.status <> 'cancelled' then raise exception 'cancel the booking first'; end if;
  if p_kind = 'no_show' and not exists (select 1 from trips where booking_id = b.id and status = 'no_show') then
    raise exception 'mark the trip as a no-show first';
  end if;
  if p_kind not in ('late_cancel','no_show') then raise exception 'kind must be late_cancel or no_show'; end if;
  select * into o from orgs where id = b.org_id;
  select * into v_tax from tax_rates where org_id = b.org_id and is_default;
  select coalesce(sum(amount), 0) into v_fares from booking_lines where booking_id = b.id and kind in ('fare','surcharge','discount');
  v_fee := round(v_fares * case p_kind when 'late_cancel' then o.cancel_fee_percent else o.no_show_fee_percent end / 100, 2);
  v_old := b.total;
  delete from booking_lines where booking_id = b.id;
  if v_fee > 0 then
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (b.org_id, b.id, 'surcharge', case p_kind when 'late_cancel' then 'Late cancellation fee' else 'No-show fee' end,
            v_fee, v_tax.id, round(v_fee * v_tax.rate, 2));
  end if;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (b.org_id, auth.uid(), 'charge_' || p_kind, 'booking', b.id, jsonb_build_object('previous_total', v_old, 'fee', v_fee));
  return (select jsonb_build_object('total', total, 'paid', paid_amount, 'currency', currency) from bookings where id = b.id);
end $$;

-- ---------------------------------------------------------------
-- 2. Vehicle showcase
-- ---------------------------------------------------------------
alter table vehicle_classes
  add column description text check (length(description) <= 600),
  add column amenities text[] not null default '{}',
  add column photo_urls text[] not null default '{}' check (cardinality(photo_urls) <= 6);
alter table vehicles
  add column make text, add column model text, add column year integer check (year between 1980 and 2100),
  add column color text, add column photo_url text;

-- ---------------------------------------------------------------
-- 3. Customer records
-- ---------------------------------------------------------------
alter table contacts
  add column tags text[] not null default '{}',
  add column vip boolean not null default false,
  add column preferences text check (length(preferences) <= 1000),
  add column preferred_class_id uuid references vehicle_classes(id) on delete set null,
  add column preferred_driver_id uuid references drivers(id) on delete set null;

create table notes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  contact_id  uuid references contacts(id) on delete cascade,
  booking_id  uuid references bookings(id) on delete cascade,
  author_id   uuid default auth.uid(),
  body        text not null check (length(body) between 1 and 4000),
  created_at  timestamptz not null default now(),
  check ((contact_id is null) <> (booking_id is null))
);
alter table notes enable row level security;
-- Private to staff and accountants. Never visible to customers, clients or drivers.
create policy staff_all on notes for all using (app.has_role(org_id, array['owner','admin','dispatcher','accountant']))
  with check (app.has_role(org_id, array['owner','admin','dispatcher','accountant']));

-- ---------------------------------------------------------------
-- 4. Corporate billing
-- ---------------------------------------------------------------
create table invoices (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  number       bigint generated always as identity,
  account_id   uuid not null references accounts(id) on delete restrict,
  status       text not null default 'draft' check (status in ('draft','sent','paid','void')),
  period_start date not null,
  period_end   date not null,
  issued_on    date not null default current_date,
  due_on       date not null,
  currency     text not null references currencies(code),
  subtotal     numeric(12,2) not null default 0,
  tax_total    numeric(12,2) not null default 0,
  total        numeric(12,2) not null default 0,
  paid_amount  numeric(12,2) not null default 0,
  notes        text check (length(notes) <= 2000),
  created_at   timestamptz not null default now()
);
create table invoice_items (
  invoice_id uuid not null references invoices(id) on delete cascade,
  booking_id uuid not null references bookings(id) on delete restrict,
  org_id     uuid not null references orgs(id) on delete cascade,
  primary key (invoice_id, booking_id)
);
alter table invoices enable row level security;
alter table invoice_items enable row level security;
create policy finance_all on invoices for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));
create policy staff_read  on invoices for select using (app.is_staff(org_id));
create policy client_read on invoices for select using (app.is_account_admin(account_id) and status <> 'draft');
create policy finance_all on invoice_items for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));
create policy staff_read  on invoice_items for select using (app.is_staff(org_id));
create policy client_read on invoice_items for select using (
  exists (select 1 from invoices i where i.id = invoice_id and app.is_account_admin(i.account_id) and i.status <> 'draft'));

alter table accounts add column payment_terms_days integer not null default 30 check (payment_terms_days between 0 and 120);

-- Bookings on the account in the period (by first pickup, operator timezone), not cancelled unless a fee
-- remains, and not already on a live invoice. Returns the new invoice id, or null when nothing to bill.
create function public.create_account_invoice(p_account uuid, p_from date, p_to date) returns uuid
language plpgsql security definer set search_path = public as $$
declare a accounts; o orgs; v_inv uuid;
begin
  select * into a from accounts where id = p_account;
  if not found then raise exception 'client company not found'; end if;
  if not app.is_finance(a.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_to < p_from then raise exception 'the period ends before it starts'; end if;
  select * into o from orgs where id = a.org_id;
  create temp table if not exists _inv_bookings (id uuid) on commit drop;
  delete from _inv_bookings;
  insert into _inv_bookings
  select b.id from bookings b
   where b.account_id = p_account and b.total > 0
     and (b.status in ('confirmed','in_progress','completed') or (b.status = 'cancelled' and b.total > 0))
     and ((select min(pickup_at) from trips t where t.booking_id = b.id) at time zone o.timezone)::date between p_from and p_to
     and not exists (select 1 from invoice_items ii join invoices i on i.id = ii.invoice_id
                     where ii.booking_id = b.id and i.status <> 'void');
  if not exists (select 1 from _inv_bookings) then return null; end if;
  insert into invoices (org_id, account_id, period_start, period_end, due_on, currency)
  values (a.org_id, a.id, p_from, p_to, current_date + a.payment_terms_days, o.default_currency) returning id into v_inv;
  insert into invoice_items (invoice_id, booking_id, org_id) select v_inv, id, a.org_id from _inv_bookings;
  perform app.recalc_invoice(v_inv);
  return v_inv;
end $$;

create function app.recalc_invoice(p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update invoices i set
    subtotal = s.sub, tax_total = s.tax, total = s.tot, paid_amount = s.paid,
    status = case when i.status in ('sent','paid') and s.tot > 0 and s.paid >= s.tot then 'paid'
                  when i.status = 'paid' and s.paid < s.tot then 'sent' else i.status end
  from (select coalesce(sum(b.subtotal), 0) sub, coalesce(sum(b.tax_total), 0) tax,
               coalesce(sum(b.total), 0) tot, coalesce(sum(b.paid_amount), 0) paid
        from invoice_items ii join bookings b on b.id = ii.booking_id where ii.invoice_id = p_invoice) s
  where i.id = p_invoice;
end $$;

-- Mark sent or void, or reopen a draft. Paid follows payments automatically.
create function public.set_invoice_status(p_invoice uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare i invoices;
begin
  select * into i from invoices where id = p_invoice;
  if not found then raise exception 'invoice not found'; end if;
  if not app.is_finance(i.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_status not in ('draft','sent','void') then raise exception 'status must be draft, sent or void'; end if;
  if i.status = 'void' then raise exception 'a void invoice cannot change'; end if;
  if p_status = 'void' and i.paid_amount > 0 then raise exception 'an invoice with payments cannot be voided'; end if;
  update invoices set status = p_status, issued_on = case when p_status = 'sent' then current_date else issued_on end
   where id = p_invoice;
  perform app.recalc_invoice(p_invoice);
end $$;

-- Record a payment against an invoice; spread over its bookings oldest first.
create function public.record_invoice_payment(p_invoice uuid, p_amount numeric, p_method text default 'bank_transfer', p_reference text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare i invoices; r record; v_left numeric(12,2) := round(p_amount, 2); v_take numeric(12,2);
begin
  select * into i from invoices where id = p_invoice for update;
  if not found then raise exception 'invoice not found'; end if;
  if not app.is_finance(i.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if i.status not in ('sent','paid') then raise exception 'send the invoice before recording payments'; end if;
  if v_left <= 0 then raise exception 'amount must be above zero'; end if;
  if v_left > i.total - i.paid_amount then raise exception 'amount is more than the balance due'; end if;
  for r in select b.id, b.total - b.paid_amount as due from invoice_items ii join bookings b on b.id = ii.booking_id
           where ii.invoice_id = p_invoice and b.total > b.paid_amount order by b.number loop
    exit when v_left <= 0;
    v_take := least(v_left, r.due);
    insert into payments (org_id, booking_id, provider, provider_ref, amount, currency, status)
    values (i.org_id, r.id, coalesce(nullif(p_method, ''), 'bank_transfer'),
            nullif(trim(coalesce(p_reference, '')), '') || case when v_take < p_amount then '#' || substr(gen_random_uuid()::text, 1, 6) else '' end,
            v_take, i.currency, 'succeeded');
    v_left := v_left - v_take;
  end loop;
  perform app.recalc_invoice(p_invoice);
  return (select jsonb_build_object('paid', paid_amount, 'total', total, 'status', status) from invoices where id = p_invoice);
end $$;

-- Unpaid invoice balances per client company by age.
create function public.account_ageing(p_org uuid) returns table (
  account_id uuid, account_name text, current_due numeric, days_1_30 numeric, days_31_60 numeric, days_61_90 numeric, days_over_90 numeric, total_due numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_finance(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select a.id, a.name,
    coalesce(sum(i.total - i.paid_amount) filter (where current_date <= i.due_on), 0),
    coalesce(sum(i.total - i.paid_amount) filter (where current_date - i.due_on between 1 and 30), 0),
    coalesce(sum(i.total - i.paid_amount) filter (where current_date - i.due_on between 31 and 60), 0),
    coalesce(sum(i.total - i.paid_amount) filter (where current_date - i.due_on between 61 and 90), 0),
    coalesce(sum(i.total - i.paid_amount) filter (where current_date - i.due_on > 90), 0),
    coalesce(sum(i.total - i.paid_amount), 0)
  from accounts a join invoices i on i.account_id = a.id and i.status = 'sent'
  where a.org_id = p_org
  group by a.id, a.name
  order by 8 desc;
end $$;

-- ---------------------------------------------------------------
-- 5. Driver payroll
-- ---------------------------------------------------------------
create table pay_runs (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  period_start date not null,
  period_end   date not null,
  status       text not null default 'draft' check (status in ('draft','paid')),
  currency     text not null references currencies(code),
  created_at   timestamptz not null default now(),
  paid_at      timestamptz
);
create table pay_run_lines (
  id          uuid primary key default gen_random_uuid(),
  pay_run_id  uuid not null references pay_runs(id) on delete cascade,
  org_id      uuid not null references orgs(id) on delete cascade,
  driver_id   uuid not null references drivers(id) on delete restrict,
  trips       integer not null default 0,
  driver_pay  numeric(12,2) not null default 0,
  tips        numeric(12,2) not null default 0,
  adjustment  numeric(12,2) not null default 0,
  adjustment_note text check (length(adjustment_note) <= 300),
  total       numeric(12,2) generated always as (driver_pay + tips + adjustment) stored,
  unique (pay_run_id, driver_id)
);
alter table trip_costs add column pay_run_id uuid references pay_runs(id) on delete set null;
alter table pay_runs enable row level security;
alter table pay_run_lines enable row level security;
create policy finance_all on pay_runs for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));
create policy finance_all on pay_run_lines for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));
create policy driver_own on pay_run_lines for select using (
  exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid()));

-- Completed trips in the period with driver pay not yet in another run. Tips are split across legs.
create function public.create_pay_run(p_org uuid, p_from date, p_to date) returns uuid
language plpgsql security definer set search_path = public as $$
declare o orgs; v_run uuid;
begin
  if not app.is_finance(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_to < p_from then raise exception 'the period ends before it starts'; end if;
  select * into o from orgs where id = p_org;
  insert into pay_runs (org_id, period_start, period_end, currency) values (p_org, p_from, p_to, o.default_currency) returning id into v_run;
  with t as (
    select tr.id trip_id, tr.driver_id, tr.booking_id, coalesce(tc.driver_pay, 0) pay,
           coalesce((select sum(l.amount) from booking_lines l where l.booking_id = tr.booking_id and l.kind = 'tip'), 0)
             / greatest((select count(*) from trips x where x.booking_id = tr.booking_id and x.status <> 'cancelled'), 1) tip
    from trips tr left join trip_costs tc on tc.trip_id = tr.id
    where tr.org_id = p_org and tr.status = 'completed' and tr.driver_id is not null
      and (tr.pickup_at at time zone o.timezone)::date between p_from and p_to
      and (tc.trip_id is null or tc.pay_run_id is null)
  ), ins as (
    insert into trip_costs (trip_id, org_id, driver_pay, pay_run_id)
    select trip_id, p_org, pay, v_run from t
    on conflict (trip_id) do update set pay_run_id = v_run
    returning trip_id
  )
  insert into pay_run_lines (pay_run_id, org_id, driver_id, trips, driver_pay, tips)
  select v_run, p_org, driver_id, count(*), round(sum(pay), 2), round(sum(tip), 2) from t group by driver_id;
  if not exists (select 1 from pay_run_lines where pay_run_id = v_run) then
    delete from pay_runs where id = v_run;
    return null;
  end if;
  return v_run;
end $$;

create function public.set_pay_run_paid(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r pay_runs;
begin
  select * into r from pay_runs where id = p_run;
  if not found then raise exception 'pay run not found'; end if;
  if not app.is_finance(r.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  update pay_runs set status = 'paid', paid_at = now() where id = p_run;
end $$;

-- Delete a draft run and release its trips for the next run.
create function public.delete_pay_run(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r pay_runs;
begin
  select * into r from pay_runs where id = p_run;
  if not found then raise exception 'pay run not found'; end if;
  if not app.is_finance(r.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if r.status = 'paid' then raise exception 'a paid run cannot be deleted'; end if;
  update trip_costs set pay_run_id = null where pay_run_id = p_run;
  delete from pay_runs where id = p_run;
end $$;

-- ---------------------------------------------------------------
-- 6. Recurring bookings
-- ---------------------------------------------------------------
alter table bookings add column series_id uuid;
create index bookings_series_idx on bookings (series_id) where series_id is not null;

-- p as create_booking_v2 (pickup_at gives the first date and the local time).
-- p_rule: {freq: "daily"|"weekly", every: 1..4, days: [0..6] for weekly, until: "YYYY-MM-DD"}. At most 60 bookings.
create function public.create_recurring_bookings(p_org uuid, p_booker uuid, p jsonb, p_rule jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o orgs; v_series uuid := gen_random_uuid(); v_first timestamptz := (p->>'pickup_at')::timestamptz;
  v_local timestamp; v_time time; v_day date; v_until date := (p_rule->>'until')::date;
  v_freq text := coalesce(p_rule->>'freq', 'weekly'); v_every integer := least(greatest(coalesce((p_rule->>'every')::integer, 1), 1), 4);
  v_days integer[]; v_ids uuid[] := '{}'; v_id uuid; v_at timestamptz; v_ret interval; n integer := 0;
begin
  if not app.is_staff(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  if v_first is null or v_until is null then raise exception 'first pickup and end date are required'; end if;
  v_local := v_first at time zone o.timezone; v_time := v_local::time; v_day := v_local::date;
  if v_until < v_day or v_until > v_day + 366 then raise exception 'end date must be within a year of the first pickup'; end if;
  if v_freq not in ('daily','weekly') then raise exception 'repeat must be daily or weekly'; end if;
  v_days := coalesce((select array_agg(x::integer) from jsonb_array_elements_text(p_rule->'days') x), array[extract(dow from v_day)::integer]);
  v_ret := case when nullif(p->>'return_at', '') is not null then (p->>'return_at')::timestamptz - v_first end;
  while v_day <= v_until loop
    if (v_freq = 'daily' and ((v_day - (v_first at time zone o.timezone)::date) % v_every) = 0)
       or (v_freq = 'weekly' and extract(dow from v_day)::integer = any (v_days)
           and (((v_day - (v_first at time zone o.timezone)::date) / 7) % v_every) = 0) then
      n := n + 1;
      if n > 60 then raise exception 'a series can have at most 60 bookings'; end if;
      v_at := (v_day + v_time) at time zone o.timezone;
      v_id := public.create_booking_v2(p_org, p_booker, p || jsonb_build_object('pickup_at', v_at,
                'return_at', case when v_ret is not null then v_at + v_ret end));
      v_ids := v_ids || v_id;
    end if;
    v_day := v_day + 1;
  end loop;
  if n = 0 then raise exception 'these dates produce no bookings'; end if;
  update bookings set series_id = v_series where id = any (v_ids);
  return jsonb_build_object('series_id', v_series, 'count', n, 'booking_ids', to_jsonb(v_ids));
end $$;

-- Cancel the bookings of a series from a date onward (operator timezone). Returns how many were cancelled.
create function public.cancel_series(p_series uuid, p_from date, p_reason text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select b.id, b.org_id from bookings b join orgs o on o.id = b.org_id
           where b.series_id = p_series and b.status in ('quoted','confirmed')
             and ((select min(pickup_at) from trips t where t.booking_id = b.id) at time zone o.timezone)::date >= p_from loop
    if not app.is_staff(r.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
    perform public.cancel_booking(r.id, coalesce(p_reason, 'Series cancelled'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------
-- 7. Availability
-- ---------------------------------------------------------------
create table driver_shifts (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  driver_id  uuid not null references drivers(id) on delete cascade,
  kind       text not null default 'shift' check (kind in ('shift','time_off')),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null check (ends_at > starts_at),
  note       text check (length(note) <= 300)
);
create index driver_shifts_idx on driver_shifts (driver_id, starts_at);
create table vehicle_blocks (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null check (ends_at > starts_at),
  reason     text check (length(reason) <= 300)
);
alter table driver_shifts enable row level security;
alter table vehicle_blocks enable row level security;
create policy staff_all on driver_shifts for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy driver_own on driver_shifts for select using (exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid()));
create policy staff_all on vehicle_blocks for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));

-- ---------------------------------------------------------------
-- 8. Compliance
-- ---------------------------------------------------------------
alter table driver_documents add column number text, add column file_path text, add column notes text;
create table vehicle_documents (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  vehicle_id  uuid not null references vehicles(id) on delete cascade,
  kind        text not null check (length(kind) between 1 and 60),
  number      text,
  expires_on  date not null,
  file_path   text,
  notes       text
);
alter table vehicle_documents enable row level security;
create policy staff_all on vehicle_documents for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));

-- Expired or expiring documents (within p_days), drivers and vehicles together.
create function public.compliance_alerts(p_org uuid, p_days integer default 30) returns table (
  subject text, subject_id uuid, subject_name text, document_id uuid, kind text, expires_on date, days_left integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_staff(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select 'driver'::text, d.id, d.full_name, dd.id, dd.kind, dd.expires_on, (dd.expires_on - current_date)::integer
    from driver_documents dd join drivers d on d.id = dd.driver_id
   where dd.org_id = p_org and d.active and dd.expires_on <= current_date + p_days
  union all
  select 'vehicle'::text, v.id, v.label, vd.id, vd.kind, vd.expires_on, (vd.expires_on - current_date)::integer
    from vehicle_documents vd join vehicles v on v.id = vd.vehicle_id
   where vd.org_id = p_org and v.active and vd.expires_on <= current_date + p_days
  order by 6;
end $$;

-- Everything that argues against an assignment, for the assign dialog.
-- Returns [{level: "block"|"warn", code, message}]; codes: time_off, off_shift, vehicle_blocked,
-- driver_document_expired, vehicle_document_expired.
create function public.assignment_warnings(p_trip uuid, p_driver uuid default null, p_vehicle uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t trips; v_end timestamptz; v_out jsonb := '[]'::jsonb; r record;
begin
  select * into t from trips where id = p_trip;
  if not found then raise exception 'trip not found'; end if;
  if not app.is_staff(t.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  v_end := t.pickup_at + make_interval(mins => (coalesce(t.duration_hours, 3) * 60)::integer);
  if p_driver is not null then
    for r in select * from driver_shifts where driver_id = p_driver and kind = 'time_off'
               and starts_at < v_end and ends_at > t.pickup_at loop
      v_out := v_out || jsonb_build_object('level', 'warn', 'code', 'time_off', 'message', coalesce(r.note, 'Time off'));
    end loop;
    if exists (select 1 from driver_shifts where driver_id = p_driver and kind = 'shift'
                 and starts_at::date between t.pickup_at::date - 1 and t.pickup_at::date + 1)
       and not exists (select 1 from driver_shifts where driver_id = p_driver and kind = 'shift'
                         and starts_at <= t.pickup_at and ends_at >= t.pickup_at) then
      v_out := v_out || jsonb_build_object('level', 'warn', 'code', 'off_shift', 'message', 'Outside the driver''s shift');
    end if;
    for r in select kind from driver_documents where driver_id = p_driver and expires_on < t.pickup_at::date loop
      v_out := v_out || jsonb_build_object('level', 'warn', 'code', 'driver_document_expired', 'message', r.kind);
    end loop;
  end if;
  if p_vehicle is not null then
    for r in select * from vehicle_blocks where vehicle_id = p_vehicle and starts_at < v_end and ends_at > t.pickup_at loop
      v_out := v_out || jsonb_build_object('level', 'warn', 'code', 'vehicle_blocked', 'message', coalesce(r.reason, 'Out of service'));
    end loop;
    for r in select kind from vehicle_documents where vehicle_id = p_vehicle and expires_on < t.pickup_at::date loop
      v_out := v_out || jsonb_build_object('level', 'warn', 'code', 'vehicle_document_expired', 'message', r.kind);
    end loop;
  end if;
  return v_out;
end $$;

-- ---------------------------------------------------------------
-- 9. Ratings
-- ---------------------------------------------------------------
create table trip_ratings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  booking_id  uuid not null unique references bookings(id) on delete cascade,
  rating      integer not null check (rating between 1 and 5),
  comment     text check (length(comment) <= 1000),
  created_at  timestamptz not null default now()
);
alter table trip_ratings enable row level security;
create policy staff_read on trip_ratings for select using (app.is_member(org_id) and app.has_role(org_id, array['owner','admin','dispatcher','accountant']));

-- Customer rates a completed booking once, from the status page.
create function public.public_rate_booking(p_slug text, p_code text, p_rating integer, p_comment text default null) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select bk.* into b from bookings bk join orgs o on o.id = bk.org_id where o.slug = p_slug and bk.public_code = p_code;
  if not found then raise exception 'booking not found'; end if;
  if b.status <> 'completed' then raise exception 'you can rate after the trip is completed'; end if;
  if p_rating not between 1 and 5 then raise exception 'rating must be 1 to 5'; end if;
  insert into trip_ratings (org_id, booking_id, rating, comment)
  values (b.org_id, b.id, p_rating, nullif(trim(coalesce(p_comment, '')), ''))
  on conflict (booking_id) do nothing;
  if not found then raise exception 'this trip has already been rated'; end if;
end $$;

-- Average rating per driver (driver of the outbound leg).
create function public.driver_ratings(p_org uuid) returns table (driver_id uuid, driver_name text, ratings integer, average numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_staff(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select d.id, d.full_name, count(*)::integer, round(avg(r.rating), 2)
  from trip_ratings r
  join trips t on t.booking_id = r.booking_id and t.leg = 'outbound'
  join drivers d on d.id = t.driver_id
  where r.org_id = p_org
  group by d.id, d.full_name
  order by 4 desc;
end $$;

-- ---------------------------------------------------------------
-- 10. Notifications
-- ---------------------------------------------------------------
alter table platform_settings add column app_url text;   -- e.g. https://velvet-ride-reservations.lovable.app

create table notification_templates (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  event     text not null check (event in ('booking_confirmed','quote_sent','driver_assigned','driver_en_route','driver_arrived','trip_completed','booking_cancelled')),
  channel   text not null check (channel in ('email','sms')),
  locale    text not null references locales(code),
  subject   text check (length(subject) <= 200),
  body      text not null check (length(body) between 1 and 4000),
  active    boolean not null default true,
  unique (org_id, event, channel, locale)
);
create table notification_outbox (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  booking_id  uuid references bookings(id) on delete cascade,
  event       text not null,
  channel     text not null,
  to_address  text not null,
  subject     text,
  body        text not null,
  status      text not null default 'queued' check (status in ('queued','sent','failed','skipped')),
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index notification_outbox_queued on notification_outbox (created_at) where status = 'queued';
alter table notification_templates enable row level security;
alter table notification_outbox enable row level security;
create policy staff_all on notification_templates for all using (app.has_role(org_id, array['owner','admin'])) with check (app.has_role(org_id, array['owner','admin']));
create policy staff_read on notification_templates for select using (app.is_staff(org_id));
create policy staff_read on notification_outbox for select using (app.is_staff(org_id));

-- Fill {{placeholders}} for one booking.
create function app.render_template(p_text text, p_booking uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare b bookings; o orgs; t trips; v_driver text; v_vehicle text; v_url text; v_out text := p_text; v_fmt text;
begin
  select * into b from bookings where id = p_booking;
  select * into o from orgs where id = b.org_id;
  select * into t from trips where booking_id = b.id order by leg = 'return', pickup_at limit 1;
  select full_name into v_driver from drivers where id = t.driver_id;
  select trim(coalesce(make, '') || ' ' || coalesce(model, '') || ' ' || coalesce(color, '') || coalesce(' (' || plate || ')', ''))
    into v_vehicle from vehicles where id = t.vehicle_id;
  select app_url into v_url from platform_settings limit 1;
  v_fmt := case when o.clock_24h then 'Dy DD Mon HH24:MI' else 'Dy DD Mon HH12:MI AM' end;
  v_out := replace(v_out, '{{operator_name}}', o.name);
  v_out := replace(v_out, '{{passenger_name}}', coalesce(b.passenger_name, ''));
  v_out := replace(v_out, '{{booking_number}}', b.number::text);
  v_out := replace(v_out, '{{pickup_time}}', coalesce(to_char(t.pickup_at at time zone o.timezone, v_fmt), ''));
  v_out := replace(v_out, '{{pickup_address}}', coalesce(t.pickup_address, ''));
  v_out := replace(v_out, '{{dropoff_address}}', coalesce(t.dropoff_address, ''));
  v_out := replace(v_out, '{{total}}', to_char(b.total, 'FM999G999G990D00') || ' ' || b.currency);
  v_out := replace(v_out, '{{driver_name}}', coalesce(v_driver, ''));
  v_out := replace(v_out, '{{vehicle}}', coalesce(nullif(v_vehicle, ''), ''));
  v_out := replace(v_out, '{{status_link}}', coalesce(rtrim(v_url, '/') || '/book/' || o.slug || '/status/' || b.public_code, ''));
  return v_out;
end $$;

-- Queue the messages for one event on one booking, to the booker (email and/or phone).
create function app.notify(p_booking uuid, p_event text) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; o orgs; c contacts; tpl notification_templates; v_to text;
begin
  select * into b from bookings where id = p_booking;
  if not found then return; end if;
  select * into o from orgs where id = b.org_id;
  select * into c from contacts where id = b.booker_id;
  for tpl in select * from notification_templates where org_id = b.org_id and event = p_event and active and locale = o.default_locale loop
    v_to := case tpl.channel when 'email' then c.email else coalesce(b.passenger_phone, c.phone) end;
    if v_to is null or v_to = '' then continue; end if;
    insert into notification_outbox (org_id, booking_id, event, channel, to_address, subject, body)
    values (b.org_id, b.id, p_event, tpl.channel, v_to,
            app.render_template(tpl.subject, b.id), app.render_template(tpl.body, b.id));
  end loop;
end $$;

create function app.bookings_notify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'confirmed' then perform app.notify(new.id, 'booking_confirmed'); end if;
    if new.status = 'cancelled' then perform app.notify(new.id, 'booking_cancelled'); end if;
  end if;
  if new.quote_sent_at is distinct from old.quote_sent_at and new.quote_sent_at is not null then
    perform app.notify(new.id, 'quote_sent');
  end if;
  return new;
end $$;
create trigger bookings_notify after update on bookings for each row execute function app.bookings_notify();

create function app.trips_notify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.leg = 'outbound' and (select status from bookings where id = new.booking_id) = 'confirmed' then
      perform app.notify(new.booking_id, 'booking_confirmed');
    end if;
    return new;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'assigned' then perform app.notify(new.booking_id, 'driver_assigned'); end if;
    if new.status = 'en_route' then perform app.notify(new.booking_id, 'driver_en_route'); end if;
    if new.status = 'arrived' then perform app.notify(new.booking_id, 'driver_arrived'); end if;
    if new.status = 'completed' and new.leg = 'outbound' then perform app.notify(new.booking_id, 'trip_completed'); end if;
  end if;
  return new;
end $$;
create trigger trips_notify after insert or update of status on trips for each row execute function app.trips_notify();

-- Default templates in English and French. Safe to run again: existing templates are kept.
create function public.install_default_templates(p_org uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not app.has_role(p_org, array['owner','admin']) then raise exception 'not allowed' using errcode = '42501'; end if;
  insert into notification_templates (org_id, event, channel, locale, subject, body)
  select p_org, v.event, v.channel, v.locale, v.subject, v.body from (values
    ('booking_confirmed','email','en','Your ride is confirmed: {{pickup_time}}',
     E'Hello {{passenger_name}},\n\nYour booking #{{booking_number}} with {{operator_name}} is confirmed.\nPickup: {{pickup_time}}\nFrom: {{pickup_address}}\nTo: {{dropoff_address}}\nTotal: {{total}}\n\nDetails and payment: {{status_link}}'),
    ('booking_confirmed','sms','en',null,'{{operator_name}}: booking #{{booking_number}} confirmed for {{pickup_time}}. {{status_link}}'),
    ('quote_sent','email','en','Your quote from {{operator_name}}',
     E'Hello {{passenger_name}},\n\nHere is your quote for {{pickup_time}}: {{total}}.\nReview and accept it here: {{status_link}}'),
    ('driver_assigned','sms','en',null,'{{operator_name}}: {{driver_name}} will drive you on {{pickup_time}}. {{vehicle}}'),
    ('driver_en_route','sms','en',null,'{{operator_name}}: your chauffeur {{driver_name}} is on the way. {{status_link}}'),
    ('driver_arrived','sms','en',null,'{{operator_name}}: your chauffeur has arrived at {{pickup_address}}.'),
    ('trip_completed','email','en','Thank you for riding with {{operator_name}}',
     E'Hello {{passenger_name}},\n\nThank you for travelling with us. Your receipt and a short rating are here: {{status_link}}'),
    ('booking_cancelled','email','en','Booking #{{booking_number}} cancelled',
     E'Hello {{passenger_name}},\n\nYour booking #{{booking_number}} for {{pickup_time}} has been cancelled. Questions? Reply to this email.'),
    ('booking_confirmed','email','fr','Votre course est confirmée : {{pickup_time}}',
     E'Bonjour {{passenger_name}},\n\nVotre réservation n° {{booking_number}} avec {{operator_name}} est confirmée.\nPrise en charge : {{pickup_time}}\nDépart : {{pickup_address}}\nArrivée : {{dropoff_address}}\nTotal : {{total}}\n\nDétails et paiement : {{status_link}}'),
    ('booking_confirmed','sms','fr',null,'{{operator_name}} : réservation n° {{booking_number}} confirmée pour {{pickup_time}}. {{status_link}}'),
    ('quote_sent','email','fr','Votre devis de {{operator_name}}',
     E'Bonjour {{passenger_name}},\n\nVoici votre devis pour {{pickup_time}} : {{total}}.\nConsultez-le et acceptez-le ici : {{status_link}}'),
    ('driver_assigned','sms','fr',null,'{{operator_name}} : {{driver_name}} sera votre chauffeur le {{pickup_time}}. {{vehicle}}'),
    ('driver_en_route','sms','fr',null,'{{operator_name}} : votre chauffeur {{driver_name}} est en route. {{status_link}}'),
    ('driver_arrived','sms','fr',null,'{{operator_name}} : votre chauffeur est arrivé à {{pickup_address}}.'),
    ('trip_completed','email','fr','Merci d''avoir voyagé avec {{operator_name}}',
     E'Bonjour {{passenger_name}},\n\nMerci d''avoir voyagé avec nous. Votre reçu et une courte évaluation : {{status_link}}'),
    ('booking_cancelled','email','fr','Réservation n° {{booking_number}} annulée',
     E'Bonjour {{passenger_name}},\n\nVotre réservation n° {{booking_number}} du {{pickup_time}} a été annulée. Des questions ? Répondez à ce courriel.')
  ) as v(event, channel, locale, subject, body)
  on conflict (org_id, event, channel, locale) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Preview a template against a real booking, without queueing anything.
create function public.preview_template(p_booking uuid, p_text text) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_staff((select org_id from bookings where id = p_booking)) then raise exception 'not allowed' using errcode = '42501'; end if;
  return app.render_template(p_text, p_booking);
end $$;

-- ---------------------------------------------------------------
-- 11. Booking terms
-- ---------------------------------------------------------------
alter table bookings add column terms_version integer, add column terms_accepted_at timestamptz;

create or replace function public.public_create_booking_v2(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orgs; v_contact uuid; v_booking uuid; v_email text := lower(trim(coalesce(p->>'booker_email', '')));
begin
  select * into o from orgs where slug = p_slug and status = 'active' and kind = 'operator';
  if o.id is null then raise exception 'unknown operator'; end if;
  if not exists (select 1 from vehicle_classes where id = (p->>'class_id')::uuid and org_id = o.id) then
    raise exception 'unknown vehicle class';
  end if;
  if (p->>'pickup_at')::timestamptz < now() + interval '30 minutes' then
    raise exception 'pickup must be at least 30 minutes from now';
  end if;
  if coalesce(trim(p->>'booker_name'), '') = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'name and a valid email are required';
  end if;
  if length(p->>'booker_name') > 200 or length(v_email) > 320 or length(coalesce(p->>'pickup_address', '')) > 500
     or length(coalesce(p->>'dropoff_address', '')) > 500 then
    raise exception 'input too long';
  end if;
  if o.require_terms and not coalesce((p->>'accept_terms')::boolean, false) then
    raise exception 'please accept the booking terms';
  end if;

  select id into v_contact from contacts where org_id = o.id and lower(email) = v_email limit 1;
  if v_contact is null then
    insert into contacts (org_id, full_name, email, phone)
    values (o.id, trim(p->>'booker_name'), v_email, nullif(trim(coalesce(p->>'booker_phone', '')), ''))
    returning id into v_contact;
  end if;

  v_booking := app.book(o.id, v_contact,
    p || jsonb_build_object(
      'passenger_name', coalesce(nullif(trim(coalesce(p->>'passenger_name', '')), ''), trim(p->>'booker_name')),
      'passenger_phone', coalesce(nullif(trim(coalesce(p->>'passenger_phone', '')), ''), p->>'booker_phone')),
    'quoted');
  if coalesce((p->>'accept_terms')::boolean, false) then
    update bookings set terms_version = o.terms_version, terms_accepted_at = now() where id = v_booking;
  end if;
  return (select jsonb_build_object('public_code', public_code, 'total', total, 'currency', currency)
          from bookings where id = v_booking);
end $$;

-- ---------------------------------------------------------------
-- Public reads, extended
-- ---------------------------------------------------------------
create or replace function public.public_operator(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'name', o.name, 'slug', o.slug, 'country', o.country, 'timezone', o.timezone,
    'currency', o.default_currency, 'locale', o.default_locale,
    'unit_system', o.unit_system, 'clock_24h', o.clock_24h,
    'logo_url', o.logo_url, 'brand_color', o.brand_color, 'default_tip_percent', o.default_tip_percent,
    'has_promos', exists (select 1 from promo_codes pc where pc.org_id = o.id and pc.active),
    'require_terms', o.require_terms, 'terms_text', o.terms_text, 'terms_version', o.terms_version,
    'cancel_free_hours', o.cancel_free_hours, 'cancel_fee_percent', o.cancel_fee_percent,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'seats', c.seats, 'luggage', c.luggage,
                       'description', c.description, 'amenities', to_jsonb(c.amenities), 'photo_urls', to_jsonb(c.photo_urls),
                       'services', (select coalesce(jsonb_agg(r.service_type), '[]'::jsonb) from rate_cards r
                                     where r.class_id = c.id and r.currency = o.default_currency))
                       order by c.sort_order, c.name)
      from vehicle_classes c where c.org_id = o.id), '[]'::jsonb),
    'extras', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'price', x.price, 'max_qty', x.max_qty)
                       order by x.sort_order, x.name)
      from extras x where x.org_id = o.id and x.active), '[]'::jsonb))
  from orgs o where o.slug = p_slug and o.status = 'active' and o.kind = 'operator';
$$;

create or replace function public.public_booking_status(p_slug text, p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'public_code', b.public_code, 'status', b.status, 'payment_status', b.payment_status,
    'total', b.total, 'subtotal', b.subtotal, 'tax_total', b.tax_total,
    'paid', b.paid_amount, 'balance', greatest(b.total - b.paid_amount, 0),
    'deposit_due', greatest(round(b.total * o.deposit_percent / 100, 2) - b.paid_amount, 0),
    'card_payments_ready', o.stripe_charges_enabled and o.status = 'active',
    'currency', b.currency, 'passenger_name', b.passenger_name,
    'round_trip', b.round_trip, 'passenger_count', b.passenger_count, 'luggage_count', b.luggage_count,
    'quote_sent_at', b.quote_sent_at, 'quote_expires_at', b.quote_expires_at,
    'can_accept', b.status = 'quoted' and b.quote_sent_at is not null
                  and (b.quote_expires_at is null or b.quote_expires_at > now()),
    'can_rate', b.status = 'completed' and not exists (select 1 from trip_ratings r where r.booking_id = b.id),
    'rating', (select rating from trip_ratings r where r.booking_id = b.id),
    'operator', jsonb_build_object('name', o.name, 'logo_url', o.logo_url, 'brand_color', o.brand_color,
                                   'cancel_free_hours', o.cancel_free_hours, 'cancel_fee_percent', o.cancel_fee_percent),
    'driver', (select jsonb_build_object('name', split_part(d.full_name, ' ', 1)) from drivers d
               where d.id = t.driver_id and t.status in ('assigned','en_route','arrived','on_board')),
    'vehicle', (select jsonb_build_object('make', v.make, 'model', v.model, 'color', v.color, 'plate', v.plate)
                from vehicles v where v.id = t.vehicle_id and t.status in ('assigned','en_route','arrived','on_board')),
    'pickup_at', t.pickup_at, 'pickup_address', t.pickup_address, 'dropoff_address', t.dropoff_address,
    'trip_status', t.status, 'flight_number', t.flight_number, 'meet_greet', t.meet_greet,
    'stops', coalesce((select jsonb_agg(s.address order by s.seq) from trip_stops s where s.trip_id = t.id), '[]'::jsonb),
    'return_at', (select r.pickup_at from trips r where r.booking_id = b.id and r.leg = 'return' limit 1),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'description', l.description, 'amount', l.amount)
                                        order by l.kind = 'tip', l.kind = 'discount', l.kind)
                       from booking_lines l where l.booking_id = b.id), '[]'::jsonb))
  from bookings b
  join orgs o on o.id = b.org_id
  join lateral (select * from trips where booking_id = b.id order by leg = 'return', pickup_at limit 1) t on true
  where o.slug = p_slug and b.public_code = p_code;
$$;

-- ---------------------------------------------------------------
-- Storage: vehicle photos (public) and documents (private to staff). Path starts with the company id.
-- ---------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('vehicles', 'vehicles', true) on conflict (id) do nothing;
    insert into storage.buckets (id, name, public) values ('documents', 'documents', false) on conflict (id) do nothing;
    execute $p$create policy vehicles_write on storage.objects for insert to authenticated
      with check (bucket_id = 'vehicles' and app.is_staff(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy vehicles_delete on storage.objects for delete to authenticated
      using (bucket_id = 'vehicles' and app.is_staff(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy documents_read on storage.objects for select to authenticated
      using (bucket_id = 'documents' and app.is_staff(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy documents_write on storage.objects for insert to authenticated
      with check (bucket_id = 'documents' and app.is_staff(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy documents_delete on storage.objects for delete to authenticated
      using (bucket_id = 'documents' and app.is_staff(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

-- ---------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------
grant select, insert, update, delete on zones, zone_rates, price_rules, notes, invoices, invoice_items,
  pay_runs, pay_run_lines, driver_shifts, vehicle_blocks, vehicle_documents, notification_templates to authenticated;
grant select on trip_ratings, notification_outbox to authenticated;
grant execute on function public.add_trip_charges(uuid, jsonb) to authenticated;
grant execute on function public.cancellation_terms(uuid) to authenticated;
grant execute on function public.charge_cancellation(uuid, text) to authenticated;
grant execute on function public.create_account_invoice(uuid, date, date) to authenticated;
grant execute on function public.set_invoice_status(uuid, text) to authenticated;
grant execute on function public.record_invoice_payment(uuid, numeric, text, text) to authenticated;
grant execute on function public.account_ageing(uuid) to authenticated;
grant execute on function public.create_pay_run(uuid, date, date) to authenticated;
grant execute on function public.set_pay_run_paid(uuid) to authenticated;
grant execute on function public.delete_pay_run(uuid) to authenticated;
grant execute on function public.create_recurring_bookings(uuid, uuid, jsonb, jsonb) to authenticated;
grant execute on function public.cancel_series(uuid, date, text) to authenticated;
grant execute on function public.compliance_alerts(uuid, integer) to authenticated;
grant execute on function public.assignment_warnings(uuid, uuid, uuid) to authenticated;
grant execute on function public.public_rate_booking(text, text, integer, text) to anon, authenticated;
grant execute on function public.driver_ratings(uuid) to authenticated;
grant execute on function public.install_default_templates(uuid) to authenticated;
grant execute on function public.preview_template(uuid, text) to authenticated;
grant execute on function app.zone_fare(uuid, uuid, numeric, numeric, numeric, numeric) to anon, authenticated;
grant execute on function app.in_airport_zone(uuid, numeric, numeric) to anon, authenticated;
