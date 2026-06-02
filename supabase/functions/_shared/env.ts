// Env access for Edge Functions. ALL secrets come from Deno.env — nothing is
// hardcoded. The full list of required/optional vars is documented in
// README-backend.md. Supabase auto-injects SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY; the rest are set via `supabase secrets set`.

/** Read a required env var; throw a clear error if missing (fail fast at boot). */
export function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (v === undefined || v === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return v;
}

/** Read an optional env var with a fallback. */
export function optionalEnv(name: string, fallback: string): string {
  const v = Deno.env.get(name);
  return v === undefined || v === "" ? fallback : v;
}

/** Read an optional integer env var with a fallback. */
export function optionalEnvInt(name: string, fallback: number): number {
  const v = Deno.env.get(name);
  if (v === undefined || v === "") return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) ? n : fallback;
}
