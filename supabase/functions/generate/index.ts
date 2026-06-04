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
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { handleGenerate } from "./handler.ts";
import { CHAT_MODEL, CHAT_PROVIDER, GEMINI_THINKING_LEVEL, STT_PROVIDER } from "./config.ts";
import { makeChatClient, makeSttClient } from "./providers/factory.ts";
import { SupabaseBillingStore } from "./store.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  // Whisper STT always needs the OpenAI key (STT stays OpenAI this phase).
  const openaiKey = requireEnv("OPENAI_API_KEY");
  // Only hard-require the Gemini key when the chat provider actually uses it.
  const geminiKey = CHAT_PROVIDER === "gemini" ? requireEnv("GEMINI_API_KEY") : undefined;

  return await handleGenerate(req, {
    store: new SupabaseBillingStore(serviceClient()),
    stt: makeSttClient({ provider: STT_PROVIDER, openaiKey }),
    chat: makeChatClient({
      provider: CHAT_PROVIDER,
      model: CHAT_MODEL,
      openaiKey,
      geminiKey,
      thinkingLevel: GEMINI_THINKING_LEVEL,
    }),
    jwtSecret,
  });
});
