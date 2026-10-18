-- 0006_platform_admin: super admin for the platform owner, company status and type,
-- suspension, and protection of plan/trial fields from company owners.

-- ---------------------------------------------------------------
-- Super admins. Granted only by running SQL in Supabase (never from the app):
--   insert into platform_admins (user_id) select id from auth.users where email = 'you@example.com';
-- ---------------------------------------------------------------
create table platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table platform_admins enable row level security;
create policy self_read on platform_admins for select using (user_id = auth.uid());
grant select on platform_admins to authenticated;

create function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;
grant execute on function app.is_platform_admin() to anon, authenticated;

-- ---------------------------------------------------------------
-- Company status and type
-- ---------------------------------------------------------------
alter table orgs
  add column status text not null default 'active' check (status in ('active','suspended')),
  add column kind   text not null default 'operator' check (kind in ('operator','travel_agency')),
  add column status_reason text;

-- Super admin passes every company check. Staff of a suspended company lose access.
create or replace function app.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_platform_admin() or exists (
    select 1 from memberships m join orgs o on o.id = m.org_id
    where m.org_id = p_org and m.user_id = auth.uid() and m.active and o.status = 'active'
  );
$$;

create or replace function app.has_role(p_org uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_platform_admin() or exists (
    select 1 from memberships m join orgs o on o.id = m.org_id
    where m.org_id = p_org and m.user_id = auth.uid() and m.active and o.status = 'active'
      and m.role = any (p_roles)
  );
$$;

-- Company owners may edit their profile but not plan, trial, status, type or Stripe link.
create function app.orgs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app.is_platform_admin() or auth.uid() is null then return new; end if;
  if new.plan_id is distinct from old.plan_id
     or new.trial_ends_at is distinct from old.trial_ends_at
     or new.status is distinct from old.status
     or new.status_reason is distinct from old.status_reason
     or new.kind is distinct from old.kind
     or new.stripe_account_id is distinct from old.stripe_account_id then
    raise exception 'only the platform administrator can change plan, trial, status or account type'
      using errcode = '42501';
  end if;
  return new;
end $$;

create trigger orgs_guard before update on orgs
  for each row execute function app.orgs_guard();

-- Reference data: super admin can manage it.
create policy admin_write on plans       for all using (app.is_platform_admin()) with check (app.is_platform_admin());
create policy admin_write on currencies  for all using (app.is_platform_admin()) with check (app.is_platform_admin());
create policy admin_write on locales     for all using (app.is_platform_admin()) with check (app.is_platform_admin());
create policy admin_write on tax_presets for all using (app.is_platform_admin()) with check (app.is_platform_admin());

-- Super admin reads and edits app user profiles; full audit log.
create policy admin_all on profiles for all using (app.is_platform_admin()) with check (app.is_platform_admin());
create policy admin_read on audit_log for select using (app.is_platform_admin());

-- ---------------------------------------------------------------
-- Provisioning, shared by self sign-up and the super admin
-- ---------------------------------------------------------------
create function app.provision_org(
  p_owner uuid, p_name text, p_slug text, p_country text, p_currency text, p_locale text,
  p_timezone text, p_unit_system text, p_clock_24h boolean, p_tax_preset text, p_kind text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_class uuid; r record;
begin
  if p_kind not in ('operator','travel_agency') then raise exception 'invalid account type %', p_kind; end if;

  insert into profiles (id) values (p_owner) on conflict do nothing;

  insert into orgs (name, slug, country, timezone, default_currency, default_locale,
                    unit_system, clock_24h, plan_id, trial_ends_at, kind)
  values (p_name, p_slug, p_country, p_timezone, p_currency, p_locale,
          p_unit_system, p_clock_24h, 'starter', now() + interval '14 days', p_kind)
  returning id into v_org;

  insert into memberships (org_id, user_id, role) values (v_org, p_owner, 'owner');

  insert into tax_rates (org_id, code, label, rate, kind, is_default)
  select v_org, code, label, rate, kind, (code = p_tax_preset)
  from tax_presets where country = p_country;

  if not exists (select 1 from tax_rates where org_id = v_org and is_default) then
    insert into tax_rates (org_id, code, label, rate, kind, is_default)
    values (v_org, 'NONE', 'No tax', 0, 'NONE', true)
    on conflict (org_id, code) do update set is_default = true;
  end if;

  -- Operators get a starter fleet and prices. Travel agencies do not run cars.
  if p_kind = 'operator' then
    for r in select * from (values
      ('Sedan', 3, 2, 1.0, 1), ('SUV', 6, 4, 1.4, 2), ('Van', 10, 8, 2.0, 3)
    ) as t(name, seats, luggage, mult, ord)
    loop
      insert into vehicle_classes (org_id, name, seats, luggage, sort_order)
      values (v_org, r.name, r.seats, r.luggage, r.ord) returning id into v_class;

      insert into rate_cards (org_id, class_id, service_type, currency, base_amount, per_distance, per_hour, minimum_amount)
      values
        (v_org, v_class, 'one_way', p_currency, round(60 * r.mult, 2), round(2 * r.mult, 2), 0, round(80 * r.mult, 2)),
        (v_org, v_class, 'hourly',  p_currency, 0, 0, round(75 * r.mult, 2), round(150 * r.mult, 2));
    end loop;
  end if;

  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (v_org, auth.uid(), 'create', 'org', v_org, jsonb_build_object('kind', p_kind, 'owner', p_owner));
  return v_org;
end $$;

-- Self sign-up now also takes the account type (operator or travel agency).
drop function public.create_operator(text,text,text,text,text,text,text,boolean,text);
create function public.create_operator(
  p_name text, p_slug text, p_country text, p_currency text, p_locale text,
  p_timezone text default 'UTC', p_unit_system text default 'metric',
  p_clock_24h boolean default true, p_tax_preset text default null,
  p_kind text default 'operator'
) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return app.provision_org(auth.uid(), p_name, p_slug, p_country, p_currency, p_locale,
                           p_timezone, p_unit_system, p_clock_24h, p_tax_preset, p_kind);
end $$;
grant execute on function public.create_operator(text,text,text,text,text,text,text,boolean,text,text) to authenticated;

-- ---------------------------------------------------------------
-- Suspended companies disappear from the public portal and the network
-- ---------------------------------------------------------------
create or replace function public.public_operator(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'name', o.name, 'slug', o.slug, 'country', o.country, 'timezone', o.timezone,
    'currency', o.default_currency, 'locale', o.default_locale,
    'unit_system', o.unit_system, 'clock_24h', o.clock_24h,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'seats', c.seats, 'luggage', c.luggage)
                       order by c.sort_order, c.name)
      from vehicle_classes c where c.org_id = o.id), '[]'::jsonb))
  from orgs o where o.slug = p_slug and o.status = 'active' and o.kind = 'operator';
$$;

create or replace function public.network_directory() returns table (id uuid, name text, slug text, country text)
language sql stable security definer set search_path = public as $$
  select id, name, slug, country from orgs
  where listed_in_network and status = 'active' and kind = 'operator' order by name;
$$;

create function app.require_active_org() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app.is_platform_admin() then return new; end if;
  if (select status from orgs where id = new.org_id) <> 'active' then
    raise exception 'this company account is suspended' using errcode = '42501';
  end if;
  return new;
end $$;

-- Blocks new bookings for a suspended company from any path (portal or staff).
create trigger bookings_active_org before insert on bookings
  for each row execute function app.require_active_org();

-- ---------------------------------------------------------------
-- Super admin functions. All raise for anyone else.
-- ---------------------------------------------------------------
create function app.require_platform_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_platform_admin() then
    raise exception 'platform administrators only' using errcode = '42501';
  end if;
end $$;

-- Headline numbers for the admin home page.
create function public.platform_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform app.require_platform_admin();
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
    'booking_value_30d', coalesce((
      select jsonb_object_agg(currency, total) from (
        select currency, sum(total) total from bookings
        where created_at > now() - interval '30 days' and status <> 'cancelled' group by currency) s), '{}'::jsonb),
    'unassigned_next_24h', (select count(*) from trips where status = 'unassigned'
                            and pickup_at between now() and now() + interval '24 hours'),
    'requests_waiting_1h', (select count(*) from bookings where status = 'quoted'
                            and created_at < now() - interval '1 hour'),
    'expired_documents', (select count(*) from driver_documents dd join drivers d on d.id = dd.driver_id
                          where d.active and dd.expires_on < current_date)
  ) into v;
  return v;
end $$;

-- Every company with its key facts.
create function public.platform_companies()
returns table (
  id uuid, name text, slug text, kind text, status text, status_reason text, country text,
  default_currency text, plan_id text, trial_ends_at timestamptz, created_at timestamptz,
  owner_email text, staff_count bigint, driver_count bigint, vehicle_count bigint,
  bookings_30d bigint, last_booking_at timestamptz
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
         (select max(b.created_at) from bookings b where b.org_id = o.id)
  from orgs o
  order by o.created_at desc;
end $$;

-- Every user account with their company memberships.
create function public.platform_users(p_search text default null)
returns table (user_id uuid, email text, full_name text, created_at timestamptz,
               last_sign_in_at timestamptz, is_platform_admin boolean, memberships jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return query
  select u.id, u.email::text, p.full_name, u.created_at, u.last_sign_in_at,
         exists (select 1 from platform_admins a where a.user_id = u.id),
         coalesce((select jsonb_agg(jsonb_build_object(
                     'membership_id', m.id, 'org_id', m.org_id, 'org_name', o.name,
                     'role', m.role, 'active', m.active) order by o.name)
                   from memberships m join orgs o on o.id = m.org_id where m.user_id = u.id), '[]'::jsonb)
  from auth.users u left join profiles p on p.id = u.id
  where p_search is null or p_search = ''
     or u.email ilike '%' || p_search || '%' or p.full_name ilike '%' || p_search || '%'
  order by u.created_at desc
  limit 500;
end $$;

-- Create a company on behalf of someone who already has an account.
create function public.platform_create_company(
  p_owner_email text, p_name text, p_slug text, p_country text, p_currency text, p_locale text,
  p_timezone text default 'UTC', p_unit_system text default 'metric', p_clock_24h boolean default true,
  p_tax_preset text default null, p_kind text default 'operator'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_org uuid;
begin
  perform app.require_platform_admin();
  select id into v_owner from auth.users where lower(email) = lower(trim(p_owner_email));
  if v_owner is null then
    return jsonb_build_object('result', 'no_account');
  end if;
  v_org := app.provision_org(v_owner, p_name, p_slug, p_country, p_currency, p_locale,
                             p_timezone, p_unit_system, p_clock_24h, p_tax_preset, p_kind);
  return jsonb_build_object('result', 'created', 'org_id', v_org);
end $$;

-- Suspend or reactivate a company, with a reason. Logged.
create function public.platform_set_company_status(p_org uuid, p_status text, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_status not in ('active','suspended') then raise exception 'invalid status %', p_status; end if;
  update orgs set status = p_status, status_reason = case when p_status = 'active' then null else p_reason end
   where id = p_org;
  if not found then raise exception 'company not found'; end if;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'platform_set_status', 'org', p_org,
          jsonb_build_object('status', p_status, 'reason', p_reason));
end $$;

-- Change plan and trial end. Logged.
create function public.platform_set_company_plan(p_org uuid, p_plan text, p_trial_ends_at timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  update orgs set plan_id = p_plan, trial_ends_at = p_trial_ends_at where id = p_org;
  if not found then raise exception 'company not found'; end if;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'platform_set_plan', 'org', p_org,
          jsonb_build_object('plan', p_plan, 'trial_ends_at', p_trial_ends_at));
end $$;

-- Platform-wide audit feed with company names and actor emails.
create function public.platform_audit(p_limit int default 200, p_org uuid default null)
returns table (id bigint, created_at timestamptz, org_id uuid, org_name text, actor_email text,
               action text, entity text, entity_id uuid, detail jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return query
  select a.id, a.created_at, a.org_id, o.name, u.email::text, a.action, a.entity, a.entity_id, a.detail
  from audit_log a left join orgs o on o.id = a.org_id left join auth.users u on u.id = a.actor_id
  where p_org is null or a.org_id = p_org
  order by a.created_at desc
  limit least(greatest(p_limit, 1), 1000);
end $$;

-- Is the signed-in user a super admin? (for showing the Platform menu)
create function public.am_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_platform_admin();
$$;

grant execute on function public.platform_overview() to authenticated;
grant execute on function public.platform_companies() to authenticated;
grant execute on function public.platform_users(text) to authenticated;
grant execute on function public.platform_create_company(text,text,text,text,text,text,text,text,boolean,text,text) to authenticated;
grant execute on function public.platform_set_company_status(uuid,text,text) to authenticated;
grant execute on function public.platform_set_company_plan(uuid,text,timestamptz) to authenticated;
grant execute on function public.platform_audit(int,uuid) to authenticated;
grant execute on function public.am_platform_admin() to authenticated;

-- Internal only: callable from the functions above, never directly by app users.
revoke execute on function app.provision_org(uuid,text,text,text,text,text,text,text,boolean,text,text) from public, anon, authenticated;
