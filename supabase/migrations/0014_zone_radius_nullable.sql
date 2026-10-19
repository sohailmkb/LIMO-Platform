-- 0014_zone_radius_nullable: fixes a gap in 0013. Drawn-boundary zones are meant to have no
-- radius (the frontend correctly sends radius_km = null when boundary is set, matching
-- app.zone_fare's coalesce(radius_km, 0) and app.point_in_zone's boundary-first logic), but
-- the column was left NOT NULL, so saving a drawn zone fails outright. The CHECK itself was
-- already fine (a CHECK passes when any operand is null), only the NOT NULL needed dropping.
alter table zones alter column radius_km drop not null;
