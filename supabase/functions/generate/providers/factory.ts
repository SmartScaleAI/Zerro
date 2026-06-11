// =============================================================================
// Provider factory — selects the STT / chat adapter from the configured
// provider, with the resolved API keys passed IN (not read from config here).
// =============================================================================
// The factories take provider + keys as ARGUMENTS rather than reading the
// config.ts consts directly: those consts are evaluated once at module import,
// so a factory closing over them couldn't be exercised with multiple provider
// values in one test process. index.ts owns env resolution and passes the
// values in; tests call the factory directly with explicit args.
//
// Unknown provider → throw HERE (at wiring time, fail loud) rather than at
// request time.
// =============================================================================

import { type ChatClient, type SttClient } from "./types.ts";
import { OpenAIChatClient, OpenAISttClient } from "./openai.ts";
import { GeminiChatClient } from "./gemini.ts";
import { AnthropicChatClient } from "./anthropic.ts";

export function makeSttClient(opts: { provider: string; openaiKey: string }): SttClient {
  switch (opts.provider) {
    case "openai":
      return new OpenAISttClient(opts.openaiKey);
    default:
      throw new Error(`Unknown STT_PROVIDER: ${opts.provider}`);
  }
}

export function makeChatClient(
  opts: {
    provider: string;
    model: string;
    openaiKey: string;
    geminiKey?: string;
    anthropicKey?: string;
    thinkingLevel?: string;
  },
): ChatClient {
  switch (opts.provider) {
    case "openai":
      return new OpenAIChatClient(opts.openaiKey, opts.model);
    case "gemini":
      if (!opts.geminiKey) throw new Error("GEMINI_API_KEY required when CHAT_PROVIDER=gemini");
      return new GeminiChatClient(opts.geminiKey, opts.model, opts.thinkingLevel);
    case "anthropic":
      if (!opts.anthropicKey) {
        throw new Error("ANTHROPIC_API_KEY required when CHAT_PROVIDER=anthropic");
      }
      return new AnthropicChatClient(opts.anthropicKey, opts.model);
    default:
      throw new Error(`Unknown CHAT_PROVIDER: ${opts.provider}`);
  }
}
