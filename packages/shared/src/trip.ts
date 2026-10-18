// Mirrors public.update_trip_status in supabase/migrations/0003_security_and_actions.sql.
// If the SQL transition table changes, change this too.

import type { TripStatus } from './types';

/** The one forward step a driver can take from each status. */
export const DRIVER_NEXT: Partial<Record<TripStatus, TripStatus>> = {
  assigned: 'en_route',
  en_route: 'arrived',
  arrived: 'on_board',
  on_board: 'completed',
};

/** Extra branch from "arrived". */
export const DRIVER_NO_SHOW_FROM: TripStatus = 'arrived';

export const ACTIVE_TRIP_STATUSES: TripStatus[] = ['assigned', 'en_route', 'arrived', 'on_board'];
