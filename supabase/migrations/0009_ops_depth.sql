-- 0009_ops_depth: enablers for Phase 7 (operations depth).
-- 1. Customers sign in on the web and claim their own bookings.
-- 2. Re-price an edited booking in one safe step.
-- 3. Cancel a booking with a recorded reason.
-- 4. Invoice details (address, tax number, footer) and tax labels on customer receipts.

-- Links every contact with the signed-in user's email (at any operator) to that user,
-- and makes them a customer of those operators. Returns how many bookings they can now see.
create function public.link_customer_account() returns integer
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_email text; v_count integer;
begin
  if v_user is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select lower(email) into v_email from auth.users where id = v_user;
  if v_email is null then return 0; end if;

  update contacts set user_id = v_user
   where lower(email) = v_email and (user_id is null or user_id = v_user);

  insert into memberships (org_id, user_id, role)
  select distinct c.org_id, v_user, 'customer' from contacts c
   where c.user_id = v_user
  on conflict (org_id, user_id, role) do update set active = true;

  insert into profiles (id) values (v_user) on conflict do nothing;

  select count(*) into v_count from bookings b join contacts c on c.id = b.booker_id where c.user_id = v_user;
  return v_count;
end $$;

-- Re-price a booking after an edit: replaces fare and surcharge lines from the current rate card.
-- Extras and tips stay. Only before the trip starts.
create function public.reprice_booking(
  p_booking uuid, p_class uuid, p_service text, p_distance numeric default 0, p_hours numeric default 0
) returns jsonb
language plpgsql as $$
declare
  b bookings; v_quote jsonb; v_tax uuid; l jsonb; v_trip trips;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'booking not found'; end if;
  if not app.is_staff(b.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if b.status not in ('quoted', 'confirmed') then
    raise exception 'only bookings that have not started can be re-priced';
  end if;
  select * into v_trip from trips where booking_id = p_booking order by pickup_at limit 1;
  if v_trip.status not in ('unassigned', 'offered', 'assigned') then
    raise exception 'only bookings that have not started can be re-priced';
  end if;

  v_quote := public.quote_price(b.org_id, p_class, p_service, p_distance, p_hours);
  v_tax := (v_quote->>'tax_rate_id')::uuid;

  update bookings set class_id = p_class, service_type = p_service where id = p_booking;
  update trips set distance = nullif(p_distance, 0), duration_hours = nullif(p_hours, 0) where id = v_trip.id;

  delete from booking_lines where booking_id = p_booking and kind in ('fare', 'surcharge');
  for l in select * from jsonb_array_elements(v_quote->'lines') loop
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (b.org_id, p_booking, l->>'kind', l->>'description', (l->>'amount')::numeric, v_tax, (l->>'tax_amount')::numeric);
  end loop;

  insert into trip_events (org_id, trip_id, status, actor_id) values (b.org_id, v_trip.id, 'repriced', auth.uid());
  return (select jsonb_build_object('subtotal', subtotal, 'tax_total', tax_total, 'total', total, 'paid', paid_amount, 'currency', currency)
          from bookings where id = p_booking);
end $$;

-- Cancel a booking and all its open trips, with a reason kept in the audit log.
create function public.cancel_booking(p_booking uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; t record;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'booking not found'; end if;
  if not app.is_staff(b.org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if b.status in ('completed', 'cancelled') then raise exception 'this booking is already %', b.status; end if;

  for t in select id, status from trips where booking_id = p_booking loop
    if t.status in ('on_board', 'completed', 'no_show') then
      raise exception 'a trip on this booking has already started';
    end if;
    if t.status <> 'cancelled' then
      update trips set status = 'cancelled' where id = t.id;
      insert into trip_events (org_id, trip_id, status, actor_id) values (b.org_id, t.id, 'cancelled', auth.uid());
    end if;
  end loop;

  update bookings set status = 'cancelled' where id = p_booking;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (b.org_id, auth.uid(), 'cancel_booking', 'booking', p_booking,
          jsonb_build_object('reason', nullif(trim(coalesce(p_reason, '')), '')));
end $$;

-- Invoice details on the company, edited in Settings by owners and admins.
alter table orgs add column billing_address text,
                 add column tax_number text,
                 add column invoice_footer text;

-- Customers and drivers may read tax labels (needed on receipts). Rates are not sensitive.
create policy member_read on tax_rates for select using (app.is_member(org_id));

grant execute on function public.link_customer_account() to authenticated;
grant execute on function public.reprice_booking(uuid, uuid, text, numeric, numeric) to authenticated;
grant execute on function public.cancel_booking(uuid, text) to authenticated;
