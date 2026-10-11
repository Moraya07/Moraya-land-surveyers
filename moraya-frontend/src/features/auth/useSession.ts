import { useQuery } from '@tanstack/react-query';
import { ApiError } from '../../lib/errors';
import { authApi, type AuthUser } from './authApi';

export const sessionKey = ['auth', 'me'] as const;

/** data: AuthUser when signed in, null when not, undefined while loading. No polling. */
export function useSession() {
  return useQuery<AuthUser | null>({
    queryKey: sessionKey,
    queryFn: async () => {
      try {
        return (await authApi.me()).user;
      } catch (e) {
        if (e instanceof ApiError && e.status === 401) return null;
        throw e;
      }
    },
    staleTime: 5 * 60_000,
    refetchOnWindowFocus: false,
    retry: false,
  });
}
