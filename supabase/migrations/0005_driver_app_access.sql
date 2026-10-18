-- 0005_driver_app_access: give app access to a driver who is already on the list,
-- without creating a second driver row. Also live updates for driver status.

-- Owner or admin links an existing drivers row to the account with this email.
-- Returns: 'linked', 'already_linked', 'no_account' (person must sign up first),
-- or 'account_used_by_other_driver' (that account is already another driver at this operator).
create function public.grant_driver_app_access(p_driver uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_current uuid; v_user uuid;
begin
  select org_id, user_id into v_org, v_current from drivers where id = p_driver;
  if v_org is null then raise exception 'driver not found'; end if;
  if not app.has_role(v_org, array['owner','admin']) then
    raise exception 'only owners and admins can give app access' using errcode = '42501';
  end if;

  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then return 'no_account'; end if;

  if v_current = v_user then
    insert into memberships (org_id, user_id, role) values (v_org, v_user, 'driver')
    on conflict (org_id, user_id, role) do update set active = true;
    return 'already_linked';
  end if;

  if exists (select 1 from drivers where org_id = v_org and user_id = v_user and id <> p_driver) then
    return 'account_used_by_other_driver';
  end if;

  update drivers set user_id = v_user where id = p_driver;
  insert into memberships (org_id, user_id, role) values (v_org, v_user, 'driver')
  on conflict (org_id, user_id, role) do update set active = true;

  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (v_org, auth.uid(), 'grant_app_access', 'driver', p_driver, jsonb_build_object('user_id', v_user));
  return 'linked';
end $$;

grant execute on function public.grant_driver_app_access(uuid, text) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table drivers;
  end if;
end $$;
