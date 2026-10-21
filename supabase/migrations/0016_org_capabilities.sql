-- 0016_org_capabilities: capability-based organization model, additive to orgs.kind.
-- An org can now hold more than one capability (a hotel that also books as a corporate
-- buyer, for example) without widening orgs.kind's check constraint again. orgs.kind stays
-- exactly as it is and keeps driving every existing `kind = 'operator'` check; capabilities
-- is a superset that starts in sync with it and grows from there as new org types (hotel,
-- dmc, affiliate_supplier, corporate_buyer, api_partner) are onboarded.
-- See claude/role-architecture-model.md and claude/enterprise-roadmap.md Step A1.

-- ---------------------------------------------------------------
-- Capabilities
-- ---------------------------------------------------------------
create table organization_capabilities (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  capability  text not null check (capability in
                ('operator', 'travel_agency', 'hotel', 'dmc', 'affiliate_supplier', 'corporate_buyer', 'api_partner')),
  granted_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  unique (org_id, capability)
);
alter table organization_capabilities enable row level security;

create policy staff_read on organization_capabilities for select
  using (app.is_staff(org_id) or app.is_platform_admin());

grant select on organization_capabilities to authenticated;

-- Back-fill: every existing org already has exactly one capability, the one orgs.kind says.
insert into organization_capabilities (org_id, capability)
select id, kind from orgs
on conflict (org_id, capability) do nothing;

-- Keep it in sync automatically: orgs.kind remains the single source of truth for the
-- "primary" capability every org already has today, including orgs created after this point.
create function app.sync_org_kind_capability() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into organization_capabilities (org_id, capability)
  values (new.id, new.kind)
  on conflict (org_id, capability) do nothing;
  return new;
end $$;

create trigger org_kind_capability_sync
  after insert or update of kind on orgs
  for each row execute function app.sync_org_kind_capability();

-- Grant / revoke, platform-admin only. A capability changes what an org is legally and
-- commercially allowed to do on the platform (take hotel commission, run a DMC project,
-- call the API), so it is not self-service the way ordinary settings are.
create function public.grant_org_capability(p_org uuid, p_capability text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  insert into organization_capabilities (org_id, capability, granted_by)
  values (p_org, p_capability, auth.uid())
  on conflict (org_id, capability) do nothing;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'grant', 'org_capability', p_org, jsonb_build_object('capability', p_capability));
end $$;
grant execute on function public.grant_org_capability(uuid, text) to authenticated;

create function public.revoke_org_capability(p_org uuid, p_capability text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_capability = (select kind from orgs where id = p_org) then
    raise exception 'Cannot revoke %, it is this organization''s primary kind. Change orgs.kind first.', p_capability;
  end if;
  delete from organization_capabilities where org_id = p_org and capability = p_capability;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'revoke', 'org_capability', p_org, jsonb_build_object('capability', p_capability));
end $$;
grant execute on function public.revoke_org_capability(uuid, text) to authenticated;

-- ---------------------------------------------------------------
-- Relationships: a standing link between two organizations (parent/subsidiary, a hotel's
-- preferred operator, a franchise). Separate from farm_outs, which records a single trip
-- handed from one org to another, not an ongoing relationship.
-- ---------------------------------------------------------------
create table organization_relationships (
  id                uuid primary key default gen_random_uuid(),
  org_a             uuid not null references orgs(id) on delete cascade,
  org_b             uuid not null references orgs(id) on delete cascade,
  relationship_type text not null check (relationship_type in
                      ('parent_subsidiary', 'preferred_supplier', 'booking_channel', 'franchise')),
  since             date not null default current_date,
  notes             text,
  created_at        timestamptz not null default now(),
  check (org_a <> org_b),
  unique (org_a, org_b, relationship_type)
);
alter table organization_relationships enable row level security;

create policy staff_read on organization_relationships for select
  using (app.is_staff(org_a) or app.is_staff(org_b) or app.is_platform_admin());

grant select on organization_relationships to authenticated;

create function public.create_org_relationship(
  p_org_a uuid, p_org_b uuid, p_type text, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform app.require_platform_admin();
  insert into organization_relationships (org_a, org_b, relationship_type, notes)
  values (p_org_a, p_org_b, p_type, p_notes)
  returning id into v_id;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org_a, auth.uid(), 'create', 'org_relationship', v_id,
          jsonb_build_object('org_b', p_org_b, 'relationship_type', p_type));
  return v_id;
end $$;
grant execute on function public.create_org_relationship(uuid, uuid, text, text) to authenticated;

create function public.delete_org_relationship(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org_a uuid;
begin
  perform app.require_platform_admin();
  select org_a into v_org_a from organization_relationships where id = p_id;
  delete from organization_relationships where id = p_id;
  insert into audit_log (org_id, actor_id, action, entity, entity_id)
  values (v_org_a, auth.uid(), 'delete', 'org_relationship', p_id);
end $$;
grant execute on function public.delete_org_relationship(uuid) to authenticated;
