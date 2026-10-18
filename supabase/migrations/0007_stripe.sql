-- 0007_stripe: card payments through Stripe Connect.
-- Each operator connects its own Stripe account; customers pay the operator directly
-- (direct charges). The platform may take an application fee (default 0).

alter table orgs
  add column stripe_charges_enabled   boolean not null default false,
  add column stripe_details_submitted boolean not null default false,
  add column deposit_percent          numeric(5,2) not null default 0
    check (deposit_percent >= 0 and deposit_percent <= 100);

-- The Stripe flags are written only by the server; extend the owner guard.
create or replace function app.orgs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app.is_platform_admin() or auth.uid() is null then return new; end if;
  if new.plan_id is distinct from old.plan_id
     or new.trial_ends_at is distinct from old.trial_ends_at
     or new.status is distinct from old.status
     or new.status_reason is distinct from old.status_reason
     or new.kind is distinct from old.kind
     or new.stripe_account_id is distinct from old.stripe_account_id
     or new.stripe_charges_enabled is distinct from old.stripe_charges_enabled
     or new.stripe_details_submitted is distinct from old.stripe_details_submitted then
    raise exception 'only the platform administrator can change plan, trial, status, account type or payment connection'
      using errcode = '42501';
  end if;
  return new;
end $$;

alter table payments
  add column kind text not null default 'manual' check (kind in ('deposit','balance','manual')),
  add column checkout_url text,
  add column payment_intent text,
  add column application_fee numeric(12,2) not null default 0,
  add column updated_at timestamptz not null default now();

create unique index payments_provider_ref_uniq on payments (provider, provider_ref) where provider_ref is not null;

-- Platform-wide settings (one row). Fee in basis points: 100 = 1%.
create table platform_settings (
  id               boolean primary key default true check (id),
  platform_fee_bps integer not null default 0 check (platform_fee_bps between 0 and 2000),
  updated_at       timestamptz not null default now()
);
insert into platform_settings (id) values (true);
alter table platform_settings enable row level security;
create policy admin_all on platform_settings for all
  using (app.is_platform_admin()) with check (app.is_platform_admin());
grant select, update on platform_settings to authenticated;

-- Amount still owed and the deposit due, for the payment screens.
create function public.booking_amount_due(p_booking uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'currency', b.currency,
    'total', b.total,
    'paid', b.paid_amount,
    'balance', greatest(b.total - b.paid_amount, 0),
    'deposit_due', greatest(round(b.total * o.deposit_percent / 100, 2) - b.paid_amount, 0),
    'deposit_percent', o.deposit_percent,
    'card_payments_ready', o.stripe_charges_enabled)
  from bookings b join orgs o on o.id = b.org_id
  where b.id = p_booking;
$$;
grant execute on function public.booking_amount_due(uuid) to authenticated;

-- Public status page also shows whether card payment is available and what is owed.
create or replace function public.public_booking_status(p_slug text, p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'public_code', b.public_code, 'status', b.status, 'payment_status', b.payment_status,
    'total', b.total, 'paid', b.paid_amount, 'balance', greatest(b.total - b.paid_amount, 0),
    'deposit_due', greatest(round(b.total * o.deposit_percent / 100, 2) - b.paid_amount, 0),
    'card_payments_ready', o.stripe_charges_enabled and o.status = 'active',
    'currency', b.currency, 'passenger_name', b.passenger_name,
    'pickup_at', t.pickup_at, 'pickup_address', t.pickup_address, 'dropoff_address', t.dropoff_address,
    'trip_status', t.status)
  from bookings b
  join orgs o on o.id = b.org_id
  join lateral (select * from trips where booking_id = b.id order by pickup_at limit 1) t on true
  where o.slug = p_slug and b.public_code = p_code;
$$;

-- Recompute paid amount whenever a payment row changes status (already handled by
-- payments_totals trigger from 0003, which counts status = 'succeeded').
