// =============================================================================
// trial-start — Deno.serve entrypoint (Phase F). Thin wiring only; the full flow
// lives in handler.ts (so it's unit-testable with injected deps).
// =============================================================================
// Deployed with verify_jwt = false: this is an UNAUTHENTICATED public endpoint
// (the user is mid-trial with no credential yet). Security is the rate limit +
// hashed/TTL'd code + disposable block + one-grant-per-email cap, all in code.
//
// Secrets read HERE and handed down: SESSION_JWT_SECRET (mints the trial token,
// same secret the rest of the billing functions verify against) and
// RESEND_API_KEY (delivers the code). Neither is logged or returned.
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { handleTrialStart } from "./handler.ts";
import { ResendEmailSender } from "./resend.ts";
import { SupabaseTrialStore } from "./store.ts";
import { TRIAL_EMAIL_FROM } from "./config.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  const resendKey = requireEnv("RESEND_API_KEY");

  return await handleTrialStart(req, {
    store: new SupabaseTrialStore(serviceClient()),
    email: new ResendEmailSender(resendKey, TRIAL_EMAIL_FROM),
    jwtSecret,
  });
});
