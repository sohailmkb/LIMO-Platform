import { useState } from 'react';
import { Text, TextInput } from 'react-native';
import { useTranslation } from 'react-i18next';
import { supabase } from '../lib/supabase';
import { Button, Screen, s } from '../ui';

export function SignIn() {
  const { t } = useTranslation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true); setError(null);
    const { error: e } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (e) setError(e.message);
    setBusy(false);
  }

  return (
    <Screen title={t('common.signIn')}>
      <TextInput style={s.input} placeholder={t('common.email')} autoCapitalize="none"
        keyboardType="email-address" value={email} onChangeText={setEmail} />
      <TextInput style={s.input} placeholder={t('common.password')} secureTextEntry
        value={password} onChangeText={setPassword} />
      {error ? <Text style={s.error}>{error}</Text> : null}
      <Button label={t('common.signIn')} onPress={submit} disabled={busy || !email || !password} />
    </Screen>
  );
}
