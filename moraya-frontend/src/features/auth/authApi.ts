import { request } from '../../lib/api';
import type { LoginValues } from './schemas';

export type Role = 'main_admin' | 'sub_admin' | 'worker';

export interface AuthUser {
  id: string;
  employeeId: string;
  name: string;
  email: string;
  role: Role;
  permissions: string[];
}

export interface LoginResponse {
  user: AuthUser;
  redirectTo: string;
}

export const authApi = {
  login: (values: LoginValues) => request<LoginResponse>('/auth/login', { method: 'POST', body: values }),
  me: () => request<{ user: AuthUser }>('/auth/me'),
  logout: () => request<void>('/auth/logout', { method: 'POST' }),
  forgotPassword: (email: string) =>
    request<{ ok: true }>('/auth/forgot-password', { method: 'POST', body: { email } }),
};
