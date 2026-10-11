export type Role = 'main_admin' | 'sub_admin' | 'worker';
export type AccountStatus = 'active' | 'inactive' | 'revoked';

export const PERMISSIONS = [
  'employee_management',
  'site_management',
  'verification',
  'income_management',
  'salary_management',
  'report_view',
  'export',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export interface Env {
  ENVIRONMENT: string;
  SUPABASE_URL: string;
  ALLOWED_ORIGIN: string;
  REFRESH_COOKIE_DAYS: string;
  PASSWORD_RESET_REDIRECT_URL: string;
  DEV_INSECURE_COOKIES?: string;
  // secrets
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  SUPABASE_JWT_SECRET?: string;
  ASSETS?: Fetcher;
}

/** Row returned by the get_auth_profile RPC. */
export interface Profile {
  id: string;
  auth_user_id: string;
  employee_id: string;
  name: string;
  login_email: string;
  role: Role;
  account_status: AccountStatus;
  permissions: string[];
}

export interface AuthUser {
  id: string;
  employeeId: string;
  name: string;
  email: string;
  role: Role;
  permissions: string[];
}

export interface AuthContext {
  authUserId: string;
  employee: Profile;
  role: Role;
  permissions: string[];
}

export type AppEnv = {
  Bindings: Env;
  Variables: { requestId: string; auth: AuthContext };
};

const REQUIRED = [
  'ENVIRONMENT',
  'SUPABASE_URL',
  'ALLOWED_ORIGIN',
  'REFRESH_COOKIE_DAYS',
  'PASSWORD_RESET_REDIRECT_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
] as const;

/** Fails fast with a clear message (variable NAMES only, never values). */
export function assertEnv(env: Env): void {
  const missing = REQUIRED.filter((k) => !env[k]);
  if (missing.length > 0) throw new Error(`Missing required environment variables: ${missing.join(', ')}`);

  const days = Number(env.REFRESH_COOKIE_DAYS);
  if (!Number.isInteger(days) || days < 1 || days > 90) throw new Error('REFRESH_COOKIE_DAYS must be an integer 1-90');
  try {
    new URL(env.SUPABASE_URL);
    new URL(env.ALLOWED_ORIGIN);
    new URL(env.PASSWORD_RESET_REDIRECT_URL);
  } catch {
    throw new Error('SUPABASE_URL, ALLOWED_ORIGIN and PASSWORD_RESET_REDIRECT_URL must be valid URLs');
  }
  if (env.ENVIRONMENT === 'production') {
    if (env.DEV_INSECURE_COOKIES === 'true') {
      throw new Error('DEV_INSECURE_COOKIES must not be enabled when ENVIRONMENT=production');
    }
    if (!env.ALLOWED_ORIGIN.startsWith('https://')) throw new Error('ALLOWED_ORIGIN must be https in production');
  }
}

export const isInsecureDev = (env: Env): boolean =>
  env.DEV_INSECURE_COOKIES === 'true' && env.ENVIRONMENT !== 'production';

export const supabaseUrl = (env: Env): string => env.SUPABASE_URL.replace(/\/+$/, '');
