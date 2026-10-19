-- 0015_currency_fx: platform-wide USD reporting on top of each company's own billing currency.
--
-- Each operator and travel agency keeps pricing, invoicing and quoting in its own currency
-- (default_currency, set once at signup) — that does not change here. What was missing:
-- 1. farm_outs.partner_price had NO currency at all. When one org hands a trip to another
--    (e.g. a France-based travel agency billing in EUR farming a trip to a USD operator),
--    that price was an ambiguous bare number. It is now tagged with the currency it was
--    actually agreed in (the originating org's).
-- 2. There was no way to see a combined, single-currency total across companies that bill
--    in different currencies — platform_overview's booking_value_30d was already correctly
--    grouped by currency (never summed across currencies, which would have been meaningless),
--    but there was no converted total alongside it.
-- 3. A company's currency could only ever be set once, at signup, with no admin path to
--    change it afterward.

-- ---------------------------------------------------------------
-- Admin-maintained exchange rates
-- ---------------------------------------------------------------
create table fx_rates (
  currency_code text primary key references currencies(code),
  rate_to_usd   numeric(14,6) not null check (rate_to_usd > 0),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id)
);
-- Starting rates (platform admin edits these on Reference data > Exchange rates); USD is fixed at 1.
insert into fx_rates (currency_code, rate_to_usd)
  select code, case code when 'USD' then 1 when 'CAD' then 0.73 when 'EUR' then 1.08 when 'GBP' then 1.27 else 1 end
  from currencies
  on conflict do nothing;

alter table fx_rates enable row level security;
create policy fx_read  on fx_rates for select using (auth.uid() is not null);
create policy fx_write on fx_rates for all using (app.is_platform_admin()) with check (app.is_platform_admin());

create function public.to_usd(p_currency text, p_amount numeric) returns numeric
language sql stable as $$
  select round(coalesce(p_amount, 0) * coalesce((select rate_to_usd from fx_rates where currency_code = p_currency), 1), 2);
$$;
grant execute on function public.to_usd(text, numeric) to authenticated;

create function public.set_fx_rate(p_currency text, p_rate numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_rate <= 0 then raise exception 'rate must be positive'; end if;
  if not exists (select 1 from currencies where code = p_currency) then raise exception 'unknown currency %', p_currency; end if;
  insert into fx_rates (currency_code, rate_to_usd, updated_at, updated_by)
  values (p_currency, p_rate, now(), auth.uid())
  on conflict (currency_code) do update set rate_to_usd = excluded.rate_to_usd, updated_at = now(), updated_by = auth.uid();
  insert into audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), 'set_fx_rate', 'fx_rate', null, jsonb_build_object('currency', p_currency, 'rate_to_usd', p_rate));
end $$;
grant execute on function public.set_fx_rate(text, numeric) to authenticated;

-- ---------------------------------------------------------------
-- farm_outs: tag the price with the currency it was actually agreed in
-- ---------------------------------------------------------------
alter table farm_outs add column currency text references currencies(code);
update farm_outs fo set currency = o.default_currency from orgs o where o.id = fo.from_org_id and fo.currency is null;
alter table farm_outs alter column currency set not null;

-- farm_outs rows are inserted directly against the table (no RPC), so a trigger stamps the
-- currency server-side when the frontend does not set one, rather than trusting the client.
create function app.stamp_farm_out_currency() returns trigger
language plpgsql as $$
begin
  if new.currency is null then
    select default_currency into new.currency from orgs where id = new.from_org_id;
  end if;
  return new;
end $$;
create trigger farm_out_currency before insert on farm_outs
  for each row execute function app.stamp_farm_out_currency();

-- ---------------------------------------------------------------
-- Platform admin: change a company's currency after signup
-- ---------------------------------------------------------------
-- This relabels future pricing only. It does not retroactively convert existing rate cards,
-- zone rates, invoices or pay runs — those stay in their original numbers under the old code
-- until the operator updates them. The UI must say this plainly before the change is made.
create function public.platform_set_org_currency(p_org uuid, p_currency text) returns void
language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  perform app.require_platform_admin();
  if not exists (select 1 from currencies where code = p_currency) then raise exception 'unknown currency %', p_currency; end if;
  select default_currency into v_old from orgs where id = p_org;
  if not found then raise exception 'company not found'; end if;
  update orgs set default_currency = p_currency where id = p_org;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'platform_set_currency', 'org', p_org,
          jsonb_build_object('from', v_old, 'to', p_currency));
end $$;
grant execute on function public.platform_set_org_currency(uuid, text) to authenticated;

-- ---------------------------------------------------------------
-- Extend platform_overview and platform_companies with USD-converted totals
-- ---------------------------------------------------------------
create or replace function public.platform_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_value_by_currency jsonb;
begin
  perform app.require_platform_admin();
  v_value_by_currency := coalesce((
    select jsonb_object_agg(currency, total) from (
      select currency, sum(total) total from bookings
      where created_at > now() - interval '30 days' and status <> 'cancelled' group by currency) s), '{}'::jsonb);
  select jsonb_build_object(
    'companies', (select count(*) from orgs),
    'operators', (select count(*) from orgs where kind = 'operator'),
    'travel_agencies', (select count(*) from orgs where kind = 'travel_agency'),
    'suspended', (select count(*) from orgs where status = 'suspended'),
    'in_trial', (select count(*) from orgs where trial_ends_at > now()),
    'trials_ending_7d', (select count(*) from orgs where trial_ends_at between now() and now() + interval '7 days'),
    'users', (select count(*) from auth.users),
    'drivers', (select count(*) from drivers where active),
    'signups_30d', (select count(*) from orgs where created_at > now() - interval '30 days'),
    'bookings_today', (select count(*) from bookings where created_at::date = now()::date),
    'bookings_30d', (select count(*) from bookings where created_at > now() - interval '30 days'),
    'booking_value_30d', v_value_by_currency,
    'booking_value_30d_usd', (
      select coalesce(sum(public.to_usd(key, value::numeric)), 0)
      from jsonb_each_text(v_value_by_currency)),
    'unassigned_next_24h', (select count(*) from trips where status = 'unassigned'
                            and pickup_at between now() and now() + interval '24 hours'),
    'requests_waiting_1h', (select count(*) from bookings where status = 'quoted'
                            and created_at < now() - interval '1 hour'),
    'expired_documents', (select count(*) from driver_documents dd join drivers d on d.id = dd.driver_id
                          where d.active and dd.expires_on < current_date)
  ) into v;
  return v;
end $$;

-- Adding a column changes the return type, which create-or-replace cannot do for a table function.
drop function public.platform_companies();
create function public.platform_companies()
returns table (
  id uuid, name text, slug text, kind text, status text, status_reason text, country text,
  default_currency text, plan_id text, trial_ends_at timestamptz, created_at timestamptz,
  owner_email text, staff_count bigint, driver_count bigint, vehicle_count bigint,
  bookings_30d bigint, last_booking_at timestamptz, revenue_30d_usd numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return query
  select o.id, o.name, o.slug, o.kind, o.status, o.status_reason, o.country, o.default_currency,
         o.plan_id, o.trial_ends_at, o.created_at,
         (select u.email::text from memberships m join auth.users u on u.id = m.user_id
           where m.org_id = o.id and m.role = 'owner' order by m.created_at limit 1),
         (select count(*) from memberships m where m.org_id = o.id and m.active and m.role in ('owner','admin','dispatcher')),
         (select count(*) from drivers d where d.org_id = o.id and d.active),
         (select count(*) from vehicles v where v.org_id = o.id and v.active),
         (select count(*) from bookings b where b.org_id = o.id and b.created_at > now() - interval '30 days'),
         (select max(b.created_at) from bookings b where b.org_id = o.id),
         public.to_usd(o.default_currency, (select coalesce(sum(b.total), 0) from bookings b
            where b.org_id = o.id and b.created_at > now() - interval '30 days' and b.status <> 'cancelled'))
  from orgs o
  order by o.created_at desc;
end $$;

grant execute on function public.platform_overview() to authenticated;
grant execute on function public.platform_companies() to authenticated;
