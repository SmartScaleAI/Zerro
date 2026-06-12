// =============================================================================
// convert — Deno.serve entrypoint (Phase 6). Thin wiring only; the full flow
// lives in handler.ts (unit-testable with injected deps).
// =============================================================================
// Deployed with verify_jwt = false at the Supabase gateway — exactly like
// `generate`: we verify OUR OWN session JWT in code.
//
// No STT here (text in, text out), so NO provider key is hard-required at
// boot: all three are read optionally and a request selecting a keyless
// provider fails as a clean 503 at the makeChat seam. The store is only used
// for the rate-limit RPC.
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { handleConvert } from "./handler.ts";
import { GEMINI_THINKING_LEVEL } from "./config.ts";
import { makeChatClient } from "../generate/providers/factory.ts";
import { SupabaseBillingStore } from "../generate/store.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  const openaiKey = optionalEnv("OPENAI_API_KEY", "");
  const geminiKey = optionalEnv("GEMINI_API_KEY", "") || undefined;
  const anthropicKey = optionalEnv("ANTHROPIC_API_KEY", "") || undefined;

  return await handleConvert(req, {
    store: new SupabaseBillingStore(serviceClient()),
    makeChat: (provider: string, model: string) => {
      // The factory requires openaiKey as a plain string; guard the empty
      // optional here so a keyless OpenAI selection throws (→ clean 503)
      // instead of riding an empty bearer to the provider.
      if (provider === "openai" && !openaiKey) {
        throw new Error("OPENAI_API_KEY required when the selected model is OpenAI");
      }
      return makeChatClient({
        provider,
        model,
        openaiKey,
        geminiKey,
        anthropicKey,
        thinkingLevel: GEMINI_THINKING_LEVEL,
      });
    },
    jwtSecret,
  });
});
