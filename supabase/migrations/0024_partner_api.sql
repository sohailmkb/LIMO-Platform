-- 0024_partner_api: the backend half of Step A2/Step D/Step 16 that's been deferred since
-- the self-service credential UI shipped (0017). That UI only ever let an org GENERATE
-- keys and register webhook endpoints; nothing in the database could yet be called WITH
-- those keys. This migration adds the entry points the partner-api and
-- webhook-delivery-worker edge functions (written alongside this migration) call.
--
-- Why these are new functions rather than reusing create_booking/cancel_booking/etc:
-- those existing RPCs are written for a signed-in-staff caller and, where it matters
-- (cancel_booking), gate on app.is_staff(org_id) -- which reads auth.uid(), a concept
-- that does not exist when the edge function calls as service_role on a partner's
-- behalf. Re-pointing them at service_role would either silently disable that check
-- (if called from a context with no auth.uid()) or require weakening it. Instead, each
-- api_* function below takes an explicit p_client (the authenticated API client, already
-- verified by the edge function against api_credentials/api_credential_secrets) and
-- proves ownership itself: a booking can only be modified or cancelled through the same
-- api_client that created it, checked in SQL, not assumed from the caller's own claim.
-- These functions are PUBLIC-EXECUTE REVOKED and granted only to service_role: no signed-in
-- user, staff or otherwise, can call them directly, by design -- the edge function's key/
-- secret check is the only door in.
--
-- quote_price and create_booking themselves need no changes: both already have PUBLIC
-- default execute (no REVOKE was ever issued on them) and no auth.uid()-based check, which
-- is how the existing public booking widget already calls them anonymously. api_create_booking
-- below duplicates create_booking's insert logic rather than calling it, only so it can also
-- stamp created_via_api_client_id and validate p_class against the client's own org in one
-- place; the actual pricing math is delegated to the same quote_price everything else uses.

alter table bookings add column created_via_api_client_id uuid references api_clients(id) on delete set null;
comment on column bookings.created_via_api_client_id is 'Set only for a booking created through the partner API. Null for every staff-entered, public-widget, hotel, or group booking. Ownership check for api_modify_booking/api_cancel_booking/api_booking_status: a credential can only touch what its own client created.';
create index bookings_api_client_idx on bookings (created_via_api_client_id) where created_via_api_client_id is not null;

-- ---------------------------------------------------------------
-- Webhook emission. Security definer so any RPC (including the ones below) can call it
-- without needing its own webhook_endpoints grants. Cheap no-op when an org has registered
-- no endpoint for the event -- the common case for every org today, since nobody has
-- configured one yet.
-- ---------------------------------------------------------------
create function public.emit_webhook_event(p_org uuid, p_event_type text, p_payload jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into webhook_deliveries (endpoint_id, event_type, payload, status, next_attempt_at)
  select e.id, p_event_type, p_payload, 'pending', now()
  from webhook_endpoints e
  where e.org_id = p_org and e.active and (p_event_type = any(e.events) or '*' = any(e.events));
end $$;
revoke execute on function public.emit_webhook_event(uuid, text, jsonb) from public;
grant execute on function public.emit_webhook_event(uuid, text, jsonb) to service_role;

-- A trip's status change is useful to a partner integration regardless of which channel
-- created the booking (staff, widget, hotel, or the API itself), so this fires for all of
-- them -- emit_webhook_event's own join against webhook_endpoints keeps it a no-op for an
-- org with nothing registered.
create function app.notify_trip_status_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.emit_webhook_event(new.org_id, 'trip.status_changed', jsonb_build_object(
    'trip_id', new.id, 'booking_id', new.booking_id, 'status', new.status, 'previous_status', old.status
  ));
  return new;
end $$;
create trigger trips_notify_status_change after update on trips
  for each row when (new.status is distinct from old.status)
  execute function app.notify_trip_status_change();

-- ---------------------------------------------------------------
-- Partner API entry points. Every one takes p_client, not p_org: the edge function has
-- already authenticated the credential and resolved it to a client, and these functions
-- re-derive org_id from api_clients themselves rather than trusting a caller-supplied org id.
-- ---------------------------------------------------------------
create function public.api_create_booking(
  p_client uuid, p_passenger_name text, p_passenger_phone text,
  p_service text, p_class uuid, p_pickup_at timestamptz, p_pickup_address text,
  p_dropoff_address text default null, p_distance numeric default 0, p_hours numeric default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid; v_quote jsonb; v_booking uuid; v_tax uuid; l jsonb; v_row bookings;
begin
  select org_id into v_org from api_clients where id = p_client and active;
  if v_org is null then raise exception 'unknown or inactive API client' using errcode = '42501'; end if;
  if not exists (select 1 from vehicle_classes where id = p_class and org_id = v_org) then
    raise exception 'vehicle_class_id does not belong to this operator';
  end if;
  if p_service not in ('one_way', 'hourly') then raise exception 'service_type must be one_way or hourly'; end if;

  v_quote := public.quote_price(v_org, p_class, p_service, p_distance, p_hours);
  v_tax := (v_quote->>'tax_rate_id')::uuid;

  insert into bookings (org_id, passenger_name, passenger_phone, service_type, class_id, status, currency, created_via_api_client_id)
  values (v_org, p_passenger_name, p_passenger_phone, p_service, p_class, 'confirmed', v_quote->>'currency', p_client)
  returning id into v_booking;

  for l in select * from jsonb_array_elements(v_quote -> 'lines') loop
    insert into booking_lines (org_id, booking_id, kind, description, amount, tax_rate_id, tax_amount)
    values (v_org, v_booking, l ->> 'kind', l ->> 'description', (l ->> 'amount')::numeric, v_tax, (l ->> 'tax_amount')::numeric);
  end loop;

  insert into trips (org_id, booking_id, pickup_at, pickup_address, dropoff_address, distance, duration_hours)
  values (v_org, v_booking, p_pickup_at, p_pickup_address, p_dropoff_address, nullif(p_distance, 0), nullif(p_hours, 0));

  select * into v_row from bookings where id = v_booking;
  insert into audit_log (org_id, action, entity, entity_id, detail)
  values (v_org, 'api_create', 'booking', v_booking, jsonb_build_object('api_client_id', p_client));
  perform public.emit_webhook_event(v_org, 'booking.created', jsonb_build_object('booking_id', v_booking, 'reference', v_row.public_code));

  return jsonb_build_object(
    'booking_id', v_row.id, 'reference', v_row.public_code, 'number', v_row.number,
    'status', v_row.status, 'currency', v_row.currency, 'total', v_row.total
  );
end $$;
revoke execute on function public.api_create_booking(uuid, text, text, text, uuid, timestamptz, text, text, numeric, numeric) from public;
grant execute on function public.api_create_booking(uuid, text, text, text, uuid, timestamptz, text, text, numeric, numeric) to service_role;

create function public.api_modify_booking(
  p_client uuid, p_booking uuid, p_pickup_at timestamptz default null,
  p_pickup_address text default null, p_dropoff_address text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_trip trips;
begin
  select org_id into v_org from bookings where id = p_booking and created_via_api_client_id = p_client;
  if v_org is null then raise exception 'booking not found for this API client' using errcode = '42501'; end if;

  select * into v_trip from trips where booking_id = p_booking order by pickup_at limit 1;
  if v_trip.id is null then raise exception 'booking has no trip to modify'; end if;
  if v_trip.status in ('on_board', 'completed', 'no_show', 'cancelled') then
    raise exception 'this trip can no longer be modified, status is %', v_trip.status;
  end if;

  update trips set
    pickup_at = coalesce(p_pickup_at, pickup_at),
    pickup_address = coalesce(p_pickup_address, pickup_address),
    dropoff_address = coalesce(p_dropoff_address, dropoff_address)
  where id = v_trip.id;

  insert into trip_events (org_id, trip_id, status) values (v_org, v_trip.id, 'modified_via_api');
  insert into audit_log (org_id, action, entity, entity_id, detail)
  values (v_org, 'api_modify', 'booking', p_booking, jsonb_build_object('api_client_id', p_client, 'trip_id', v_trip.id));
  perform public.emit_webhook_event(v_org, 'booking.modified', jsonb_build_object('booking_id', p_booking, 'trip_id', v_trip.id));

  return jsonb_build_object('booking_id', p_booking, 'trip_id', v_trip.id, 'status', 'modified');
end $$;
revoke execute on function public.api_modify_booking(uuid, uuid, timestamptz, text, text) from public;
grant execute on function public.api_modify_booking(uuid, uuid, timestamptz, text, text) to service_role;

create function public.api_cancel_booking(p_client uuid, p_booking uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_status text; t record;
begin
  select org_id, status into v_org, v_status from bookings
    where id = p_booking and created_via_api_client_id = p_client for update;
  if v_org is null then raise exception 'booking not found for this API client' using errcode = '42501'; end if;
  if v_status in ('completed', 'cancelled') then raise exception 'this booking is already %', v_status; end if;

  for t in select id, status from trips where booking_id = p_booking loop
    if t.status in ('on_board', 'completed', 'no_show') then
      raise exception 'a trip on this booking has already started';
    end if;
    if t.status <> 'cancelled' then
      update trips set status = 'cancelled' where id = t.id;
      insert into trip_events (org_id, trip_id, status) values (v_org, t.id, 'cancelled');
    end if;
  end loop;

  update bookings set status = 'cancelled' where id = p_booking;
  insert into audit_log (org_id, action, entity, entity_id, detail)
  values (v_org, 'api_cancel', 'booking', p_booking, jsonb_build_object('api_client_id', p_client, 'reason', p_reason));
  perform public.emit_webhook_event(v_org, 'booking.cancelled', jsonb_build_object('booking_id', p_booking, 'reason', p_reason));

  return jsonb_build_object('booking_id', p_booking, 'status', 'cancelled');
end $$;
revoke execute on function public.api_cancel_booking(uuid, uuid, text) from public;
grant execute on function public.api_cancel_booking(uuid, uuid, text) to service_role;

create function public.api_booking_status(p_client uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'booking_id', b.id, 'reference', b.public_code, 'status', b.status,
    'currency', b.currency, 'total', b.total, 'payment_status', b.payment_status,
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object(
        'trip_id', tr.id, 'status', tr.status, 'pickup_at', tr.pickup_at,
        'pickup_address', tr.pickup_address, 'dropoff_address', tr.dropoff_address,
        'flight_status', tr.flight_status
      ) order by tr.pickup_at)
      from trips tr where tr.booking_id = b.id
    ), '[]'::jsonb)
  )
  from bookings b
  where b.id = p_booking and b.created_via_api_client_id = p_client;
$$;
revoke execute on function public.api_booking_status(uuid, uuid) from public;
grant execute on function public.api_booking_status(uuid, uuid) to service_role;
