import './src/i18n';
import { ActivityIndicator, Text, View } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import { useTranslation } from 'react-i18next';
import { isConfigured } from './src/lib/supabase';
import { SessionProvider, useSession } from './src/lib/session';
import { SignIn } from './src/screens/SignIn';
import { WorkspacePicker } from './src/screens/WorkspacePicker';
import { AdminHome } from './src/screens/AdminHome';
import { DriverHome } from './src/screens/DriverHome';
import { CustomerHome } from './src/screens/CustomerHome';
import { Screen, s } from './src/ui';

// One codebase, three role modes. The mode comes from the person's membership in an operator.
function Root() {
  const { t } = useTranslation();
  const { session, loading, active } = useSession();

  if (!isConfigured) {
    return (
      <Screen title={t('setup.title')}>
        <Text style={s.sub}>{t('setup.body')}</Text>
      </Screen>
    );
  }
  if (loading) {
    return <View style={{ flex: 1, justifyContent: 'center' }}><ActivityIndicator /></View>;
  }
  if (!session) return <SignIn />;
  if (!active) return <WorkspacePicker />;

  switch (active.mode) {
    case 'driver': return <DriverHome workspace={active} />;
    case 'customer': return <CustomerHome workspace={active} />;
    default: return <AdminHome workspace={active} />;
  }
}

export default function App() {
  return (
    <SessionProvider>
      <Root />
      <StatusBar style="auto" />
    </SessionProvider>
  );
}
