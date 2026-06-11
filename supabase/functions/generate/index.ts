// =============================================================================
// generate — Deno.serve entrypoint (Phase D2). Thin wiring only; the full flow
// lives in handler.ts (so it's unit-testable with injected deps).
// =============================================================================
// Deployed with verify_jwt = false at the Supabase gateway — exactly like
// `entitlement`. We verify OUR OWN session JWT (HS256, SESSION_JWT_SECRET) IN
// CODE inside handleGenerate; if the gateway also demanded a Supabase JWT it
// would reject the app's token before our code runs. See config.toml /
// README-backend.md.
//
// Provider keys are read HERE and handed to the adapter factories. OPENAI_API_KEY
// is always required (Whisper STT). They are never returned to the client or
// logged.
//
// F2 (multi-model Phase 3): the chat client is no longer built once at startup —
// the model is chosen per request, so we inject a makeChat FACTORY (closing over
// all resolved provider keys) and the handler builds the right adapter when it
// knows the selected provider+model.
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { handleGenerate } from "./handler.ts";
import { CHAT_PROVIDER, GEMINI_THINKING_LEVEL, STT_PROVIDER } from "./config.ts";
import { makeChatClient, makeSttClient } from "./providers/factory.ts";
import { SupabaseBillingStore } from "./store.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  // Whisper STT always needs the OpenAI key (STT stays OpenAI this phase).
  const openaiKey = requireEnv("OPENAI_API_KEY");
  // Per-request model selection (F2) needs ALL provider keys available. Read
  // them optionally so the function still boots with any subset configured —
  // a request selecting a provider whose key is unset fails clearly at the
  // factory ("X_API_KEY required when CHAT_PROVIDER=x"). The env-DEFAULT
  // provider's key stays hard-required (fail fast, same as before F2).
  const geminiKey = optionalEnv("GEMINI_API_KEY", "") || undefined;
  const anthropicKey = optionalEnv("ANTHROPIC_API_KEY", "") || undefined;
  if (CHAT_PROVIDER === "gemini") requireEnv("GEMINI_API_KEY");
  if (CHAT_PROVIDER === "anthropic") requireEnv("ANTHROPIC_API_KEY");

  return await handleGenerate(req, {
    store: new SupabaseBillingStore(serviceClient()),
    stt: makeSttClient({ provider: STT_PROVIDER, openaiKey }),
    makeChat: (provider: string, model: string) =>
      makeChatClient({
        provider,
        model,
        openaiKey,
        geminiKey,
        anthropicKey,
        thinkingLevel: GEMINI_THINKING_LEVEL,
      }),
    jwtSecret,
  });
});
