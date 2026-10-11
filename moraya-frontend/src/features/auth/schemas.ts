import { z } from 'zod';
import type { DictKey } from '../../i18n/en';

// Messages are dictionary keys, translated at render time.
const k = (key: DictKey): DictKey => key;

const email = z
  .string()
  .trim()
  .toLowerCase()
  .min(1, k('err.emailRequired'))
  .max(254, k('err.emailTooLong'))
  .email(k('err.emailInvalid'));

export const loginSchema = z.object({
  email,
  // Passwords are never trimmed and get no complexity rules on login.
  password: z.string().min(1, k('err.passwordRequired')).max(128, k('err.passwordTooLong')),
});
export const forgotSchema = z.object({ email });

export type LoginValues = z.infer<typeof loginSchema>;
export type ForgotValues = z.infer<typeof forgotSchema>;
