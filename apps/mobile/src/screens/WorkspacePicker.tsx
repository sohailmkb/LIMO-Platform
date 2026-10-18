import { Pressable, Text } from 'react-native';
import { useTranslation } from 'react-i18next';
import { useSession } from '../lib/session';
import { Button, Screen, s } from '../ui';

export function WorkspacePicker() {
  const { t } = useTranslation();
  const { workspaces, setActive, signOut } = useSession();

  return (
    <Screen title={t('picker.title')}>
      {workspaces.length === 0 ? <Text style={s.sub}>{t('picker.none')}</Text> : null}
      {workspaces.map((w) => (
        <Pressable key={`${w.mode}:${w.org.id}`} style={s.card} onPress={() => setActive(w)}>
          <Text style={s.title}>{w.org.name}</Text>
          <Text style={s.sub}>{t(`picker.${w.mode}`)}</Text>
        </Pressable>
      ))}
      <Button kind="ghost" label={t('common.signOut')} onPress={signOut} />
    </Screen>
  );
}
