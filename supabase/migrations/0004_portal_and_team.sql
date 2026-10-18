-- 0004_portal_and_team: public booking portal (no sign-in) and adding team members by email.

-- Public profile of an operator plus its vehicle classes, for the booking portal.
create function public.public_operator(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'name', o.name, 'slug', o.slug, 'country', o.country, 'timezone', o.timezone,
    'currency', o.default_currency, 'locale', o.default_locale,
    'unit_system', o.unit_system, 'clock_24h', o.clock_24h,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'seats', c.seats, 'luggage', c.luggage)
                       order by c.sort_order, c.name)
      from vehicle_classes c where c.org_id = o.id), '[]'::jsonb))
  from orgs o where o.slug = p_slug;
$$;

-- A customer requests a booking from the portal. Status 'quoted' = waiting for the operator to confirm.
create function public.public_create_booking(
  p_slug text, p_class uuid, p_service text, p_pickup_at timestamptz,
  p_pickup_address text, p_dropoff_address text, p_distance numeric, p_hours numeric,
  p_booker_name text, p_booker_email text, p_booker_phone text,
  p_passenger_name text default null, p_passenger_phone text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid; v_quote jsonb; v_tax uuid; v_contact uuid; v_booking uuid; v_code text; l jsonb;
begin
  select id into v_org from orgs where slug = p_slug;
  if v_org is null then raise exception 'unknown operator'; end if;
  if not exists (select 1 from vehicle_classes where id = p_class and org_id = v_org) then
    raise exception 'unknown vehicle class';
  end if;
  if p_pickup_at < now() + interval '30 minutes' then
    raise exception 'pickup must be at least 30 minutes from now';
  end if;
  if coalesce(trim(p_booker_name), '') = '' or coalesce(trim(p_booker_email), '') = ''
     or coalesce(trim(p_pickup_address), '') = '' then
    raise exception 'name, email and pickup address are required';
  end if;
  if length(p_booker_name) > 200 or length(p_booker_email) > 320 or length(p_pickup_address) > 500
     or length(coalesce(p_dropoff_address, '')) > 500 then
    raise exception 'input too long';
  end if;

  v_quote := public.quote_price(v_org, p_class, p_service, p_distance, p_hours);
  v_tax := (v_quote->>'tax_rate_id')::uuid;

  select id into v_contact from contacts
   where org_id = v_org and lower(email) = lower(trim(p_booker_email)) limit 1;
  if v_contact is null then
    insert into contacts (org_id, full_name, email, phone)
    values (v_org, trim(p_booker_name), lower(trim(p_booker_email)), p_booker_phone)
    returning id into v_contact;
  end if;

  insert into bookings (org_id, booker_id, passenger_name, passenger_phone, service_type, class_id, status, currency)
  values (v_org, v_contact, coalesce(nullif(trim(p_passenger_name), ''), trim(p_booker_name)),
          coalesce(p_passenger_phone, p_booker_phone), p_service, p_class, 'quoted', v_quote->>'currency')
  returning id, public_code into v_booking, v_code;

  for l in select * from jsonb_array_elements(v_quote->'lines') loop
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (v_org, v_booking, l->>'kind', l->>'description', (l->>'amount')::numeric, v_tax, (l->>'tax_amount')::numeric);
  end loop;

  insert into trips (org_id, booking_id, pickup_at, pickup_address, dropoff_address, distance, duration_hours)
  values (v_org, v_booking, p_pickup_at, p_pickup_address, p_dropoff_address,
          nullif(p_distance, 0), nullif(p_hours, 0));

  insert into audit_log (org_id, action, entity, entity_id, detail)
  values (v_org, 'portal_request', 'booking', v_booking, jsonb_build_object('email', lower(trim(p_booker_email))));

  return jsonb_build_object('public_code', v_code, 'total', (v_quote->>'total')::numeric,
                            'currency', v_quote->>'currency', 'status', 'quoted');
end $$;

-- Confirmation / status page for a portal booking, by operator slug and public code.
create function public.public_booking_status(p_slug text, p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'public_code', b.public_code, 'status', b.status, 'payment_status', b.payment_status,
    'total', b.total, 'currency', b.currency, 'passenger_name', b.passenger_name,
    'pickup_at', t.pickup_at, 'pickup_address', t.pickup_address, 'dropoff_address', t.dropoff_address,
    'trip_status', t.status)
  from bookings b
  join orgs o on o.id = b.org_id
  join lateral (select * from trips where booking_id = b.id order by pickup_at limit 1) t on true
  where o.slug = p_slug and b.public_code = p_code;
$$;

-- Owner or admin adds an existing user (who has signed up) to their operator by email.
-- Returns 'added', 'already_member' or 'no_account' (the person must sign up first).
create function public.add_member_by_email(
  p_org uuid, p_email text, p_role text, p_driver_name text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_name text;
begin
  if not app.has_role(p_org, array['owner','admin']) then
    raise exception 'only owners and admins can add team members' using errcode = '42501';
  end if;
  if p_role not in ('admin','dispatcher','driver','customer') then
    raise exception 'invalid role %', p_role;
  end if;

  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then return 'no_account'; end if;

  if exists (select 1 from memberships where org_id = p_org and user_id = v_user and role = p_role) then
    update memberships set active = true where org_id = p_org and user_id = v_user and role = p_role;
    return 'already_member';
  end if;

  insert into memberships (org_id, user_id, role) values (p_org, v_user, p_role);

  if p_role = 'driver' and not exists (select 1 from drivers where org_id = p_org and user_id = v_user) then
    v_name := coalesce(nullif(trim(p_driver_name), ''), split_part(p_email, '@', 1));
    insert into drivers (org_id, user_id, full_name) values (p_org, v_user, v_name);
  end if;

  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'add_member', 'membership', v_user, jsonb_build_object('role', p_role));
  return 'added';
end $$;

-- Staff need to read the emails of team members; auth.users is not exposed to clients.
create function public.team_members(p_org uuid)
returns table (membership_id uuid, user_id uuid, email text, role text, active boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, m.user_id, u.email::text, m.role, m.active, m.created_at
  from memberships m join auth.users u on u.id = m.user_id
  where m.org_id = p_org and app.is_staff(p_org)
  order by m.created_at;
$$;

grant execute on function public.public_operator(text) to anon, authenticated;
grant execute on function public.public_create_booking(text,uuid,text,timestamptz,text,text,numeric,numeric,text,text,text,text,text) to anon, authenticated;
grant execute on function public.public_booking_status(text,text) to anon, authenticated;
grant execute on function public.add_member_by_email(uuid,text,text,text) to authenticated;
grant execute on function public.team_members(uuid) to authenticated;

-- Live updates for the dispatch board (Supabase Realtime). Skipped where the publication does not exist.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table trips, trip_events, bookings;
  end if;
end $$;
