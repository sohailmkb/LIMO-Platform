-- 0002_operations: fleet, people, pricing, bookings, trips, payments, network.
-- A booking is the order and the bill. A trip is one car movement.

create table vehicle_classes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null,
  seats       integer not null check (seats > 0),
  luggage     integer not null default 0,
  sort_order  integer not null default 0,
  unique (org_id, name)
);

create table vehicles (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  class_id    uuid not null references vehicle_classes(id),
  label       text not null,
  plate       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table drivers (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  user_id       uuid references auth.users(id) on delete set null,
  full_name     text not null,
  phone         text,
  status        text not null default 'offline' check (status in ('offline','available','busy')),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);
create index drivers_user_idx on drivers (user_id);

create table driver_documents (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  driver_id   uuid not null references drivers(id) on delete cascade,
  kind        text not null,                 -- licence, insurance, inspection
  expires_on  date not null
);

create table accounts (                      -- corporate clients
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table contacts (                      -- bookers and passengers
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  account_id  uuid references accounts(id) on delete set null,
  user_id     uuid references auth.users(id) on delete set null,
  full_name   text not null,
  email       text,
  phone       text,
  created_at  timestamptz not null default now()
);
create index contacts_user_idx on contacts (user_id);

create table rate_cards (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  class_id         uuid not null references vehicle_classes(id) on delete cascade,
  service_type     text not null check (service_type in ('one_way','hourly')),
  currency         text not null references currencies(code),
  base_amount      numeric(12,2) not null default 0,
  per_distance     numeric(12,2) not null default 0,   -- per km or per mile, follows org unit_system
  per_hour         numeric(12,2) not null default 0,
  minimum_amount   numeric(12,2) not null default 0,
  unique (org_id, class_id, service_type, currency)
);

create table surcharges (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  name          text not null,
  amount_type   text not null check (amount_type in ('fixed','percent')),
  amount        numeric(12,4) not null,
  active        boolean not null default true
);

create table bookings (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  number           bigint generated always as identity,
  public_code      text not null default substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
  booker_id        uuid references contacts(id),
  account_id       uuid references accounts(id),
  passenger_name   text not null,
  passenger_phone  text,
  service_type     text not null check (service_type in ('one_way','hourly')),
  class_id         uuid not null references vehicle_classes(id),
  status           text not null default 'quoted'
                   check (status in ('quoted','confirmed','in_progress','completed','cancelled')),
  currency         text not null references currencies(code),
  subtotal         numeric(12,2) not null default 0,
  tax_total        numeric(12,2) not null default 0,
  total            numeric(12,2) not null default 0,
  paid_amount      numeric(12,2) not null default 0,
  payment_status   text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid','refunded')),
  created_at       timestamptz not null default now(),
  unique (org_id, public_code)
);
create index bookings_org_created_idx on bookings (org_id, created_at desc);
create index bookings_booker_idx on bookings (booker_id);

create table booking_lines (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  booking_id    uuid not null references bookings(id) on delete cascade,
  kind          text not null check (kind in ('fare','surcharge','extra','tip')),
  description   text not null,
  amount        numeric(12,2) not null,
  tax_rate_id   uuid references tax_rates(id),
  tax_amount    numeric(12,2) not null default 0
);
create index booking_lines_booking_idx on booking_lines (booking_id);

create table trips (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  booking_id     uuid not null references bookings(id) on delete cascade,
  pickup_at      timestamptz not null,
  pickup_address text not null,
  pickup_lat     numeric(9,6),
  pickup_lng     numeric(9,6),
  dropoff_address text,
  dropoff_lat    numeric(9,6),
  dropoff_lng    numeric(9,6),
  distance       numeric(10,2),              -- in org unit_system
  duration_hours numeric(6,2),
  vehicle_id     uuid references vehicles(id),
  driver_id      uuid references drivers(id),
  status         text not null default 'unassigned'
                 check (status in ('unassigned','offered','assigned','en_route','arrived','on_board','completed','no_show','cancelled')),
  created_at     timestamptz not null default now()
);
create index trips_org_pickup_idx on trips (org_id, pickup_at);
create index trips_driver_idx on trips (driver_id, pickup_at);

-- Staff-only money: never exposed to drivers or customers.
create table trip_costs (
  trip_id        uuid primary key references trips(id) on delete cascade,
  org_id         uuid not null references orgs(id) on delete cascade,
  driver_pay     numeric(12,2) not null default 0,
  partner_cost   numeric(12,2) not null default 0
);

create table trip_events (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references orgs(id) on delete cascade,
  trip_id     uuid not null references trips(id) on delete cascade,
  status      text not null,
  actor_id    uuid,
  lat         numeric(9,6),
  lng         numeric(9,6),
  created_at  timestamptz not null default now()
);
create index trip_events_trip_idx on trip_events (trip_id, created_at);

create table driver_locations (
  driver_id   uuid primary key references drivers(id) on delete cascade,
  org_id      uuid not null references orgs(id) on delete cascade,
  lat         numeric(9,6) not null,
  lng         numeric(9,6) not null,
  updated_at  timestamptz not null default now()
);

create table payments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  booking_id    uuid not null references bookings(id) on delete cascade,
  provider      text not null default 'stripe',
  provider_ref  text,
  amount        numeric(12,2) not null,
  currency      text not null references currencies(code),
  status        text not null default 'pending' check (status in ('pending','succeeded','failed','refunded')),
  created_at    timestamptz not null default now()
);

-- Open farm-out network between operators.
create table farm_outs (
  id             uuid primary key default gen_random_uuid(),
  from_org_id    uuid not null references orgs(id) on delete cascade,
  to_org_id      uuid not null references orgs(id) on delete cascade,
  trip_id        uuid not null references trips(id) on delete cascade,
  partner_price  numeric(12,2),
  status         text not null default 'offered' check (status in ('offered','accepted','declined','cancelled')),
  created_at     timestamptz not null default now(),
  check (from_org_id <> to_org_id)
);
