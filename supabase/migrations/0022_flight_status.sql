-- 0022_flight_status: flight monitoring, the one MVP module the master spec lists
-- (Section 27's own module list: "...flight monitoring...") that was never built. The
-- platform already captures flight_number/airline per trip (0010_booking_depth.sql) but
-- nothing tracks whether that flight is on time, so the data has never been actionable.
--
-- Deliberately staff-entered for now, not pulled from a live provider: a flight-data API
-- (AeroDataBox, FlightAware, etc.) is a new paid account and a new edge function, the same
-- kind of provider decision A3/A4 are already blocked on, and shouldn't block this slice.
-- The columns and UI are provider-agnostic either way -- a future edge function would write
-- to the exact same fields a dispatcher can already update by hand, nothing to migrate
-- later. flight_updated_by distinguishes a manual staff update from a future automated one
-- (null once a system writes it; a future column addition, not needed yet).
--
-- No new table, no new RPC: trips already has a staff_all RLS policy covering these columns
-- like every other trip field.

alter table trips
  add column flight_status text not null default 'unknown'
    check (flight_status in ('unknown', 'on_time', 'delayed', 'cancelled', 'diverted', 'landed', 'departed')),
  add column flight_scheduled_at timestamptz,
  add column flight_estimated_at timestamptz,
  add column flight_actual_at timestamptz,
  add column flight_updated_at timestamptz,
  add column flight_updated_by uuid references auth.users(id);
comment on column trips.flight_status is 'Staff-entered for now. unknown is the default for a trip with no flight_number, or one whose status hasn''t been checked yet.';
comment on column trips.flight_scheduled_at is 'The flight''s originally scheduled arrival/departure time, as published -- not this trip''s pickup_at, which the operator set independently and is never auto-changed by this data.';
comment on column trips.flight_estimated_at is 'Current estimated time, if different from scheduled. Null when not delayed or not yet checked.';
comment on column trips.flight_updated_at is 'When flight_status (or either time) was last set, so stale entries can be told apart from current ones in the UI.';

create index trips_flight_watch_idx on trips (org_id, pickup_at)
  where flight_number is not null and flight_status not in ('landed', 'departed', 'cancelled');
