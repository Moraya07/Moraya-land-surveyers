import { useMemo } from 'react';
import { useSession } from '../auth/useSession';
import { canAccessPath, visibleNavItems, type NavItem } from './navConfig';

/** Nav items the signed-in user can see, plus a check for whether a link target is openable. UX only. */
export function useNavAccess(): { items: NavItem[]; canOpen: (path: string) => boolean } {
  const { data: user } = useSession();
  return useMemo(
    () => ({
      items: user ? visibleNavItems(user) : [],
      canOpen: (path: string) => (user ? canAccessPath(user, path) : false),
    }),
    [user],
  );
}
