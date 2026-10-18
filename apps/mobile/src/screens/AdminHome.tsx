import { useCallback, useEffect, useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { useTranslation } from 'react-i18next';
import { formatDateTime, type Trip } from '@limo/shared';
import { supabase } from '../lib/supabase';
import { useSession, type Workspace } from '../lib/session';
import { Button, Screen, s } from '../ui';

export function AdminHome({ workspace }: { workspace: Workspace }) {
  const { t, i18n } = useTranslation();
  const { setActive, workspaces } = useSession();
  const [trips, setTrips] = useState<Trip[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const org = workspace.org;

  const load = useCallback(async () => {
    setRefreshing(true);
    const { data, error: e } = await supabase
      .from('trips').select('*').eq('org_id', org.id)
      .not('status', 'in', '(completed,cancelled,no_show)')
      .order('pickup_at').limit(50);
    if (e) setError(e.message); else { setTrips((data ?? []) as Trip[]); setError(null); }
    setRefreshing(false);
  }, [org.id]);

  useEffect(() => { load(); }, [load]);

  const unassigned = trips.filter((x) => x.status === 'unassigned').length;

  return (
    <Screen title={`${org.name}`}
      right={workspaces.length > 1 ? <Button kind="ghost" label={t('common.switch')} onPress={() => setActive(null)} /> : undefined}>
      <View style={s.card}>
        <Text style={s.title}>{t('admin.unassigned')}: {unassigned}</Text>
      </View>
      {error ? <Text style={s.error}>{error}</Text> : null}
      <Text style={[s.title, { marginBottom: 8 }]}>{t('admin.upcoming')}</Text>
      <FlatList
        data={trips}
        keyExtractor={(x) => x.id}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={load} />}
        ListEmptyComponent={<Text style={s.sub}>{t('admin.empty')}</Text>}
        renderItem={({ item }) => (
          <View style={s.card}>
            <Text style={s.title}>{formatDateTime(item.pickup_at, org.timezone, org.clock_24h, i18n.language as 'en')}</Text>
            <Text style={s.sub}>{item.pickup_address}</Text>
            <Text style={s.sub}>{t(`status.${item.status}`)}</Text>
          </View>
        )}
      />
      <Button kind="ghost" label={t('common.signOut')} onPress={() => supabase.auth.signOut()} />
    </Screen>
  );
}
