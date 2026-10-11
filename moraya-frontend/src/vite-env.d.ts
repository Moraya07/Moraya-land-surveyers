/// <reference types="vite/client" />
interface ImportMetaEnv {
  readonly VITE_APP_NAME?: string;
  /** Dev only: serve the admin dashboard from typed mock data instead of the API. */
  readonly VITE_USE_MOCK_DASHBOARD?: string;
  /** Dev only: serve /api/admin/employees from the in-memory mock (ignored in production builds). */
  readonly VITE_USE_MOCK_EMPLOYEES?: string;
}
interface ImportMeta {
  readonly env: ImportMetaEnv;
}
