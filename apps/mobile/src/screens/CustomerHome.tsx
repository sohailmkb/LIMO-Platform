import { useCallback, useEffect, useState } from 'react';
import { FlatList, RefreshControl, Text, View } from 'react-native';
import { useTranslation } from 'react-i18next';
import { formatMoney, type Booking } from '@limo/shared';
import { supabase } from '../lib/supabase';
import { useSession, type Workspace } from '../lib/session';
import { Button, Screen, s } from '../ui';

// Booking and payment screens arrive on Day 5. This lists the customer's own bookings (enforced by RLS).
export function CustomerHome({ workspace }: { workspace: Workspace }) {
  const { t, i18n } = useTranslation();
  const { setActive, workspaces } = useSession();
  const [rows, setRows] = useState<Booking[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const org = workspace.org;

  const load = useCallback(async () => {
    setRefreshing(true);
    const { data, error: e } = await supabase
      .from('bookings').select('*').eq('org_id', org.id).order('created_at', { ascending: false });
    if (e) setError(e.message); else { setRows((data ?? []) as Booking[]); setError(null); }
    setRefreshing(false);
  }, [org.id]);

  useEffect(() => { load(); }, [load]);

  return (
    <Screen title={t('customer.title')}
      right={workspaces.length > 1 ? <Button kind="ghost" label={t('common.switch')} onPress={() => setActive(null)} /> : undefined}>
      {error ? <Text style={s.error}>{error}</Text> : null}
      <FlatList
        data={rows}
        keyExtractor={(x) => x.id}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={load} />}
        ListEmptyComponent={<Text style={s.sub}>{t('customer.empty')}</Text>}
        renderItem={({ item }) => (
          <View style={s.card}>
            <Text style={s.title}>{t('customer.booking')} #{item.number}</Text>
            <Text style={s.sub}>{item.passenger_name}</Text>
            <Text style={s.sub}>{t(`status.${item.status}`)} · {formatMoney(Number(item.total), item.currency, i18n.language as 'en')}</Text>
          </View>
        )}
      />
      <Button kind="ghost" label={t('common.signOut')} onPress={() => supabase.auth.signOut()} />
    </Screen>
  );
}
