import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import type { AppMode, Membership, Org, Role } from '@limo/shared';
import { supabase } from './supabase';

const MODE_FOR_ROLE: Record<Role, AppMode> = {
  owner: 'admin',
  admin: 'admin',
  dispatcher: 'admin',
  driver: 'driver',
  customer: 'customer',
};

export interface Workspace { mode: AppMode; org: Org }

interface SessionState {
  session: Session | null;
  loading: boolean;
  workspaces: Workspace[];
  active: Workspace | null;
  setActive: (w: Workspace | null) => void;
  signOut: () => Promise<void>;
}

const Ctx = createContext<SessionState | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [active, setActive] = useState<Workspace | null>(null);

  const loadWorkspaces = useCallback(async (s: Session | null) => {
    if (!s) { setWorkspaces([]); setActive(null); return; }
    const { data: ms } = await supabase
      .from('memberships')
      .select('id, org_id, role, active')
      .eq('user_id', s.user.id)
      .eq('active', true);
    const { data: orgs } = await supabase.from('orgs').select('*');
    const byId = new Map((orgs ?? []).map((o) => [o.id as string, o as Org]));
    const seen = new Set<string>();
    const list: Workspace[] = [];
    for (const m of (ms ?? []) as Membership[]) {
      const org = byId.get(m.org_id);
      if (!org) continue;
      const mode = MODE_FOR_ROLE[m.role];
      const key = `${mode}:${org.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      list.push({ mode, org });
    }
    setWorkspaces(list);
    // One workspace: go straight in. Several: let the person choose.
    setActive(list.length === 1 ? list[0] : null);
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      loadWorkspaces(data.session).finally(() => setLoading(false));
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      loadWorkspaces(s);
    });
    return () => sub.subscription.unsubscribe();
  }, [loadWorkspaces]);

  const signOut = useCallback(async () => { await supabase.auth.signOut(); }, []);

  const value = useMemo(
    () => ({ session, loading, workspaces, active, setActive, signOut }),
    [session, loading, workspaces, active, signOut],
  );
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSession(): SessionState {
  const v = useContext(Ctx);
  if (!v) throw new Error('useSession must be used inside SessionProvider');
  return v;
}
