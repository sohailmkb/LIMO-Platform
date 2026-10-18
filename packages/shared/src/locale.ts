// Locale, currency and unit helpers shared by web and mobile.
// Language status mirrors the `locales` table: only live languages are offered.

export type CurrencyCode = 'USD' | 'CAD' | 'GBP' | 'EUR';
export type LocaleCode = 'en' | 'fr' | 'es' | 'de' | 'it';
export type UnitSystem = 'metric' | 'imperial';

export const CURRENCIES: CurrencyCode[] = ['USD', 'CAD', 'GBP', 'EUR'];

export const LOCALES: Record<LocaleCode, { name: string; live: boolean }> = {
  en: { name: 'English', live: true },
  fr: { name: 'Français', live: true },
  es: { name: 'Español', live: false }, // waiting for native review
  de: { name: 'Deutsch', live: false },
  it: { name: 'Italiano', live: false },
};

export const LIVE_LOCALES = (Object.keys(LOCALES) as LocaleCode[]).filter((l) => LOCALES[l].live);

/** Pick the best live language for a device locale string such as "fr-CA". */
export function pickLocale(deviceLocale: string | undefined, fallback: LocaleCode = 'en'): LocaleCode {
  const base = (deviceLocale ?? '').slice(0, 2).toLowerCase() as LocaleCode;
  return LIVE_LOCALES.includes(base) ? base : fallback;
}

export function formatMoney(amount: number, currency: CurrencyCode, locale: LocaleCode = 'en'): string {
  return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount);
}

export function formatDistance(value: number, units: UnitSystem): string {
  return `${Math.round(value * 10) / 10} ${units === 'metric' ? 'km' : 'mi'}`;
}

export function formatClock(date: Date | string, timeZone: string, clock24: boolean, locale: LocaleCode = 'en'): string {
  const d = typeof date === 'string' ? new Date(date) : date;
  return new Intl.DateTimeFormat(locale, {
    timeZone,
    hour: 'numeric',
    minute: '2-digit',
    hour12: !clock24,
  }).format(d);
}

export function formatDateTime(date: Date | string, timeZone: string, clock24: boolean, locale: LocaleCode = 'en'): string {
  const d = typeof date === 'string' ? new Date(date) : date;
  return new Intl.DateTimeFormat(locale, {
    timeZone,
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: 'numeric',
    minute: '2-digit',
    hour12: !clock24,
  }).format(d);
}
