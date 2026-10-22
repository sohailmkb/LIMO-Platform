-- 0021_network_directory_quality: closes a real gap in 0020's own design. Still Step E.
--
-- 0020 added partner_quality_score(org, days) as a one-partner-at-a-time RPC, intended to
-- be called per row in the Directory list. But network_directory() -- the only RPC the
-- Directory tab is actually allowed to call, since ordinary staff have no RLS path to read
-- another org's row directly -- only ever returned (id, name, slug, country). There was no
-- column for a UI to read network_status from, and calling a security-definer RPC once per
-- row for a long directory is wasteful. Fixed here by computing both the status and the
-- 90-day acceptance/completion rate in the same directory query, one pass, no N+1.
-- partner_quality_score() is left as-is (used by the platform company page, which wants an
-- adjustable day window for one specific org, not a directory-wide default).
--
-- Also adds a DB-level guarantee the roadmap's Step F already promises: a trip can never be
-- farmed out to a suspended partner, not just discouraged in the UI. This was previously
-- enforceable only by convention.

-- Postgres won't let CREATE OR REPLACE change a set-returning function's OUT-parameter
-- row type (the three new columns), even though the first four are unchanged. Drop and
-- recreate instead -- and because DROP FUNCTION wipes any grants on it, the original
-- grant (0003: anon, authenticated) has to be re-issued below, not just assumed to survive.
drop function if exists public.network_directory();

create function public.network_directory() returns table (
  id uuid, name text, slug text, country text,
  network_status text, acceptance_rate numeric, completion_rate numeric
)
language sql stable security definer set search_path = public as $$
  select
    o.id, o.name, o.slug, o.country, o.network_status,
    q.acceptance_rate, q.completion_rate
  from orgs o
  left join lateral (
    select
      case when count(*) filter (where f.status in ('accepted', 'declined')) > 0
        then round(count(*) filter (where f.status = 'accepted')::numeric
          / count(*) filter (where f.status in ('accepted', 'declined')), 3)
        else null end as acceptance_rate,
      case when count(*) filter (where t.status in ('completed', 'no_show', 'cancelled')) > 0
        then round(count(*) filter (where t.status = 'completed')::numeric
          / count(*) filter (where t.status in ('completed', 'no_show', 'cancelled')), 3)
        else null end as completion_rate
    from farm_outs f
    left join trips t on t.id = f.trip_id and f.status = 'accepted'
    where f.to_org_id = o.id and f.created_at >= now() - interval '90 days'
  ) q on true
  where o.listed_in_network and o.status = 'active' and o.kind = 'operator'
  order by o.name;
$$;
grant execute on function public.network_directory() to anon, authenticated;

create function app.block_suspended_partner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select network_status from orgs where id = new.to_org_id) = 'suspended' then
    raise exception 'this partner is suspended in the network and cannot be offered trips' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger farm_outs_block_suspended before insert on farm_outs
  for each row execute function app.block_suspended_partner();
