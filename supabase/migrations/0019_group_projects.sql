-- 0019_group_projects: DMC/MICE group movement. Step C of the enterprise roadmap.
-- A group project is a lightweight container (dates, destination, optional billing
-- account) that many ordinary bookings attach to. No new booking engine: a group booking
-- is created exactly the same way any booking is today (create_booking, the CSV import
-- already wired to it, or create_recurring_bookings for a repeating transfer pattern),
-- just tagged with group_project_id. No new RPC for the project itself either: it's
-- staff-writable under the same direct-insert/update pattern already used for accounts.

create table group_projects (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references orgs(id) on delete cascade,
  name                text not null,
  destination         text not null,
  start_date          date not null,
  end_date            date not null check (end_date >= start_date),
  status              text not null default 'planning' check (status in ('planning', 'confirmed', 'completed', 'cancelled')),
  primary_account_id  uuid references accounts(id) on delete set null,
  notes               text,
  created_at          timestamptz not null default now()
);
comment on column group_projects.primary_account_id is 'Optional: the hotel or corporate account this group bills through. A group project can also stand alone with each booking billed individually.';
comment on column group_projects.status is 'planning: still being built. confirmed: attendee list and transfers locked. completed: travel dates have passed. cancelled: whole group called off.';
alter table group_projects enable row level security;
create policy staff_all on group_projects for all using (app.is_staff(org_id)) with check (app.is_staff(org_id));
grant select, insert, update, delete on group_projects to authenticated;
create index group_projects_org_dates_idx on group_projects (org_id, start_date);

alter table bookings
  add column group_project_id uuid references group_projects(id) on delete set null;
comment on column bookings.group_project_id is 'Set when this booking is part of a group/MICE movement (attached via the group project''s manifest/import, or picked on an individual booking); null for an ordinary booking.';
create index bookings_group_project_idx on bookings (group_project_id) where group_project_id is not null;
