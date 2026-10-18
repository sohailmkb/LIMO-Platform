-- 0001_core: tenants, plans, memberships, locale, currency, tax, access helpers.
-- Target: Supabase Postgres. No extensions required (PostGIS moves to week 2).

create table plans (
  id            text primary key,
  name          text not null,
  seat_limit    integer,                  -- null = unlimited
  features      jsonb not null default '{}'::jsonb,
  sort_order    integer not null default 0
);

create table currencies (
  code        text primary key,           -- ISO 4217
  symbol      text not null,
  minor_unit  integer not null default 2
);

create table locales (
  code    text primary key,               -- BCP 47: en, fr, es, de, it
  name    text not null,
  status  text not null default 'review' check (status in ('live', 'review'))
);

-- Global starting points an operator copies into its own tax_rates on sign-up.
create table tax_presets (
  code          text primary key,         -- e.g. CA-ON-HST
  country       text not null,            -- ISO 3166-1 alpha-2
  region        text,
  label         text not null,
  rate          numeric(7,4) not null check (rate >= 0 and rate < 1),
  kind          text not null check (kind in ('VAT','GST','HST','SALES_TAX','NONE'))
);

create table orgs (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  slug                text not null unique,
  country             text not null,
  timezone            text not null default 'UTC',
  default_currency    text not null references currencies(code),
  default_locale      text not null references locales(code),
  unit_system         text not null default 'metric' check (unit_system in ('metric', 'imperial')),
  clock_24h           boolean not null default true,
  plan_id             text not null references plans(id),
  trial_ends_at       timestamptz,
  stripe_account_id   text,
  listed_in_network   boolean not null default true,
  created_at          timestamptz not null default now()
);

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  locale      text references locales(code),
  created_at  timestamptz not null default now()
);

-- One user can belong to several orgs (a driver working for two operators).
create table memberships (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null check (role in ('owner','admin','dispatcher','driver','customer')),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (org_id, user_id, role)
);
create index memberships_user_idx on memberships (user_id) where active;

create table tax_rates (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  code        text not null,
  label       text not null,
  rate        numeric(7,4) not null check (rate >= 0 and rate < 1),
  kind        text not null check (kind in ('VAT','GST','HST','SALES_TAX','NONE')),
  is_default  boolean not null default false,
  unique (org_id, code)
);
create unique index tax_rates_one_default on tax_rates (org_id) where is_default;

create table audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid references orgs(id) on delete cascade,
  actor_id    uuid,
  action      text not null,
  entity      text not null,
  entity_id   uuid,
  detail      jsonb,
  created_at  timestamptz not null default now()
);

-- Access helpers. SECURITY DEFINER so policies can read memberships
-- without recursing into the memberships policy itself.
create schema if not exists app;

create function app.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from memberships m
    where m.org_id = p_org and m.user_id = auth.uid() and m.active
  );
$$;

create function app.has_role(p_org uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from memberships m
    where m.org_id = p_org and m.user_id = auth.uid() and m.active
      and m.role = any (p_roles)
  );
$$;

create function app.is_staff(p_org uuid) returns boolean
language sql stable as $$
  select app.has_role(p_org, array['owner','admin','dispatcher']);
$$;
