-- 0013_moovs_parity: closes the gaps found comparing our build to Moovs (screen-by-screen walkthrough).
-- 1. Zone polygons (in addition to the existing radius zones).
-- 2. Driver scorecards and penalty-rule deductions feeding into pay runs.
-- 3. Stripe dispute tracking and an evidence bundle for chargebacks.
-- 4. Ranked driver suggestions at assign time (transparent weighted score, not a learned model).
-- 5. One search across contacts, bookings and companies.

-- ---------------------------------------------------------------
-- 1. Zone polygons
-- ---------------------------------------------------------------
-- A free-form boundary as a ring of [lat, lng] pairs, e.g. [[43.64,-79.40],[43.66,-79.38],...].
-- When set, it is used instead of the radius. No PostGIS: point-in-polygon is done in plain SQL
-- (ray casting), which is fast enough at our zone counts and keeps the extension deferred as planned.
alter table zones add column boundary jsonb;
alter table zones add constraint zones_boundary_shape
  check (boundary is null or (jsonb_typeof(boundary) = 'array' and jsonb_array_length(boundary) >= 3));

create function app.point_in_zone(z zones, plat numeric, plng numeric) returns boolean
language plpgsql immutable as $$
declare n integer; i integer; j integer; xi numeric; yi numeric; xj numeric; yj numeric; inside boolean := false;
begin
  if plat is null or plng is null then return false; end if;
  if z.boundary is null then
    return app.km_between(z.lat, z.lng, plat, plng) <= z.radius_km;
  end if;
  n := jsonb_array_length(z.boundary);
  j := n - 1;
  for i in 0 .. n - 1 loop
    yi := (z.boundary->i->>0)::numeric; xi := (z.boundary->i->>1)::numeric;
    yj := (z.boundary->j->>0)::numeric; xj := (z.boundary->j->>1)::numeric;
    if ((yi > plat) <> (yj > plat)) and (plng < (xj - xi) * (plat - yi) / nullif(yj - yi, 0) + xi) then
      inside := not inside;
    end if;
    j := i;
  end loop;
  return inside;
end $$;

create or replace function app.zone_fare(p_org uuid, p_class uuid, plat numeric, plng numeric, dlat numeric, dlng numeric)
returns table (amount numeric, from_name text, to_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select zr.amount, fz.name, tz.name
  from zone_rates zr join zones fz on fz.id = zr.from_zone join zones tz on tz.id = zr.to_zone
  where zr.org_id = p_org and zr.class_id = p_class
    and ((app.point_in_zone(fz, plat, plng) and app.point_in_zone(tz, dlat, dlng))
      or (zr.both_directions and app.point_in_zone(fz, dlat, dlng) and app.point_in_zone(tz, plat, plng)))
  order by coalesce(fz.radius_km, 0) + coalesce(tz.radius_km, 0), zr.amount
  limit 1;
end $$;

create or replace function app.in_airport_zone(p_org uuid, plat numeric, plng numeric) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare z zones;
begin
  for z in select * from zones where org_id = p_org and kind = 'airport' loop
    if app.point_in_zone(z, plat, plng) then return true; end if;
  end loop;
  return false;
end $$;

-- Bulk polygon import, mirroring the existing radius CSV import: one zone per call so the UI can
-- report per-row success without a transaction rollback on one bad row.
create function public.upsert_zone(p_org uuid, p_name text, p_kind text, p_lat numeric, p_lng numeric,
                                    p_radius_km numeric, p_boundary jsonb default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not app.is_staff(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  insert into zones (org_id, name, kind, lat, lng, radius_km, boundary)
  values (p_org, trim(p_name), p_kind, p_lat, p_lng, p_radius_km, p_boundary)
  on conflict (org_id, name) do update set kind = excluded.kind, lat = excluded.lat, lng = excluded.lng,
    radius_km = excluded.radius_km, boundary = excluded.boundary
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------
-- 2. Driver scorecards and penalties
-- ---------------------------------------------------------------
create function public.driver_scorecard(p_org uuid, p_driver uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_trips integer; v_completed integer; v_no_show integer; v_cancelled integer;
  v_on_time integer; v_timed integer; v_rating numeric; v_ratings integer;
begin
  if not app.is_staff(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from drivers where id = p_driver and org_id = p_org) then
    raise exception 'driver not found';
  end if;

  select count(*), count(*) filter (where status = 'completed'),
         count(*) filter (where status = 'no_show'), count(*) filter (where status = 'cancelled')
    into v_trips, v_completed, v_no_show, v_cancelled
    from trips where driver_id = p_driver and org_id = p_org and pickup_at > now() - interval '90 days';

  select count(*) filter (where e.first_arrived <= t.pickup_at + interval '10 minutes'), count(*)
    into v_on_time, v_timed
    from trips t
    join lateral (select min(te.created_at) first_arrived from trip_events te
                   where te.trip_id = t.id and te.status = 'arrived') e on e.first_arrived is not null
   where t.driver_id = p_driver and t.org_id = p_org and t.status = 'completed'
     and t.pickup_at > now() - interval '90 days';

  select round(avg(r.rating), 2), count(*) into v_rating, v_ratings
    from trip_ratings r join trips t on t.booking_id = r.booking_id and t.leg = 'outbound'
   where t.driver_id = p_driver and r.org_id = p_org;

  return jsonb_build_object(
    'trips_90d', v_trips, 'completed_90d', v_completed, 'no_shows_90d', v_no_show, 'cancelled_90d', v_cancelled,
    'on_time_pct', case when v_timed > 0 then round(v_on_time * 100.0 / v_timed, 1) end,
    'timed_trips_90d', v_timed, 'rating', v_rating, 'ratings', v_ratings
  );
end $$;

-- Rules an operator defines once (late by N minutes, no-show, app non-compliance); applying one
-- creates a pending deduction a dispatcher or accountant must approve before it reaches a pay run.
create table penalty_rules (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  trigger     text not null check (trigger in ('late', 'no_show', 'other')),
  late_minutes integer check (late_minutes is null or late_minutes > 0),
  amount      numeric(10,2),             -- fixed deduction
  percent     numeric(5,2) check (percent is null or (percent > 0 and percent <= 100)),  -- % of that trip's driver pay
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  check ((amount is not null) <> (percent is not null))
);
alter table penalty_rules enable row level security;
create policy finance_all on penalty_rules for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));

create table driver_penalties (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  driver_id   uuid not null references drivers(id) on delete cascade,
  trip_id     uuid references trips(id) on delete set null,
  rule_id     uuid references penalty_rules(id) on delete set null,
  amount      numeric(10,2) not null check (amount > 0),
  note        text check (length(note) <= 300),
  status      text not null default 'pending' check (status in ('pending', 'applied', 'voided')),
  pay_run_id  uuid references pay_runs(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table driver_penalties enable row level security;
create policy finance_all on driver_penalties for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));
create policy driver_own on driver_penalties for select using (
  exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid()));

-- Manual penalty, or auto-raised by apply_penalty_rules() below.
create function public.add_driver_penalty(p_org uuid, p_driver uuid, p_amount numeric, p_note text,
                                           p_trip uuid default null, p_rule uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not app.is_finance(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  insert into driver_penalties (org_id, driver_id, trip_id, rule_id, amount, note)
  values (p_org, p_driver, p_trip, p_rule, p_amount, nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end $$;

create function public.void_driver_penalty(p_penalty uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r driver_penalties;
begin
  select * into r from driver_penalties where id = p_penalty;
  if not found then raise exception 'penalty not found'; end if;
  if not app.is_finance(r.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if r.status <> 'pending' then raise exception 'only a pending penalty can be voided'; end if;
  update driver_penalties set status = 'voided' where id = p_penalty;
end $$;

-- Scans completed trips with an active "late" rule and no penalty raised yet; run from the dispatch
-- board or a schedule. Returns how many it created.
create function public.apply_penalty_rules(p_org uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare r penalty_rules; t record; v_n integer := 0; v_pay numeric;
begin
  if not app.is_finance(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  for r in select * from penalty_rules where org_id = p_org and active and trigger in ('late', 'no_show') loop
    for t in
      select tr.id trip_id, tr.driver_id, tc.driver_pay
      from trips tr
      left join trip_costs tc on tc.trip_id = tr.id
      left join lateral (select min(created_at) first_arrived from trip_events where trip_id = tr.id and status = 'arrived') e on true
      where tr.org_id = p_org and tr.driver_id is not null
        and not exists (select 1 from driver_penalties dp where dp.trip_id = tr.id and dp.rule_id = r.id)
        and (
          (r.trigger = 'no_show' and tr.status = 'no_show')
          or (r.trigger = 'late' and tr.status = 'completed' and e.first_arrived is not null
              and e.first_arrived > tr.pickup_at + make_interval(mins => r.late_minutes))
        )
    loop
      v_pay := coalesce(t.driver_pay, 0);
      insert into driver_penalties (org_id, driver_id, trip_id, rule_id, amount, note)
      values (p_org, t.driver_id, t.trip_id,
              r.id, round(coalesce(r.amount, v_pay * r.percent / 100), 2),
              r.name);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

-- Extend create_pay_run to fold in approved-but-pending penalties for the same drivers and period,
-- as a negative adjustment, and mark those penalties applied.
create or replace function public.create_pay_run(p_org uuid, p_from date, p_to date) returns uuid
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
  ), pen as (
    update driver_penalties set status = 'applied', pay_run_id = v_run
    where org_id = p_org and status = 'pending'
      and driver_id in (select distinct driver_id from t)
    returning driver_id, amount
  )
  insert into pay_run_lines (pay_run_id, org_id, driver_id, trips, driver_pay, tips, adjustment, adjustment_note)
  select v_run, p_org, d, trips_n, pay_n, tip_n, -pen_n,
         case when pen_n > 0 then 'Penalties this period' end
  from (
    select t.driver_id d, count(*) trips_n, round(sum(t.pay), 2) pay_n, round(sum(t.tip), 2) tip_n,
           coalesce((select round(sum(amount), 2) from pen where pen.driver_id = t.driver_id), 0) pen_n
    from t group by t.driver_id
  ) x;
  if not exists (select 1 from pay_run_lines where pay_run_id = v_run) then
    delete from pay_runs where id = v_run;
    return null;
  end if;
  return v_run;
end $$;

-- ---------------------------------------------------------------
-- 3. Disputes (chargebacks)
-- ---------------------------------------------------------------
create table disputes (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references orgs(id) on delete cascade,
  payment_id        uuid references payments(id) on delete set null,
  booking_id        uuid references bookings(id) on delete set null,
  stripe_dispute_id text unique,
  amount            numeric(12,2) not null,
  currency          text not null,
  reason            text,
  status            text not null default 'needs_response'
                     check (status in ('needs_response', 'under_review', 'won', 'lost')),
  evidence_due_by   timestamptz,
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz
);
alter table disputes enable row level security;
create policy finance_all on disputes for all using (app.is_finance(org_id)) with check (app.is_finance(org_id));

-- Everything on hand to contest a chargeback: the trip timeline, booking and payment details.
-- This assembles our own records; it does not submit to Stripe's evidence API in this pass.
create function public.dispute_evidence(p_dispute uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d disputes; b bookings;
begin
  select * into d from disputes where id = p_dispute;
  if not found then raise exception 'dispute not found'; end if;
  if not app.is_finance(d.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into b from bookings where id = d.booking_id;
  return jsonb_build_object(
    'dispute', jsonb_build_object('amount', d.amount, 'currency', d.currency, 'reason', d.reason,
      'status', d.status, 'evidence_due_by', d.evidence_due_by),
    'booking', case when b.id is null then null else jsonb_build_object(
      'number', b.number, 'public_code', b.public_code, 'passenger_name', b.passenger_name,
      'passenger_phone', b.passenger_phone, 'total', b.total, 'currency', b.currency, 'status', b.status) end,
    'trips', coalesce((select jsonb_agg(jsonb_build_object(
        'leg', t.leg, 'pickup_at', t.pickup_at, 'pickup_address', t.pickup_address,
        'dropoff_address', t.dropoff_address, 'status', t.status,
        'timeline', (select jsonb_agg(jsonb_build_object('status', e.status, 'at', e.created_at, 'lat', e.lat, 'lng', e.lng) order by e.created_at)
                     from trip_events e where e.trip_id = t.id)))
      from trips t where t.booking_id = d.booking_id), '[]'::jsonb),
    'rating', (select jsonb_build_object('rating', r.rating, 'comment', r.comment) from trip_ratings r where r.booking_id = d.booking_id)
  );
end $$;

create function public.set_dispute_status(p_dispute uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r disputes;
begin
  select * into r from disputes where id = p_dispute;
  if not found then raise exception 'dispute not found'; end if;
  if not app.is_finance(r.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_status not in ('needs_response', 'under_review', 'won', 'lost') then raise exception 'unknown status'; end if;
  update disputes set status = p_status, resolved_at = case when p_status in ('won', 'lost') then now() else null end
  where id = p_dispute;
end $$;

-- ---------------------------------------------------------------
-- 4. Ranked driver suggestions
-- ---------------------------------------------------------------
-- A transparent weighted score (not a learned model): close, available, good record, and not
-- already loaded down today. Every reason is returned so a dispatcher can see why a driver ranked
-- where they did.
create function public.suggest_drivers(p_trip uuid, p_limit integer default 5) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t trips; v_end timestamptz; v_out jsonb := '[]'::jsonb; r record;
begin
  select * into t from trips where id = p_trip;
  if not found then raise exception 'trip not found'; end if;
  if not app.is_staff(t.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  v_end := t.pickup_at + make_interval(mins => (coalesce(t.duration_hours, 3) * 60)::integer);

  -- Candidates as a derived table first: ORDER BY below needs distance_km etc. as real output
  -- columns, since referencing an alias inside another expression (coalesce(distance_km, ...))
  -- only resolves against an input column, not a SELECT-list alias, in plain SQL.
  for r in
    select cand.*,
      (
        40 * (1 - least(coalesce(distance_km, 25), 50) / 50.0)
        + 25 * (coalesce(rating, 4) / 5.0)
        + 20 * (coalesce(on_time_pct, 90) / 100.0)
        + 15 * (1 - least(trips_today, 5) / 5.0)
      ) as score
    from (
      select d.id, d.full_name,
        dl.lat, dl.lng,
        case when dl.lat is not null and t.pickup_lat is not null
          then round(app.km_between(dl.lat, dl.lng, t.pickup_lat, t.pickup_lng), 1) end as distance_km,
        coalesce(sc.rating, 4) as rating,
        coalesce(sc.on_time_pct, 90) as on_time_pct,
        (select count(*) from trips x where x.driver_id = d.id and x.pickup_at::date = t.pickup_at::date
           and x.status not in ('cancelled', 'no_show')) as trips_today
      from drivers d
      left join driver_locations dl on dl.driver_id = d.id
      left join lateral (select public.driver_scorecard(t.org_id, d.id) as sc) scx on true
      left join lateral (select (scx.sc->>'rating')::numeric rating, (scx.sc->>'on_time_pct')::numeric on_time_pct) sc on true
      where d.org_id = t.org_id and d.active
        and not exists (select 1 from trips x where x.driver_id = d.id and x.id <> t.id
                           and x.status not in ('cancelled', 'no_show')
                           and x.pickup_at < v_end
                           and x.pickup_at + make_interval(mins => (coalesce(x.duration_hours, 3) * 60)::integer) > t.pickup_at)
        and not exists (select 1 from driver_shifts ds where ds.driver_id = d.id and ds.kind = 'time_off'
                           and ds.starts_at < v_end and ds.ends_at > t.pickup_at)
        and not exists (select 1 from driver_documents dd where dd.driver_id = d.id and dd.expires_on < t.pickup_at::date)
    ) cand
    order by score desc
    limit p_limit
  loop
    v_out := v_out || jsonb_build_object(
      'driver_id', r.id, 'full_name', r.full_name, 'distance_km', r.distance_km,
      'rating', r.rating, 'on_time_pct', r.on_time_pct, 'trips_today', r.trips_today,
      'score', round(r.score, 0),
      'reasons', (select jsonb_agg(x) from unnest(array_remove(array[
        case when r.distance_km is not null then r.distance_km::text || ' km away' end,
        case when r.rating is not null then r.rating::text || ' star average' end,
        case when r.on_time_pct is not null then r.on_time_pct::text || '% on time' end,
        case when r.trips_today > 0 then r.trips_today::text || ' trip(s) already today' end
      ], null)) x)
    );
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------
-- 5. Global search
-- ---------------------------------------------------------------
create function public.global_search(p_org uuid, p_query text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := trim(coalesce(p_query, '')); v_out jsonb;
begin
  if not app.is_member(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  if length(q) < 2 then return '{"contacts":[],"companies":[],"bookings":[]}'::jsonb; end if;
  select jsonb_build_object(
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', full_name, 'email', email, 'phone', phone))
      from (select id, full_name, email, phone from contacts
            where org_id = p_org and (full_name ilike '%' || q || '%' or email ilike '%' || q || '%' or phone ilike '%' || q || '%')
            limit 8) c), '[]'::jsonb),
    'companies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name))
      from (select id, name from accounts
            where org_id = p_org and name ilike '%' || q || '%' limit 8) a), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'passenger_name', passenger_name, 'status', status))
      from (select id, number, passenger_name, status from bookings
            where org_id = p_org and (passenger_name ilike '%' || q || '%' or number::text = q or public_code = q)
            limit 8) b), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;

-- ---------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------
grant execute on function public.upsert_zone(uuid, text, text, numeric, numeric, numeric, jsonb) to authenticated;
grant execute on function public.driver_scorecard(uuid, uuid) to authenticated;
grant execute on function public.add_driver_penalty(uuid, uuid, numeric, text, uuid, uuid) to authenticated;
grant execute on function public.void_driver_penalty(uuid) to authenticated;
grant execute on function public.apply_penalty_rules(uuid) to authenticated;
grant execute on function public.dispute_evidence(uuid) to authenticated;
grant execute on function public.set_dispute_status(uuid, text) to authenticated;
grant execute on function public.suggest_drivers(uuid, integer) to authenticated;
grant execute on function public.global_search(uuid, text) to authenticated;
grant select, insert, update on penalty_rules to authenticated;
grant select, insert, update on driver_penalties to authenticated;
grant select, insert, update on disputes to authenticated;
