// Hand-written row types for the week-1 slice.
// TODO(week 2): replace with `supabase gen types typescript` output once the
// project exists, and keep this file only for app-level unions.

import type { CurrencyCode, UnitSystem } from './locale';

export type Role = 'owner' | 'admin' | 'dispatcher' | 'driver' | 'customer';
export type AppMode = 'admin' | 'driver' | 'customer';

export type ServiceType = 'one_way' | 'hourly';
export type BookingStatus = 'quoted' | 'confirmed' | 'in_progress' | 'completed' | 'cancelled';
export type PaymentStatus = 'unpaid' | 'partial' | 'paid' | 'refunded';

export type TripStatus =
  | 'unassigned' | 'offered' | 'assigned' | 'en_route'
  | 'arrived' | 'on_board' | 'completed' | 'no_show' | 'cancelled';

export interface Membership { id: string; org_id: string; role: Role; active: boolean }

export interface Org {
  id: string; name: string; slug: string; country: string; timezone: string;
  default_currency: CurrencyCode; unit_system: UnitSystem; clock_24h: boolean;
}

export interface Booking {
  id: string; org_id: string; number: number; passenger_name: string;
  service_type: ServiceType; status: BookingStatus; currency: CurrencyCode;
  subtotal: number; tax_total: number; total: number; payment_status: PaymentStatus;
}

export interface Trip {
  id: string; org_id: string; booking_id: string; pickup_at: string;
  pickup_address: string; dropoff_address: string | null; status: TripStatus;
  driver_id: string | null;
}

export interface Quote {
  currency: CurrencyCode; tax_rate_id: string; tax_label: string;
  lines: { kind: string; description: string; amount: number; tax_amount: number }[];
  subtotal: number; tax_total: number; total: number;
}
