-- 0020_partner_compliance: supplier onboarding and compliance. Step E of the enterprise
-- roadmap. Formalizes what farm-out already does informally, in two parts.
--
-- 1. org_documents: same shape as driver_documents/vehicle_documents (kind, number,
--    expires_on, file_path, notes), applied to an org instead of a driver or vehicle, so a
--    partner operator's own licence/insurance/inspection paperwork can be tracked and
--    reviewed the same way driver/vehicle compliance already is. Same "compliance" storage
--    bucket, path prefixed by org_id like the existing two tables use.
-- 2. orgs.network_status (unverified/pending/verified/suspended), reviewed by platform
--    admins on the same company page Step A1's capabilities/relationships panels live on,
--    via an audited RPC reusing app.require_platform_admin() exactly as those did.
--
-- Quality scoring reuses existing farm_outs/trips data rather than a new tracking table.
-- partner_quality_score() is security definer because farm_outs/trips RLS only lets a staff
-- member see rows where their own org is from_org_id or to_org_id -- an operator deciding
-- whether to farm a trip to a partner has no RLS path to that partner's acceptance history.
-- The function returns only an aggregate (counts and rates), never another org's individual
-- trips, prices or counterparties.

create table org_documents (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  kind        text not null,
  number      text,
  expires_on  date not null,
  file_path   text,
  notes       text,
  created_at  timestamptz not null default now()
);
alter table org_documents enable row level security;
create policy staff_all on org_documents for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
grant select, insert, update, delete on org_documents to authenticated;

alter table orgs
  add column network_status text not null default 'unverified'
    check (network_status in ('unverified', 'pending', 'verified', 'suspended'));
comment on column orgs.network_status is 'Platform-admin reviewed. Meaningful only for an org with listed_in_network = true; everything else stays unverified and is not expected to apply.';

create function public.set_network_status(p_org uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_status not in ('unverified', 'pending', 'verified', 'suspended') then
    raise exception 'invalid network status';
  end if;
  update orgs set network_status = p_status where id = p_org;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'update', 'network_status', p_org, jsonb_build_object('status', p_status));
end $$;
grant execute on function public.set_network_status(uuid, text) to authenticated;

create function public.partner_quality_score(p_org uuid, p_days integer default 90) returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare
  v_responded int; v_accepted int; v_declined int;
  v_completed int; v_no_show int; v_cancelled int;
begin
  select
    count(*) filter (where status in ('accepted', 'declined')),
    count(*) filter (where status = 'accepted'),
    count(*) filter (where status = 'declined')
    into v_responded, v_accepted, v_declined
    from farm_outs
    where to_org_id = p_org and created_at >= now() - (p_days || ' days')::interval;

  select
    count(*) filter (where t.status = 'completed'),
    count(*) filter (where t.status = 'no_show'),
    count(*) filter (where t.status = 'cancelled')
    into v_completed, v_no_show, v_cancelled
    from farm_outs f join trips t on t.id = f.trip_id
    where f.to_org_id = p_org and f.status = 'accepted' and f.created_at >= now() - (p_days || ' days')::interval;

  return jsonb_build_object(
    'days', p_days,
    'offers_responded', v_responded,
    'accepted', v_accepted,
    'declined', v_declined,
    'acceptance_rate', case when v_responded > 0 then round(v_accepted::numeric / v_responded, 3) else null end,
    'completed', v_completed,
    'no_show', v_no_show,
    'cancelled', v_cancelled,
    'completion_rate', case when (v_completed + v_no_show + v_cancelled) > 0
      then round(v_completed::numeric / (v_completed + v_no_show + v_cancelled), 3) else null end
  );
end $$;
grant execute on function public.partner_quality_score(uuid, integer) to authenticated;
