import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import { pickLocale } from '@limo/shared';
import en from './en.json';
import fr from './fr.json';

// Spanish, German and Italian are added here only after native review (see LOCALES in @limo/shared).
const device = Intl.DateTimeFormat().resolvedOptions().locale;

i18n.use(initReactI18next).init({
  resources: { en: { translation: en }, fr: { translation: fr } },
  lng: pickLocale(device),
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
});

export default i18n;
