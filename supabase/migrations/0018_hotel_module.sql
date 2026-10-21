-- 0018_hotel_module: hotel/concierge accounts, reusing the existing corporate-account
-- pattern instead of inventing a parallel one. Step B of the enterprise roadmap.
-- A hotel is an `accounts` row like any corporate client (same table, same RLS, same
-- invite flow for its concierge users as client_booker/client_admin); these four columns
-- are the only new schema this module needs. No new table, no new RPC: accounts and
-- bookings already allow direct staff inserts/updates under the existing `staff_all` /
-- booking policies, so the UI just needs to pass more fields on the same calls it
-- already makes.

alter table accounts
  add column kind               text not null default 'corporate' check (kind in ('corporate', 'hotel')),
  add column commission_percent numeric(5,2) not null default 0 check (commission_percent between 0 and 100);
comment on column accounts.kind is 'corporate: an ordinary client company. hotel: quick-transfer concierge booking, commission tracked.';
comment on column accounts.commission_percent is 'Hotel only. What this operator owes the hotel per completed trip billed to the account, as a percent of the trip total.';

alter table bookings
  add column bill_to     text not null default 'account' check (bill_to in ('account', 'guest')),
  add column room_number text;
comment on column bookings.bill_to is 'account: added to the account''s next invoice, same as any corporate booking today. guest: the guest pays directly, the account is never billed for it.';
comment on column bookings.room_number is 'Set for hotel-originated quick-transfer bookings; null otherwise.';
