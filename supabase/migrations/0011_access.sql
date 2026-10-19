-- 0011_access: users and access management.
-- One model for every portal:
--   Platform console  : platform owner, platform admin            (platform_admins)
--   Operator console  : owner, admin, dispatcher, accountant      (memberships on an operator)
--   Agency (OTA)      : owner, admin, dispatcher ("agent"), accountant (memberships on a travel agency)
--   Corporate client  : client_admin (all company trips), client_booker (own trips)  (memberships + account)
--   Direct customer   : customer                                   (memberships, linked by email)
--   Driver            : driver                                     (memberships + drivers row, phone app)
-- People are invited by email. An invitation is accepted automatically when someone signs in with
-- that email, whether the account existed before or not. Invites can also be accepted from a link.

-- ---------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------
alter table memberships drop constraint memberships_role_check;
alter table memberships add constraint memberships_role_check
  check (role in ('owner','admin','dispatcher','accountant','driver','customer','client_admin','client_booker'));
alter table memberships add column account_id uuid references accounts(id) on delete cascade;
alter table memberships add constraint memberships_client_account
  check ((role in ('client_admin','client_booker')) = (account_id is not null));

alter table platform_admins add column role text not null default 'owner' check (role in ('owner','admin'));

-- Corporate client settings
alter table accounts
  add column billing_email text,
  add column auto_confirm boolean not null default false,     -- client bookings skip the quote step
  add column active boolean not null default true;

-- Platform-wide suspension of a person (separate table so people cannot lift their own).
create table user_suspensions (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  reason     text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table user_suspensions enable row level security;

create function app.is_suspended() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_suspensions where user_id = auth.uid());
$$;
grant execute on function app.is_suspended() to anon, authenticated;

create policy admin_all on user_suspensions for all using (app.is_platform_admin()) with check (app.is_platform_admin());
create policy self_read on user_suspensions for select using (user_id = auth.uid());

-- Suspended people lose every access, including platform access.
create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid())
     and not exists (select 1 from user_suspensions where user_id = auth.uid());
$$;

create function app.is_platform_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid() and role = 'owner')
     and not exists (select 1 from user_suspensions where user_id = auth.uid());
$$;
grant execute on function app.is_platform_owner() to authenticated;

create or replace function app.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_platform_admin() or (not app.is_suspended() and exists (
    select 1 from memberships m join orgs o on o.id = m.org_id
    where m.org_id = p_org and m.user_id = auth.uid() and m.active and o.status = 'active'
  ));
$$;

create or replace function app.has_role(p_org uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_platform_admin() or (not app.is_suspended() and exists (
    select 1 from memberships m join orgs o on o.id = m.org_id
    where m.org_id = p_org and m.user_id = auth.uid() and m.active and o.status = 'active'
      and m.role = any (p_roles)
  ));
$$;

-- Customers and drivers keep working through these too, so suspension applies to them.
create or replace function app.owns_contact(p_contact uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.is_suspended() and exists (select 1 from contacts c where c.id = p_contact and c.user_id = auth.uid());
$$;

-- Finance: owners, admins and accountants.
create function app.is_finance(p_org uuid) returns boolean
language sql stable as $$
  select app.has_role(p_org, array['owner','admin','accountant']);
$$;

-- Corporate client admin of the account a booking is billed to.
create function app.is_account_admin(p_account uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_account is not null and not app.is_suspended() and exists (
    select 1 from memberships m join orgs o on o.id = m.org_id
    where m.account_id = p_account and m.user_id = auth.uid() and m.active
      and m.role = 'client_admin' and o.status = 'active');
$$;

create function app.sees_booking(p_booking uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bookings b where b.id = p_booking
                 and (app.owns_contact(b.booker_id) or app.is_account_admin(b.account_id)));
$$;

-- Accountants read the money side; they cannot dispatch, change prices, settings or team.
create policy finance_read on bookings      for select using (app.is_finance(org_id));
create policy finance_read on booking_lines for select using (app.is_finance(org_id));
create policy finance_read on trips         for select using (app.is_finance(org_id));
create policy finance_read on payments      for select using (app.is_finance(org_id));
create policy finance_add  on payments      for insert with check (app.is_finance(org_id));
create policy finance_read on trip_costs    for select using (app.is_finance(org_id));
create policy finance_read on contacts      for select using (app.is_finance(org_id));
create policy finance_read on accounts      for select using (app.is_finance(org_id));
create policy finance_read on drivers       for select using (app.is_finance(org_id));
create policy finance_read on tax_rates     for select using (app.is_finance(org_id));

-- Corporate client admins see every booking on their account.
create policy account_read on bookings      for select using (app.is_account_admin(account_id));
create policy account_read on booking_lines for select using (app.sees_booking(booking_id));
create policy account_read on trips         for select using (app.sees_booking(booking_id));
create policy account_read on trip_events   for select using (
  exists (select 1 from trips t where t.id = trip_events.trip_id and app.sees_booking(t.booking_id)));
create policy client_read on accounts for select using (
  exists (select 1 from memberships m where m.account_id = accounts.id and m.user_id = auth.uid() and m.active));

-- Owner rows are protected: only a platform admin may create, demote, deactivate or remove an owner,
-- and a company always keeps at least one active owner.
create function app.memberships_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_org uuid := coalesce(new.org_id, old.org_id);
begin
  if app.is_platform_admin() or current_setting('app.bypass_guard', true) = 'on' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  -- Cascades from deleting a company or a person are always allowed.
  if tg_op = 'DELETE' and (not exists (select 1 from orgs where id = old.org_id)
                           or not exists (select 1 from auth.users where id = old.user_id)) then
    return old;
  end if;
  -- The founder of a brand-new company becomes its first owner.
  if tg_op = 'INSERT' and new.role = 'owner'
     and exists (select 1 from memberships where org_id = new.org_id) then
    raise exception 'only the platform can add an owner' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and (old.role = 'owner' or new.role = 'owner') and old.role <> new.role then
    raise exception 'owner role cannot be changed here' using errcode = '42501';
  end if;
  if old.role = 'owner' and (tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.active and not new.active)) then
    if not exists (select 1 from memberships where org_id = v_org and role = 'owner' and active and id <> old.id) then
      raise exception 'a company needs at least one active owner';
    end if;
    if not app.has_role(v_org, array['owner']) then
      raise exception 'only an owner can change another owner' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger memberships_guard before insert or update or delete on memberships
  for each row execute function app.memberships_guard();

-- ---------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------
create table invitations (
  id           uuid primary key default gen_random_uuid(),
  token        text not null unique default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  email        text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  org_id       uuid references orgs(id) on delete cascade,          -- null: platform console
  role         text not null,
  account_id   uuid references accounts(id) on delete cascade,
  full_name    text check (length(full_name) <= 120),
  invited_by   uuid,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '14 days',
  accepted_at  timestamptz,
  accepted_by  uuid,
  revoked_at   timestamptz,
  check ((org_id is null) = (role in ('platform_owner','platform_admin'))),
  check (role in ('platform_owner','platform_admin','owner','admin','dispatcher','accountant','driver','customer','client_admin','client_booker')),
  check ((role in ('client_admin','client_booker')) = (account_id is not null))
);
create index invitations_email_open on invitations (email) where accepted_at is null and revoked_at is null;
alter table invitations enable row level security;
create policy managers_read on invitations for select using (
  app.is_platform_admin() or (org_id is not null and app.has_role(org_id, array['owner','admin'])));

-- Gives one person the access an invitation describes. Internal.
create function app.grant_invitation(p_user uuid, i invitations) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text; v_name text; v_contact uuid;
begin
  select lower(email) into v_email from auth.users where id = p_user;
  v_name := coalesce(nullif(trim(coalesce(i.full_name, '')), ''), split_part(v_email, '@', 1));
  perform set_config('app.bypass_guard', 'on', true);

  if i.org_id is null then
    insert into platform_admins (user_id, role) values (p_user, case i.role when 'platform_owner' then 'owner' else 'admin' end)
    on conflict (user_id) do update set role = case when platform_admins.role = 'owner' then 'owner' else excluded.role end;
  else
    insert into memberships (org_id, user_id, role, account_id) values (i.org_id, p_user, i.role, i.account_id)
    on conflict (org_id, user_id, role) do update set active = true, account_id = excluded.account_id;

    if i.role = 'driver' and not exists (select 1 from drivers where org_id = i.org_id and user_id = p_user) then
      insert into drivers (org_id, user_id, full_name) values (i.org_id, p_user, v_name);
    end if;

    if i.role in ('customer','client_admin','client_booker') then
      select id into v_contact from contacts where org_id = i.org_id and lower(email) = v_email
       order by (user_id = p_user) desc nulls last limit 1;
      if v_contact is null then
        insert into contacts (org_id, account_id, user_id, full_name, email)
        values (i.org_id, i.account_id, p_user, v_name, v_email);
      else
        update contacts set user_id = p_user, account_id = coalesce(i.account_id, account_id) where id = v_contact;
      end if;
    end if;
  end if;

  insert into profiles (id, full_name) values (p_user, i.full_name) on conflict (id) do nothing;
  update invitations set accepted_at = now(), accepted_by = p_user where id = i.id;
  perform set_config('app.bypass_guard', 'off', true);
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (i.org_id, p_user, 'accept_invitation', 'invitation', i.id, jsonb_build_object('role', i.role));
end $$;
revoke all on function app.grant_invitation(uuid, invitations) from public;

-- Invite someone. If they already have an account, access is granted at once ('added');
-- otherwise the invitation waits for their first sign-in ('invited').
-- Returns { status, token, invitation_id }.
create function public.invite_user(
  p_org uuid, p_email text, p_role text, p_account uuid default null, p_name text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_kind text; v_user uuid; i invitations;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'enter a valid email'; end if;

  if p_org is null then
    if p_role not in ('platform_owner','platform_admin') then raise exception 'invalid platform role'; end if;
    if not app.is_platform_owner() then raise exception 'only a platform owner can add platform admins' using errcode = '42501'; end if;
  else
    select kind into v_kind from orgs where id = p_org;
    if v_kind is null then raise exception 'company not found'; end if;
    if p_role = 'owner' then
      if not app.is_platform_admin() and not app.has_role(p_org, array['owner']) then
        raise exception 'only an owner can add another owner' using errcode = '42501';
      end if;
    elsif p_role = 'admin' then
      if not app.has_role(p_org, array['owner']) then
        raise exception 'only an owner can add an admin' using errcode = '42501';
      end if;
    elsif p_role in ('dispatcher','accountant','driver','customer','client_admin','client_booker') then
      if not app.has_role(p_org, array['owner','admin']) then
        raise exception 'only owners and admins can invite people' using errcode = '42501';
      end if;
    else
      raise exception 'invalid role %', p_role;
    end if;
    if v_kind = 'travel_agency' and p_role in ('driver','customer','client_admin','client_booker') then
      raise exception 'travel agencies have staff roles only';
    end if;
    if p_role in ('client_admin','client_booker') then
      if p_account is null or not exists (select 1 from accounts where id = p_account and org_id = p_org) then
        raise exception 'choose the client company';
      end if;
    else
      p_account := null;
    end if;
  end if;

  update invitations set revoked_at = now()
   where email = v_email and coalesce(org_id, '00000000-0000-0000-0000-000000000000') = coalesce(p_org, '00000000-0000-0000-0000-000000000000')
     and role = p_role and accepted_at is null and revoked_at is null;

  insert into invitations (email, org_id, role, account_id, full_name, invited_by)
  values (v_email, p_org, p_role, p_account, nullif(trim(coalesce(p_name, '')), ''), auth.uid())
  returning * into i;

  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'invite', 'invitation', i.id, jsonb_build_object('email', v_email, 'role', p_role));

  select id into v_user from auth.users where lower(email) = v_email;
  if v_user is not null then
    perform app.grant_invitation(v_user, i);
    return jsonb_build_object('status', 'added', 'token', i.token, 'invitation_id', i.id);
  end if;
  return jsonb_build_object('status', 'invited', 'token', i.token, 'invitation_id', i.id);
end $$;

-- Called by the app after every sign-in: accepts every open invitation for this email.
-- Returns the access granted: [{ org_id, org_name, role }].
create function public.claim_invitations() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_email text; i invitations; v_out jsonb := '[]'::jsonb;
begin
  if v_user is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if app.is_suspended() then return v_out; end if;
  select lower(email) into v_email from auth.users where id = v_user;
  for i in select * from invitations where email = v_email and accepted_at is null and revoked_at is null
             and expires_at > now() order by created_at loop
    perform app.grant_invitation(v_user, i);
    v_out := v_out || jsonb_build_object('org_id', i.org_id, 'role', i.role,
               'org_name', (select name from orgs where id = i.org_id));
  end loop;
  return v_out;
end $$;

-- What an invitation link is for, shown before signing in. Never reveals more than the email it was sent to.
create function public.invitation_preview(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'email', i.email, 'role', i.role, 'full_name', i.full_name,
    'org_name', o.name, 'org_kind', o.kind, 'account_name', a.name,
    'state', case when i.revoked_at is not null then 'revoked'
                  when i.accepted_at is not null then 'accepted'
                  when i.expires_at < now() then 'expired' else 'open' end)
  from invitations i left join orgs o on o.id = i.org_id left join accounts a on a.id = i.account_id
  where i.token = p_token and length(p_token) = 64;
$$;

create function public.revoke_invitation(p_invitation uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i invitations;
begin
  select * into i from invitations where id = p_invitation;
  if not found then raise exception 'invitation not found'; end if;
  if not (app.is_platform_admin() or (i.org_id is not null and app.has_role(i.org_id, array['owner','admin']))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update invitations set revoked_at = now() where id = p_invitation and accepted_at is null;
end $$;

-- Extend an open or expired invitation by 14 days. Returns the token for the link.
create function public.renew_invitation(p_invitation uuid) returns text
language plpgsql security definer set search_path = public as $$
declare i invitations;
begin
  select * into i from invitations where id = p_invitation;
  if not found or i.accepted_at is not null or i.revoked_at is not null then raise exception 'invitation cannot be renewed'; end if;
  if not (app.is_platform_admin() or (i.org_id is not null and app.has_role(i.org_id, array['owner','admin']))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update invitations set expires_at = now() + interval '14 days' where id = p_invitation;
  return i.token;
end $$;

-- ---------------------------------------------------------------
-- Managing people in a company
-- ---------------------------------------------------------------
-- Everyone with access to a company, plus open invitations. Owners and admins (and the platform).
create function public.org_access(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.has_role(p_org, array['owner','admin']) then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'membership_id', m.id, 'user_id', m.user_id, 'email', u.email, 'full_name', p.full_name,
        'role', m.role, 'active', m.active, 'account_id', m.account_id, 'account_name', a.name,
        'last_sign_in_at', u.last_sign_in_at, 'suspended', exists (select 1 from user_suspensions s where s.user_id = m.user_id),
        'is_me', m.user_id = auth.uid()) order by m.active desc, m.role, u.email)
      from memberships m join auth.users u on u.id = m.user_id
      left join profiles p on p.id = m.user_id left join accounts a on a.id = m.account_id
      where m.org_id = p_org), '[]'::jsonb),
    'invitations', coalesce((select jsonb_agg(jsonb_build_object(
        'invitation_id', i.id, 'email', i.email, 'full_name', i.full_name, 'role', i.role, 'account_name', a.name,
        'token', i.token, 'created_at', i.created_at, 'expires_at', i.expires_at,
        'expired', i.expires_at < now()) order by i.created_at desc)
      from invitations i left join accounts a on a.id = i.account_id
      where i.org_id = p_org and i.accepted_at is null and i.revoked_at is null), '[]'::jsonb));
end $$;

-- Change role, pause or resume, or remove. Owners and admins; owner rows are guarded by the trigger,
-- and only owners may change admins.
create function public.update_member(p_membership uuid, p_action text, p_role text default null) returns void
language plpgsql security definer set search_path = public as $$
declare m memberships;
begin
  select * into m from memberships where id = p_membership;
  if not found then raise exception 'member not found'; end if;
  if not app.has_role(m.org_id, array['owner','admin']) then raise exception 'not allowed' using errcode = '42501'; end if;
  if (m.role = 'admin' or p_role = 'admin') and not app.has_role(m.org_id, array['owner']) then
    raise exception 'only an owner can change admins' using errcode = '42501';
  end if;
  if m.user_id = auth.uid() and p_action in ('pause','remove') and not app.is_platform_admin() then
    raise exception 'you cannot remove your own access';
  end if;
  case p_action
    when 'pause'  then update memberships set active = false where id = m.id;
    when 'resume' then update memberships set active = true where id = m.id;
    when 'remove' then delete from memberships where id = m.id;
    when 'role'   then
      if p_role not in ('owner','admin','dispatcher','accountant') or m.role not in ('owner','admin','dispatcher','accountant') then
        raise exception 'role changes are for staff roles; invite again for other portals';
      end if;
      update memberships set role = p_role where id = m.id;
    else raise exception 'action must be pause, resume, remove or role';
  end case;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (m.org_id, auth.uid(), 'member_' || p_action, 'membership', m.id,
          jsonb_build_object('user_id', m.user_id, 'from', m.role, 'to', p_role));
end $$;

-- ---------------------------------------------------------------
-- Platform console
-- ---------------------------------------------------------------
drop function public.platform_users(text);
create function public.platform_users(p_search text default null)
returns table (user_id uuid, email text, full_name text, created_at timestamptz, last_sign_in_at timestamptz,
               is_platform_admin boolean, platform_role text, suspended boolean, memberships jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return query
  select u.id, u.email::text, p.full_name, u.created_at, u.last_sign_in_at,
         pa.user_id is not null, pa.role,
         exists (select 1 from user_suspensions s where s.user_id = u.id),
         coalesce((select jsonb_agg(jsonb_build_object(
                     'membership_id', m.id, 'org_id', m.org_id, 'org_name', o.name, 'org_kind', o.kind,
                     'role', m.role, 'active', m.active, 'account_name', a.name) order by o.name)
                   from memberships m join orgs o on o.id = m.org_id left join accounts a on a.id = m.account_id
                   where m.user_id = u.id), '[]'::jsonb)
  from auth.users u left join profiles p on p.id = u.id left join platform_admins pa on pa.user_id = u.id
  where p_search is null or p_search = ''
     or u.email ilike '%' || p_search || '%' or p.full_name ilike '%' || p_search || '%'
  order by u.created_at desc
  limit 500;
end $$;

-- Open invitations across the platform (platform admins).
create function public.platform_invitations() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'invitation_id', i.id, 'email', i.email, 'role', i.role, 'org_id', i.org_id, 'org_name', o.name,
      'account_name', a.name, 'token', i.token, 'created_at', i.created_at, 'expires_at', i.expires_at,
      'expired', i.expires_at < now()) order by i.created_at desc)
    from invitations i left join orgs o on o.id = i.org_id left join accounts a on a.id = i.account_id
    where i.accepted_at is null and i.revoked_at is null), '[]'::jsonb);
end $$;

-- Suspend or restore a person everywhere (platform admins; never yourself; owners only by an owner).
create function public.platform_set_user_suspended(p_user uuid, p_suspended boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_user = auth.uid() then raise exception 'you cannot suspend yourself'; end if;
  if exists (select 1 from platform_admins where user_id = p_user) and not app.is_platform_owner() then
    raise exception 'only a platform owner can suspend a platform admin' using errcode = '42501';
  end if;
  if p_suspended then
    insert into user_suspensions (user_id, reason, created_by) values (p_user, p_reason, auth.uid())
    on conflict (user_id) do update set reason = excluded.reason;
  else
    delete from user_suspensions where user_id = p_user;
  end if;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), case when p_suspended then 'suspend_user' else 'restore_user' end, 'user', p_user,
          jsonb_build_object('reason', p_reason));
end $$;

-- Change or remove platform access (platform owners). Keeps at least one owner.
create function public.platform_set_admin(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not app.is_platform_owner() then raise exception 'only a platform owner can do this' using errcode = '42501'; end if;
  if p_role is null then
    if (select role from platform_admins where user_id = p_user) = 'owner'
       and (select count(*) from platform_admins where role = 'owner') <= 1 then
      raise exception 'the platform needs at least one owner';
    end if;
    delete from platform_admins where user_id = p_user;
  elsif p_role in ('owner','admin') then
    if p_role = 'admin' and (select role from platform_admins where user_id = p_user) = 'owner'
       and (select count(*) from platform_admins where role = 'owner') <= 1 then
      raise exception 'the platform needs at least one owner';
    end if;
    insert into platform_admins (user_id, role) values (p_user, p_role)
    on conflict (user_id) do update set role = excluded.role;
  else
    raise exception 'role must be owner, admin or null';
  end if;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), 'platform_role', 'user', p_user, jsonb_build_object('role', p_role));
end $$;

-- What the signed-in person can open, for routing after sign-in.
-- { platform_role, suspended, portals: [{ org_id, org_name, org_kind, role, account_id, account_name }] }
create function public.my_access() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'platform_role', (select role from platform_admins where user_id = auth.uid()),
    'suspended', app.is_suspended(),
    'portals', coalesce((select jsonb_agg(jsonb_build_object(
        'org_id', o.id, 'org_name', o.name, 'org_kind', o.kind, 'org_slug', o.slug, 'role', m.role,
        'account_id', m.account_id, 'account_name', a.name) order by o.name, m.role)
      from memberships m join orgs o on o.id = m.org_id left join accounts a on a.id = m.account_id
      where m.user_id = auth.uid() and m.active and o.status = 'active'), '[]'::jsonb));
$$;

-- Corporate client books on its company account. Confirmed at once when the account allows it.
create function public.client_create_booking(p_org uuid, p_account uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_contact uuid; v_booking uuid; a accounts; v_email text;
begin
  if not exists (select 1 from memberships m join orgs o on o.id = m.org_id
                 where m.org_id = p_org and m.user_id = auth.uid() and m.active and o.status = 'active'
                   and m.account_id = p_account and m.role in ('client_admin','client_booker'))
     or app.is_suspended() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into a from accounts where id = p_account;
  if not a.active then raise exception 'this client account is paused'; end if;
  if (p->>'pickup_at')::timestamptz < now() + interval '30 minutes' then
    raise exception 'pickup must be at least 30 minutes from now';
  end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  select id into v_contact from contacts where org_id = p_org and user_id = auth.uid() limit 1;
  if v_contact is null then
    insert into contacts (org_id, account_id, user_id, full_name, email)
    values (p_org, p_account, auth.uid(), split_part(v_email, '@', 1), v_email) returning id into v_contact;
  end if;
  v_booking := app.book(p_org, v_contact, p, case when a.auto_confirm then 'confirmed' else 'quoted' end);
  update bookings set account_id = p_account where id = v_booking;
  return v_booking;
end $$;

-- First platform owner, run once from the SQL Editor. Works before or after that person signs up.
create function app.bootstrap_platform_owner(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare v_user uuid; i invitations; v_email text := lower(trim(p_email));
begin
  insert into invitations (email, org_id, role) values (v_email, null, 'platform_owner') returning * into i;
  select id into v_user from auth.users where lower(email) = v_email;
  if v_user is not null then
    perform app.grant_invitation(v_user, i);
    return 'granted now';
  end if;
  return 'will be granted when ' || v_email || ' signs in';
end $$;
revoke all on function app.bootstrap_platform_owner(text) from public;

-- ---------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------
grant select on invitations to authenticated;
grant select on user_suspensions to authenticated;
grant execute on function app.is_finance(uuid) to authenticated;
grant execute on function app.is_account_admin(uuid) to authenticated;
grant execute on function app.sees_booking(uuid) to authenticated;
grant execute on function public.invite_user(uuid, text, text, uuid, text) to authenticated;
grant execute on function public.claim_invitations() to authenticated;
grant execute on function public.invitation_preview(text) to anon, authenticated;
grant execute on function public.revoke_invitation(uuid) to authenticated;
grant execute on function public.renew_invitation(uuid) to authenticated;
grant execute on function public.org_access(uuid) to authenticated;
grant execute on function public.update_member(uuid, text, text) to authenticated;
grant execute on function public.platform_users(text) to authenticated;
grant execute on function public.platform_invitations() to authenticated;
grant execute on function public.platform_set_user_suspended(uuid, boolean, text) to authenticated;
grant execute on function public.platform_set_admin(uuid, text) to authenticated;
grant execute on function public.my_access() to authenticated;
grant execute on function public.client_create_booking(uuid, uuid, jsonb) to authenticated;
