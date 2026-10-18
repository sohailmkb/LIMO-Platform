import { useCallback, useEffect, useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { useTranslation } from 'react-i18next';
import { ACTIVE_TRIP_STATUSES, DRIVER_NEXT, DRIVER_NO_SHOW_FROM, formatDateTime, type Trip } from '@limo/shared';
import { supabase } from '../lib/supabase';
import { useSession, type Workspace } from '../lib/session';
import { Button, Screen, s } from '../ui';

// Row-level security returns only trips assigned to this driver, so no extra filter is needed for safety.
export function DriverHome({ workspace }: { workspace: Workspace }) {
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
      .in('status', ACTIVE_TRIP_STATUSES).order('pickup_at');
    if (e) setError(e.message); else { setTrips((data ?? []) as Trip[]); setError(null); }
    setRefreshing(false);
  }, [org.id]);

  useEffect(() => { load(); }, [load]);

  async function move(trip: Trip, status: string) {
    const { error: e } = await supabase.rpc('update_trip_status', { p_trip: trip.id, p_status: status });
    if (e) setError(e.message);
    await load();
  }

  return (
    <Screen title={t('driver.title')}
      right={workspaces.length > 1 ? <Button kind="ghost" label={t('common.switch')} onPress={() => setActive(null)} /> : undefined}>
      {error ? <Text style={s.error}>{error}</Text> : null}
      <FlatList
        data={trips}
        keyExtractor={(x) => x.id}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={load} />}
        ListEmptyComponent={<Text style={s.sub}>{t('driver.empty')}</Text>}
        renderItem={({ item }) => {
          const next = DRIVER_NEXT[item.status];
          return (
            <View style={s.card}>
              <Text style={s.title}>{formatDateTime(item.pickup_at, org.timezone, org.clock_24h, i18n.language as 'en')}</Text>
              <Text style={s.sub}>{item.pickup_address}</Text>
              {item.dropoff_address ? <Text style={s.sub}>{item.dropoff_address}</Text> : null}
              <Text style={s.sub}>{t(`status.${item.status}`)}</Text>
              {next ? <Button label={t(`driver.next.${next}`)} onPress={() => move(item, next)} /> : null}
              {item.status === DRIVER_NO_SHOW_FROM
                ? <Button kind="ghost" label={t('driver.noShow')} onPress={() => move(item, 'no_show')} /> : null}
            </View>
          );
        }}
      />
      <Button kind="ghost" label={t('common.signOut')} onPress={() => supabase.auth.signOut()} />
    </Screen>
  );
}
