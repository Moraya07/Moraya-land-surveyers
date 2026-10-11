import type { Context } from 'hono';
import { z } from 'zod';
import { AppError } from './errors';

const MAX_BODY_BYTES = 4096;

const email = z.string().trim().toLowerCase().min(1).max(254).email();

// .strict() rejects unknown keys. Passwords are never trimmed.
export const loginSchema = z.object({ email, password: z.string().min(1).max(128) }).strict();
export const forgotPasswordSchema = z.object({ email }).strict();

export async function readJson<S extends z.ZodTypeAny>(c: Context, schema: S): Promise<z.infer<S>> {
  const contentType = c.req.header('Content-Type') ?? '';
  if (!/^application\/json\s*(;.*)?$/i.test(contentType)) throw new AppError(400, 'VALIDATION_ERROR');
  if (Number(c.req.header('Content-Length') ?? '0') > MAX_BODY_BYTES) throw new AppError(400, 'VALIDATION_ERROR');

  const text = await c.req.text();
  if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) throw new AppError(400, 'VALIDATION_ERROR');

  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    throw new AppError(400, 'VALIDATION_ERROR');
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new AppError(400, 'VALIDATION_ERROR'); // issues are never echoed back
  return parsed.data;
}
