-- 0023_marketplace_cascade_and_governance: starts Step F (managed marketplace) and Step G
-- (AI governance) from the enterprise roadmap, plus the audit trail UI the platform has been
-- writing into audit_log since 0006 but never exposed.
--
-- 1. Cascade farm-out. Still managed, never open bidding, per the master spec's own
--    instruction: the operator picks the ranked candidate list up front (the UI defaults to
--    the existing preferred-first/quality sort), and every advance to the next candidate is a
--    deliberate click, not a timer firing on a server. No new table and no new RPC: this
--    reuses farm_outs' existing direct-insert/update RLS pattern, just with two new columns
--    (cascade_id groups one trip's sequence; cascade_rank orders it) and two new statuses
--    ('queued' for a candidate not yet offered, 'expired' for one that timed out without a
--    response). A cascade is created by inserting all its rows at once (rank 1 as 'offered'
--    with expires_at set, the rest 'queued' with no expiry yet); advancing is one UPDATE to
--    expire the current row and one UPDATE to promote the next 'queued' row to 'offered'.
--    The existing farm_outs_block_suspended trigger (0021) still guards every row, so the UI
--    must exclude suspended partners from the candidate list before it builds one, same as the
--    single-partner dialog already does.
--
-- 2. AI recommendation log. Formalizes what suggest_drivers() (0013) already does informally.
--    suggest_drivers() itself stays a pure, stable read -- it has no side effects to log from
--    inside the database. The log is written by the client at the one moment that matters: a
--    trip actually gets a driver assigned. It records the full suggestion list shown
--    (inputs), which driver (if any) was top-ranked, and which driver was actually chosen, so
--    "accepted the AI's top pick" vs "overrode it" is a stored fact, not something inferred
--    from logs after the fact. No new RPC -- a direct insert under the same staff_all shape
--    used by org_documents and group_projects.
--
-- 3. No schema change for the audit-log viewer: audit_log (0006) already has every column a
--    reader needs. This migration just documents that a UI now reads it; nothing to add here.

alter table farm_outs
  add column cascade_id uuid,
  add column cascade_rank integer,
  add column expires_at timestamptz;
comment on column farm_outs.cascade_id is 'Groups one trip''s ranked sequence of cascade offers. Null for an ordinary single-partner farm-out.';
comment on column farm_outs.cascade_rank is 'Position in the cascade, 1-based. Null for an ordinary single-partner farm-out.';
comment on column farm_outs.expires_at is 'Set only on the currently-offered row of a cascade. The UI treats a past expiry as "ready to advance"; nothing server-side expires it automatically.';

alter table farm_outs drop constraint farm_outs_status_check;
alter table farm_outs add constraint farm_outs_status_check
  check (status in ('offered', 'accepted', 'declined', 'cancelled', 'queued', 'expired'));

create index farm_outs_cascade_idx on farm_outs (cascade_id, cascade_rank) where cascade_id is not null;

create table ai_recommendation_log (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references orgs(id) on delete cascade,
  trip_id               uuid not null references trips(id) on delete cascade,
  kind                  text not null default 'driver_suggestion',
  inputs                jsonb not null,
  recommended_driver_id uuid references drivers(id) on delete set null,
  chosen_driver_id      uuid references drivers(id) on delete set null,
  overridden            boolean generated always as
                          (recommended_driver_id is distinct from chosen_driver_id) stored,
  actor_id              uuid references auth.users(id),
  created_at            timestamptz not null default now()
);
comment on column ai_recommendation_log.inputs is 'The exact jsonb suggest_drivers() returned at the time of assignment -- the full ranked candidate list with scores and reasons, not just the winner.';
comment on column ai_recommendation_log.recommended_driver_id is 'Top-ranked candidate from inputs, or null if suggest_drivers() returned no candidates.';
comment on column ai_recommendation_log.overridden is 'True when the dispatcher chose a driver other than the top recommendation (including assigning manually with no suggestion shown).';
alter table ai_recommendation_log enable row level security;
create policy staff_all on ai_recommendation_log for all
  using (app.is_staff(org_id)) with check (app.is_staff(org_id));
grant select, insert on ai_recommendation_log to authenticated;
create index ai_recommendation_log_org_trip_idx on ai_recommendation_log (org_id, trip_id);
