import { Pressable, StyleSheet, Text, View, type ViewStyle } from 'react-native';
import type { ReactNode } from 'react';

export const colors = {
  bg: '#F6F7F9', card: '#FFFFFF', ink: '#14181F', muted: '#5B6573',
  line: '#E2E6EC', brand: '#1F3A5F', brandInk: '#FFFFFF', danger: '#B3261E',
};

export const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg, paddingTop: 56, paddingHorizontal: 16 },
  h1: { fontSize: 24, fontWeight: '700', color: colors.ink, marginBottom: 12 },
  card: { backgroundColor: colors.card, borderRadius: 12, padding: 14, marginBottom: 10, borderWidth: 1, borderColor: colors.line },
  title: { fontSize: 16, fontWeight: '600', color: colors.ink },
  sub: { fontSize: 14, color: colors.muted, marginTop: 2 },
  input: { backgroundColor: colors.card, borderWidth: 1, borderColor: colors.line, borderRadius: 10, padding: 12, fontSize: 16, marginBottom: 10 },
  error: { color: colors.danger, marginBottom: 10 },
  row: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
});

export function Button({ label, onPress, kind = 'primary', disabled }: {
  label: string; onPress: () => void; kind?: 'primary' | 'ghost'; disabled?: boolean;
}) {
  const style: ViewStyle = kind === 'primary'
    ? { backgroundColor: colors.brand }
    : { backgroundColor: 'transparent', borderWidth: 1, borderColor: colors.line };
  return (
    <Pressable onPress={onPress} disabled={disabled}
      style={[{ padding: 14, borderRadius: 10, alignItems: 'center', opacity: disabled ? 0.5 : 1, marginTop: 8 }, style]}>
      <Text style={{ color: kind === 'primary' ? colors.brandInk : colors.ink, fontWeight: '600', fontSize: 16 }}>{label}</Text>
    </Pressable>
  );
}

export function Screen({ title, right, children }: { title: string; right?: ReactNode; children: ReactNode }) {
  return (
    <View style={s.screen}>
      <View style={s.row}><Text style={s.h1}>{title}</Text>{right}</View>
      {children}
    </View>
  );
}
