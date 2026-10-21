-- 0017_api_webhooks: API client/credential and webhook endpoint management.
-- Step A2 of the enterprise roadmap (first slice): the self-service surface an operator,
-- travel agency, or any future capability (hotel, DMC, affiliate) uses to generate API
-- keys and register webhook endpoints. This migration does NOT include the outbound
-- delivery worker or the partner-facing read/write API itself (HMAC signing, retries,
-- idempotent request handling) -- that is edge function code, written and reviewed
-- directly, not generated from a prompt, because getting request authentication and
-- signature verification wrong is a security bug, not a UI bug. webhook_deliveries and
-- idempotency_keys exist here so that worker has somewhere to write once it exists.
--
-- Secrets never land in a column readable by `authenticated`. A credential's or
-- endpoint's secret is generated once, returned once in the RPC response, and stored
-- only in a *_secrets companion table with no RLS policy granted to authenticated at
-- all (RLS enabled, zero policies = default deny for every role except the service
-- role the edge functions will use, which bypasses RLS entirely). Nothing new to trust:
-- the same "service role only" boundary this project already uses for Stripe.

-- ---------------------------------------------------------------
-- API clients and credentials
-- ---------------------------------------------------------------
create table api_clients (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null,
  environment text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table api_clients enable row level security;
create policy staff_read on api_clients for select
  using (app.has_role(org_id, array['owner', 'admin']));
grant select on api_clients to authenticated;

create table api_credentials (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references api_clients(id) on delete cascade,
  key_id      text not null unique,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  revoked_by  uuid references auth.users(id)
);
alter table api_credentials enable row level security;
create policy staff_read on api_credentials for select
  using (exists (select 1 from api_clients c where c.id = client_id and app.has_role(c.org_id, array['owner', 'admin'])));
grant select on api_credentials to authenticated;

-- The only place the raw secret ever lives. No select grant to authenticated: only the
-- issuing RPC (below) and, later, the authenticating edge function (service role) touch it.
create table api_credential_secrets (
  credential_id uuid primary key references api_credentials(id) on delete cascade,
  secret        text not null,
  created_at    timestamptz not null default now()
);
alter table api_credential_secrets enable row level security;

create function public.create_api_client(p_org uuid, p_name text, p_environment text default 'sandbox') returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not app.has_role(p_org, array['owner', 'admin']) then
    raise exception 'only owners and admins can create API clients' using errcode = '42501';
  end if;
  insert into api_clients (org_id, name, environment) values (p_org, p_name, p_environment) returning id into v_id;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'create', 'api_client', v_id, jsonb_build_object('name', p_name, 'environment', p_environment));
  return v_id;
end $$;
grant execute on function public.create_api_client(uuid, text, text) to authenticated;

-- Returns {key_id, secret} ONCE. The secret is never retrievable again after this call.
create function public.issue_api_credential(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_cred uuid; v_key_id text; v_secret text;
begin
  select org_id into v_org from api_clients where id = p_client;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin']) then
    raise exception 'only owners and admins can issue API credentials' using errcode = '42501';
  end if;
  v_key_id := 'key_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
  v_secret := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into api_credentials (client_id, key_id) values (p_client, v_key_id) returning id into v_cred;
  insert into api_credential_secrets (credential_id, secret) values (v_cred, v_secret);
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (v_org, auth.uid(), 'issue', 'api_credential', v_cred, jsonb_build_object('key_id', v_key_id));
  return jsonb_build_object('key_id', v_key_id, 'secret', v_secret);
end $$;
grant execute on function public.issue_api_credential(uuid) to authenticated;

create function public.revoke_api_credential(p_credential_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select c.org_id into v_org from api_credentials k join api_clients c on c.id = k.client_id where k.id = p_credential_id;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin']) then
    raise exception 'only owners and admins can revoke API credentials' using errcode = '42501';
  end if;
  update api_credentials set revoked_at = now(), revoked_by = auth.uid() where id = p_credential_id;
  delete from api_credential_secrets where credential_id = p_credential_id;
  insert into audit_log (org_id, actor_id, action, entity, entity_id)
  values (v_org, auth.uid(), 'revoke', 'api_credential', p_credential_id);
end $$;
grant execute on function public.revoke_api_credential(uuid) to authenticated;

-- ---------------------------------------------------------------
-- Webhook endpoints
-- ---------------------------------------------------------------
create table webhook_endpoints (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  url         text not null check (url like 'https://%'),
  events      text[] not null default '{}',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table webhook_endpoints enable row level security;
create policy staff_read on webhook_endpoints for select
  using (app.has_role(org_id, array['owner', 'admin']));
grant select on webhook_endpoints to authenticated;

-- Same shape as api_credential_secrets: no select grant to authenticated, ever.
create table webhook_endpoint_secrets (
  endpoint_id uuid primary key references webhook_endpoints(id) on delete cascade,
  secret      text not null,
  created_at  timestamptz not null default now()
);
alter table webhook_endpoint_secrets enable row level security;

create function public.create_webhook_endpoint(p_org uuid, p_url text, p_events text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_secret text;
begin
  if not app.has_role(p_org, array['owner', 'admin']) then
    raise exception 'only owners and admins can register webhook endpoints' using errcode = '42501';
  end if;
  if p_url not like 'https://%' then
    raise exception 'webhook URL must be https';
  end if;
  v_secret := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into webhook_endpoints (org_id, url, events) values (p_org, p_url, p_events) returning id into v_id;
  insert into webhook_endpoint_secrets (endpoint_id, secret) values (v_id, v_secret);
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (p_org, auth.uid(), 'create', 'webhook_endpoint', v_id, jsonb_build_object('url', p_url, 'events', p_events));
  return jsonb_build_object('id', v_id, 'secret', v_secret);
end $$;
grant execute on function public.create_webhook_endpoint(uuid, text, text[]) to authenticated;

create function public.update_webhook_endpoint(p_id uuid, p_events text[], p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from webhook_endpoints where id = p_id;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin']) then
    raise exception 'only owners and admins can change webhook endpoints' using errcode = '42501';
  end if;
  update webhook_endpoints set events = p_events, active = p_active where id = p_id;
  insert into audit_log (org_id, actor_id, action, entity, entity_id, detail)
  values (v_org, auth.uid(), 'update', 'webhook_endpoint', p_id, jsonb_build_object('events', p_events, 'active', p_active));
end $$;
grant execute on function public.update_webhook_endpoint(uuid, text[], boolean) to authenticated;

create function public.delete_webhook_endpoint(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from webhook_endpoints where id = p_id;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin']) then
    raise exception 'only owners and admins can remove webhook endpoints' using errcode = '42501';
  end if;
  delete from webhook_endpoints where id = p_id;
  insert into audit_log (org_id, actor_id, action, entity, entity_id)
  values (v_org, auth.uid(), 'delete', 'webhook_endpoint', p_id);
end $$;
grant execute on function public.delete_webhook_endpoint(uuid) to authenticated;

-- ---------------------------------------------------------------
-- Delivery log and idempotency. Written only by the edge functions built next
-- (service role, bypasses RLS). The UI only ever reads webhook_deliveries.
-- ---------------------------------------------------------------
create table webhook_deliveries (
  id              uuid primary key default gen_random_uuid(),
  endpoint_id     uuid not null references webhook_endpoints(id) on delete cascade,
  event_type      text not null,
  payload         jsonb not null,
  status          text not null default 'pending' check (status in ('pending', 'delivered', 'failed', 'exhausted')),
  attempt_count   integer not null default 0,
  next_attempt_at timestamptz,
  last_error      text,
  created_at      timestamptz not null default now(),
  delivered_at    timestamptz
);
alter table webhook_deliveries enable row level security;
create policy staff_read on webhook_deliveries for select
  using (exists (select 1 from webhook_endpoints e where e.id = endpoint_id and app.has_role(e.org_id, array['owner', 'admin'])));
grant select on webhook_deliveries to authenticated;
create index webhook_deliveries_pending_idx on webhook_deliveries (next_attempt_at) where status = 'pending';

-- Fully internal: no RLS policy, so no role but service_role (which bypasses RLS) touches it.
create table idempotency_keys (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references api_clients(id) on delete cascade,
  key             text not null,
  request_hash    text not null,
  response_status integer,
  response_body   jsonb,
  created_at      timestamptz not null default now(),
  unique (client_id, key)
);
alter table idempotency_keys enable row level security;
