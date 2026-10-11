import { supabaseUrl, type Env } from '../env';
import { AppError } from '../lib/errors';

export function serviceHeaders(env: Env, extra: Record<string, string> = {}): Record<string, string> {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
    ...extra,
  };
}

/** Calls a Postgres function with the service role. Any failure becomes a generic 500. */
export async function rpc<T>(env: Env, fn: string, args: Record<string, unknown>): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${supabaseUrl(env)}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: serviceHeaders(env),
      body: JSON.stringify(args),
    });
  } catch {
    console.warn(`rpc ${fn}: network error`);
    throw new AppError(500, 'INTERNAL_ERROR');
  }
  if (!res.ok) {
    console.warn(`rpc ${fn}: status ${res.status}`); // body intentionally not logged
    throw new AppError(500, 'INTERNAL_ERROR');
  }
  return (await res.json()) as T;
}
