-- 0010_booking_depth: what a real chauffeur booking needs (Phase 8).
-- Round trips, extra stops, airport details, passengers and luggage, extras, promo codes,
-- gratuity, online quote acceptance, operator branding and automatic driver pay.
-- Pricing stays in the database: price_trip is the single source of truth.

-- ---------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------
alter table rate_cards
  add column per_stop numeric(12,2) not null default 0,     -- each extra stop on a one-way leg
  add column min_hours numeric(6,2) not null default 0;     -- hourly minimum, e.g. 3

alter table orgs
  add column logo_url text,
  add column brand_color text check (brand_color is null or brand_color ~ '^#[0-9A-Fa-f]{6}$'),
  add column default_tip_percent numeric(5,2) not null default 0 check (default_tip_percent between 0 and 50),
  add column quote_valid_hours integer not null default 48 check (quote_valid_hours between 1 and 720);

alter table bookings
  add column round_trip boolean not null default false,
  add column promo_code text,
  add column passenger_count integer check (passenger_count between 1 and 60),
  add column luggage_count integer check (luggage_count between 0 and 60),
  add column customer_notes text check (length(customer_notes) <= 1000),
  add column quote_sent_at timestamptz,
  add column quote_expires_at timestamptz;

alter table trips
  add column leg text not null default 'outbound' check (leg in ('outbound', 'return')),
  add column flight_number text check (length(flight_number) <= 12),
  add column airline text check (length(airline) <= 60),
  add column meet_greet boolean not null default false,
  add column notes text check (length(notes) <= 1000);

alter table drivers
  add column pay_percent numeric(5,2) check (pay_percent between 0 and 100);   -- share of the fare before tax and tips

alter table booking_lines drop constraint booking_lines_kind_check;
alter table booking_lines add constraint booking_lines_kind_check
  check (kind in ('fare', 'surcharge', 'extra', 'tip', 'discount'));

-- ---------------------------------------------------------------
-- New tables
-- ---------------------------------------------------------------
create table trip_stops (
  id       uuid primary key default gen_random_uuid(),
  org_id   uuid not null references orgs(id) on delete cascade,
  trip_id  uuid not null references trips(id) on delete cascade,
  seq      integer not null check (seq between 1 and 10),
  address  text not null check (length(address) <= 500),
  lat      numeric(9,6),
  lng      numeric(9,6),
  unique (trip_id, seq)
);

create table extras (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  price       numeric(12,2) not null check (price >= 0),
  taxable     boolean not null default true,
  max_qty     integer not null default 1 check (max_qty between 1 and 10),
  active      boolean not null default true,
  sort_order  integer not null default 0
);

create table promo_codes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  code        text not null check (code ~ '^[A-Za-z0-9_-]{3,30}$'),
  kind        text not null check (kind in ('percent', 'fixed')),
  value       numeric(12,2) not null check (value > 0),
  starts_at   timestamptz,
  ends_at     timestamptz,
  max_uses    integer check (max_uses > 0),
  used_count  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index promo_codes_org_code on promo_codes (org_id, upper(code));

alter table trip_stops  enable row level security;
alter table extras      enable row level security;
alter table promo_codes enable row level security;

create policy staff_all on trip_stops for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
-- Drivers, customers and partners see stops of the trips they can already see.
create policy trip_read on trip_stops for select using (exists (select 1 from trips t where t.id = trip_id));

create policy staff_all   on extras for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
create policy member_read on extras for select using (app.is_member(org_id));

create policy staff_all on promo_codes for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));

-- ---------------------------------------------------------------
-- Pricing
-- ---------------------------------------------------------------
-- p: { class_id, service ('one_way'|'hourly'), distance, hours, round_trip, stops (count),
--      extras: [{id, qty}], promo_code, tip_percent }
-- Returns { currency, tax_rate_id, tax_label, lines[], subtotal, tax_total, total, promo: {code, applied, reason} }
create function public.price_trip(p_org uuid, p jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_cur text; v_card rate_cards; v_tax tax_rates;
  v_service text := coalesce(p->>'service', 'one_way');
  v_class uuid := (p->>'class_id')::uuid;
  v_dist numeric := greatest(coalesce((p->>'distance')::numeric, 0), 0);
  v_hours numeric := greatest(coalesce((p->>'hours')::numeric, 0), 0);
  v_round boolean := coalesce((p->>'round_trip')::boolean, false) and coalesce(p->>'service', 'one_way') = 'one_way';
  v_stops integer := least(greatest(coalesce((p->>'stops')::integer, 0), 0), 10);
  v_tip numeric := least(greatest(coalesce((p->>'tip_percent')::numeric, 0), 0), 50);
  v_code text := nullif(upper(trim(coalesce(p->>'promo_code', ''))), '');
  v_leg numeric(12,2); v_fares numeric(12,2) := 0; v_base numeric(12,2);
  v_lines jsonb := '[]'::jsonb; v_sub numeric(12,2) := 0; v_taxsum numeric(12,2) := 0;
  v_amt numeric(12,2); v_t numeric(12,2);
  s record; x record; e jsonb; v_qty integer; pc promo_codes; v_promo jsonb := null;
begin
  if v_service not in ('one_way', 'hourly') then raise exception 'service must be one_way or hourly'; end if;
  select default_currency into v_cur from orgs where id = p_org;
  if v_cur is null then raise exception 'unknown operator'; end if;
  select * into v_card from rate_cards
   where org_id = p_org and class_id = v_class and service_type = v_service and currency = v_cur;
  if not found then raise exception 'no rate card for this vehicle class and service'; end if;
  select * into v_tax from tax_rates where org_id = p_org and is_default;
  if v_tax.id is null then raise exception 'no tax rate configured'; end if;

  -- Fare per leg. Hourly bills at least min_hours.
  v_leg := greatest(v_card.minimum_amount, round(v_card.base_amount
             + case when v_service = 'one_way' then v_card.per_distance * v_dist else 0 end
             + case when v_service = 'hourly' then v_card.per_hour * greatest(v_hours, v_card.min_hours) else 0 end, 2));

  v_t := round(v_leg * v_tax.rate, 2);
  v_lines := v_lines || jsonb_build_object('kind', 'fare', 'code', 'fare', 'description',
               case when v_service = 'hourly' then 'Hourly fare' else 'Fare' end, 'amount', v_leg, 'tax_amount', v_t);
  v_sub := v_sub + v_leg; v_taxsum := v_taxsum + v_t; v_fares := v_leg;

  if v_round then
    v_t := round(v_leg * v_tax.rate, 2);
    v_lines := v_lines || jsonb_build_object('kind', 'fare', 'code', 'return_fare', 'description', 'Return fare',
                 'amount', v_leg, 'tax_amount', v_t);
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
    v_lines := v_lines || jsonb_build_object('kind', 'surcharge', 'code', 'surcharge', 'description', s.name,
                 'amount', v_amt, 'tax_amount', v_t);
    v_sub := v_sub + v_amt; v_taxsum := v_taxsum + v_t;
  end loop;
  v_base := v_sub;   -- fares, stops and surcharges: what a promo code discounts

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
      v_amt := least(v_base, case pc.kind when 'percent' then round(v_base * least(pc.value, 100) / 100, 2)
                                          else round(pc.value, 2) end);
      v_t := round(-v_amt * v_tax.rate, 2);
      v_lines := v_lines || jsonb_build_object('kind', 'discount', 'code', 'promo',
                   'description', format('Promo %s', pc.code), 'amount', -v_amt, 'tax_amount', v_t);
      v_sub := v_sub - v_amt; v_taxsum := v_taxsum + v_t;
      v_promo := jsonb_build_object('code', pc.code, 'applied', true, 'reason', null, 'amount', v_amt);
    end if;
  end if;

  if v_tip > 0 then   -- gratuity on the fares, never taxed
    v_amt := round(v_fares * v_tip / 100, 2);
    v_lines := v_lines || jsonb_build_object('kind', 'tip', 'code', 'tip',
                 'description', format('Gratuity (%s%%)', trim(to_char(v_tip, 'FM990.##'))), 'amount', v_amt, 'tax_amount', 0);
    v_sub := v_sub + v_amt;
  end if;

  return jsonb_build_object('currency', v_cur, 'tax_rate_id', v_tax.id, 'tax_label', v_tax.label,
    'lines', v_lines, 'subtotal', v_sub, 'tax_total', v_taxsum, 'total', v_sub + v_taxsum, 'promo', v_promo);
end $$;

-- Public price check for the booking page. Same rules, by company slug.
create function public.public_price_trip(p_slug text, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid;
begin
  select id into v_org from orgs where slug = p_slug and status = 'active' and kind = 'operator';
  if v_org is null then raise exception 'unknown operator'; end if;
  return public.price_trip(v_org, p);
end $$;

-- ---------------------------------------------------------------
-- Booking creation (internal). Not callable by clients directly.
-- p adds: passenger_name, passenger_phone, pickup_at, pickup_address, pickup_lat, pickup_lng,
--   dropoff_address, dropoff_lat, dropoff_lng, stops_list: [{address, lat, lng}], return_at,
--   flight_number, airline, meet_greet, notes, passenger_count, luggage_count, customer_notes
-- ---------------------------------------------------------------
create function app.book(p_org uuid, p_booker uuid, p jsonb, p_status text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_price jsonb; v_tax uuid; v_booking uuid; v_trip uuid; v_ret uuid; l jsonb; st jsonb; i integer := 0;
  v_stops jsonb := coalesce(p->'stops_list', '[]'::jsonb);
  v_round boolean := coalesce((p->>'round_trip')::boolean, false) and coalesce(p->>'service', 'one_way') = 'one_way';
  v_pickup timestamptz := (p->>'pickup_at')::timestamptz;
  v_return timestamptz := nullif(p->>'return_at', '')::timestamptz;
begin
  if coalesce(trim(p->>'pickup_address'), '') = '' then raise exception 'pickup address is required'; end if;
  if coalesce(trim(p->>'passenger_name'), '') = '' then raise exception 'passenger name is required'; end if;
  if v_pickup is null then raise exception 'pickup time is required'; end if;
  if jsonb_array_length(v_stops) > 5 then raise exception 'at most 5 extra stops'; end if;
  if v_round and (v_return is null or v_return <= v_pickup) then
    raise exception 'return time must be after the pickup time';
  end if;

  v_price := public.price_trip(p_org, p || jsonb_build_object('stops', jsonb_array_length(v_stops)));
  v_tax := (v_price->>'tax_rate_id')::uuid;

  insert into bookings (org_id, booker_id, passenger_name, passenger_phone, service_type, class_id, status, currency,
                        round_trip, promo_code, passenger_count, luggage_count, customer_notes)
  values (p_org, p_booker, trim(p->>'passenger_name'), nullif(trim(coalesce(p->>'passenger_phone', '')), ''),
          coalesce(p->>'service', 'one_way'), (p->>'class_id')::uuid, p_status, v_price->>'currency',
          v_round, case when (v_price->'promo'->>'applied')::boolean then v_price->'promo'->>'code' end,
          nullif(p->>'passenger_count', '')::integer, nullif(p->>'luggage_count', '')::integer,
          nullif(trim(coalesce(p->>'customer_notes', '')), ''))
  returning id into v_booking;

  for l in select * from jsonb_array_elements(v_price->'lines') loop
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (p_org, v_booking, l->>'kind', l->>'description', (l->>'amount')::numeric,
            case when l->>'kind' = 'tip' or (l->>'tax_rate') = 'false' then null else v_tax end,
            (l->>'tax_amount')::numeric);
  end loop;

  insert into trips (org_id, booking_id, leg, pickup_at, pickup_address, pickup_lat, pickup_lng,
                     dropoff_address, dropoff_lat, dropoff_lng, distance, duration_hours,
                     flight_number, airline, meet_greet, notes)
  values (p_org, v_booking, 'outbound', v_pickup, trim(p->>'pickup_address'),
          nullif(p->>'pickup_lat', '')::numeric, nullif(p->>'pickup_lng', '')::numeric,
          nullif(trim(coalesce(p->>'dropoff_address', '')), ''),
          nullif(p->>'dropoff_lat', '')::numeric, nullif(p->>'dropoff_lng', '')::numeric,
          nullif((p->>'distance')::numeric, 0), nullif((p->>'hours')::numeric, 0),
          nullif(upper(trim(coalesce(p->>'flight_number', ''))), ''), nullif(trim(coalesce(p->>'airline', '')), ''),
          coalesce((p->>'meet_greet')::boolean, false), nullif(trim(coalesce(p->>'notes', '')), ''))
  returning id into v_trip;

  for st in select * from jsonb_array_elements(v_stops) loop
    i := i + 1;
    if coalesce(trim(st->>'address'), '') = '' then raise exception 'stop % has no address', i; end if;
    insert into trip_stops (org_id, trip_id, seq, address, lat, lng)
    values (p_org, v_trip, i, trim(st->>'address'), nullif(st->>'lat', '')::numeric, nullif(st->>'lng', '')::numeric);
  end loop;

  if v_round then   -- return leg: drop-off back to pickup, no stops
    insert into trips (org_id, booking_id, leg, pickup_at, pickup_address, pickup_lat, pickup_lng,
                       dropoff_address, dropoff_lat, dropoff_lng, distance)
    values (p_org, v_booking, 'return', v_return,
            coalesce(nullif(trim(coalesce(p->>'dropoff_address', '')), ''), trim(p->>'pickup_address')),
            nullif(p->>'dropoff_lat', '')::numeric, nullif(p->>'dropoff_lng', '')::numeric,
            trim(p->>'pickup_address'), nullif(p->>'pickup_lat', '')::numeric, nullif(p->>'pickup_lng', '')::numeric,
            nullif((p->>'distance')::numeric, 0));
  end if;

  if (v_price->'promo'->>'applied')::boolean then
    update promo_codes set used_count = used_count + 1
     where org_id = p_org and upper(code) = upper(v_price->'promo'->>'code');
  end if;
  return v_booking;
end $$;
revoke all on function app.book(uuid, uuid, jsonb, text) from public;

-- Staff: create a booking. p.status 'confirmed' (default) or 'quoted' (to send as a quote).
create function public.create_booking_v2(p_org uuid, p_booker uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_status text := coalesce(nullif(p->>'status', ''), 'confirmed');
begin
  if not app.is_staff(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_status not in ('confirmed', 'quoted') then raise exception 'status must be confirmed or quoted'; end if;
  if p_booker is not null and not exists (select 1 from contacts where id = p_booker and org_id = p_org) then
    raise exception 'unknown customer';
  end if;
  if not exists (select 1 from vehicle_classes where id = (p->>'class_id')::uuid and org_id = p_org) then
    raise exception 'unknown vehicle class';
  end if;
  return app.book(p_org, p_booker, p, v_status);
end $$;

-- Customer request from the booking page. Lands as 'quoted' for the operator to confirm or send back.
create function public.public_create_booking_v2(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_contact uuid; v_booking uuid; v_email text := lower(trim(coalesce(p->>'booker_email', '')));
begin
  select id into v_org from orgs where slug = p_slug and status = 'active' and kind = 'operator';
  if v_org is null then raise exception 'unknown operator'; end if;
  if not exists (select 1 from vehicle_classes where id = (p->>'class_id')::uuid and org_id = v_org) then
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

  select id into v_contact from contacts where org_id = v_org and lower(email) = v_email limit 1;
  if v_contact is null then
    insert into contacts (org_id, full_name, email, phone)
    values (v_org, trim(p->>'booker_name'), v_email, nullif(trim(coalesce(p->>'booker_phone', '')), ''))
    returning id into v_contact;
  end if;

  v_booking := app.book(v_org, v_contact,
    p || jsonb_build_object(
      'passenger_name', coalesce(nullif(trim(coalesce(p->>'passenger_name', '')), ''), trim(p->>'booker_name')),
      'passenger_phone', coalesce(nullif(trim(coalesce(p->>'passenger_phone', '')), ''), p->>'booker_phone')),
    'quoted');
  return (select jsonb_build_object('public_code', public_code, 'total', total, 'currency', currency)
          from bookings where id = v_booking);
end $$;

-- ---------------------------------------------------------------
-- Quote workflow
-- ---------------------------------------------------------------
-- Staff: send a quoted booking to the customer to accept online. Returns the status page code.
create function public.send_quote(p_booking uuid) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings; v_hours integer;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'booking not found'; end if;
  if not app.is_staff(b.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if b.status <> 'quoted' then raise exception 'only quotes can be sent'; end if;
  select quote_valid_hours into v_hours from orgs where id = b.org_id;
  update bookings set quote_sent_at = now(), quote_expires_at = now() + make_interval(hours => v_hours)
   where id = p_booking;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (b.org_id, auth.uid(), 'send_quote', 'booking', p_booking, jsonb_build_object('total', b.total));
  return b.public_code;
end $$;

-- Staff: confirm a quote directly (phone or email acceptance).
create function public.confirm_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'booking not found'; end if;
  if not app.is_staff(b.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if b.status <> 'quoted' then raise exception 'only quotes can be confirmed'; end if;
  update bookings set status = 'confirmed' where id = p_booking;
  insert into trip_events (org_id, trip_id, status, actor_id)
  select b.org_id, id, 'confirmed', auth.uid() from trips where booking_id = p_booking;
end $$;

-- Customer: accept a quote that was sent and has not expired.
create function public.public_accept_quote(p_slug text, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select bk.* into b from bookings bk join orgs o on o.id = bk.org_id
   where o.slug = p_slug and o.status = 'active' and bk.public_code = p_code for update of bk;
  if not found then raise exception 'booking not found'; end if;
  if b.status = 'confirmed' then return 'confirmed'; end if;
  if b.status <> 'quoted' or b.quote_sent_at is null then raise exception 'this quote is not ready to accept'; end if;
  if b.quote_expires_at is not null and b.quote_expires_at < now() then raise exception 'this quote has expired'; end if;
  update bookings set status = 'confirmed' where id = b.id;
  insert into trip_events (org_id, trip_id, status)
  select b.org_id, id, 'quote_accepted' from trips where booking_id = b.id;
  return 'confirmed';
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
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'seats', c.seats, 'luggage', c.luggage,
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
    'operator', jsonb_build_object('name', o.name, 'logo_url', o.logo_url, 'brand_color', o.brand_color),
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
-- Driver pay: when a trip completes and no pay was entered, apply the driver's percentage
-- to the fare share of that trip (before tax, tips and extras).
-- ---------------------------------------------------------------
create function app.auto_driver_pay() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pct numeric; v_fares numeric; v_legs integer;
begin
  if new.status <> 'completed' or old.status = 'completed' or new.driver_id is null then return new; end if;
  select pay_percent into v_pct from drivers where id = new.driver_id;
  if v_pct is null then return new; end if;
  select coalesce(sum(amount), 0) into v_fares from booking_lines
   where booking_id = new.booking_id and kind in ('fare', 'surcharge', 'discount');
  select count(*) into v_legs from trips where booking_id = new.booking_id and status <> 'cancelled';
  insert into trip_costs (trip_id, org_id, driver_pay)
  values (new.id, new.org_id, round(v_fares / greatest(v_legs, 1) * v_pct / 100, 2))
  on conflict (trip_id) do nothing;
  return new;
end $$;

create trigger trips_auto_driver_pay after update of status on trips
  for each row execute function app.auto_driver_pay();

-- ---------------------------------------------------------------
-- Operator logos: public bucket, writable by the company's owners and admins.
-- Path must start with the company id: "<org_id>/logo.png".
-- ---------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('branding', 'branding', true) on conflict (id) do nothing;
    execute $p$create policy branding_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'branding' and app.has_role(((storage.foldername(name))[1])::uuid, array['owner','admin']))$p$;
    execute $p$create policy branding_update on storage.objects for update to authenticated
      using (bucket_id = 'branding' and app.has_role(((storage.foldername(name))[1])::uuid, array['owner','admin']))$p$;
    execute $p$create policy branding_delete on storage.objects for delete to authenticated
      using (bucket_id = 'branding' and app.has_role(((storage.foldername(name))[1])::uuid, array['owner','admin']))$p$;
  end if;
end $$;

-- ---------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------
grant select, insert, update, delete on trip_stops, extras, promo_codes to authenticated;
grant execute on function public.price_trip(uuid, jsonb) to authenticated;
grant execute on function public.public_price_trip(text, jsonb) to anon, authenticated;
grant execute on function public.create_booking_v2(uuid, uuid, jsonb) to authenticated;
grant execute on function public.public_create_booking_v2(text, jsonb) to anon, authenticated;
grant execute on function public.send_quote(uuid) to authenticated;
grant execute on function public.confirm_booking(uuid) to authenticated;
grant execute on function public.public_accept_quote(text, text) to anon, authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table trip_stops;
  end if;
end $$;
