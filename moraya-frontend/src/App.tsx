import { QueryClientProvider } from '@tanstack/react-query';
import { RouterProvider } from 'react-router-dom';
import { sessionKey } from './features/auth/useSession';
import { I18nProvider } from './i18n';
import { setSessionExpiredHandler } from './lib/api';
import { queryClient } from './lib/queryClient';
import { ToastProvider } from './components/ui/Toast';
import { router } from './router';
import { ThemeProvider } from './theme/ThemeProvider';

// Refresh failed after a 401 on a data endpoint: drop cached data and go to /login.
setSessionExpiredHandler(() => {
  queryClient.clear();
  queryClient.setQueryData(sessionKey, null);
  void router.navigate('/login', { replace: true });
});

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider>
        <I18nProvider>
          <ToastProvider>
            <RouterProvider router={router} />
          </ToastProvider>
        </I18nProvider>
      </ThemeProvider>
    </QueryClientProvider>
  );
}
