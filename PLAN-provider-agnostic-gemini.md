# Plan: Provider-Agnostic Model Layer + Gemini (Managed Path)

Handoff plan for Claude Code. Goal: make the Managed `generate` edge function provider-agnostic behind a config-driven adapter layer, then add a Gemini chat (vision) provider. STT stays on OpenAI Whisper (`whisper-1`) because the interleaver requires segment-level timestamps, which `gpt-4o-transcribe`-family models do not support.

**Scope: Managed path only** (`supabase/functions/generate/`). The Swift BYOK path stays OpenAI-only for now — BYOK users bring an OpenAI key, so per-provider divergence there is correct, not drift. Update the KEEP-IN-SYNC comments to state this explicitly (see Step 8).

> **Reviewed & refined 2026-06-04 against the live codebase + Gemini docs.** Key changes from the original handoff are flagged inline as `[REVIEW]`. Headlines:
> - **The "Gemini 3 Pro" model does not exist.** Build the adapter provider-agnostic on the configured model name; default `CHAT_MODEL=gemini-3.5-flash` (GA-class, flat pricing) at rollout, with `gemini-3.1-pro-preview` also priced in the table for A/B.
> - **Gemini REST is camelCase and `mediaResolution` is per-part**, not in `generationConfig`. Thinking level is a new env secret `GEMINI_THINKING_LEVEL` (default `low`).
> - **The `openai_*`→`provider_*` error-string rename is confirmed safe**: the iOS `ManagedProxyClient.parse` keys `/generate` on HTTP status, never the 5xx body string (it reads the body only for 400/413/415 input-fuse errors, which we don't touch).
> - **Cost lookup needs a `provider` on `ChatResult`** and must key on the *configured* model, not the response `modelVersion`, or `est_cost_usd` silently goes null.
> - **Factory must take resolved provider/keys as args** (not read frozen `config.ts` consts) so its three branches are testable in one process.

---

## Context (current state)

- `handler.ts` already depends on an interface, not a vendor: it calls only `deps.openai.transcribe(audio)` (step 9) and `deps.openai.chat(systemPrompt, userContent)` (step 11).
- `openai.ts` defines `OpenAIClient { transcribe, chat }`, provider-neutral result types (`TranscriptionResult`, `ChatResult`), `OpenAIError { retryable, status }`, and `HttpOpenAIClient` (single retry on 429/5xx, AbortController timeout).
- `interleave.ts` → `buildInterleavedContent()` emits **OpenAI-shaped** `UserContentBlock`s (`image_url` data-URLs with `detail: "high"`). This is the only OpenAI wire format that leaks outside the transport.
- `config.ts` has `STT_MODEL` / `CHAT_MODEL` env-overridable secrets (defaults `whisper-1` / `gpt-4o`).
- `cost.ts` has hard-coded gpt-4o + whisper pricing.
- `index.ts` wires `HttpOpenAIClient(openaiKey)` into `handleGenerate`.
- `handler_test.ts` (580 lines) injects a stub client — tests never hit real APIs. All existing tests must keep passing.
- Money-safety ordering in `handler.ts` (transcribe → true-seconds gate → chat → consume credit) must NOT change.

## Target architecture

```
handler.ts ──► ModelDeps { stt: SttClient, chat: ChatClient }
                              │
              ┌───────────────┴────────────────┐
       providers/openai.ts            providers/gemini.ts
       (OpenAISttClient,              (GeminiChatClient)
        OpenAIChatClient)
                              ▲
                   providers/factory.ts  ◄── config.ts
                   (CHAT_PROVIDER / STT_PROVIDER secrets)
```

Key decisions:
- **Split STT and chat into two interfaces.** They are independent calls in the handler today; coupling them in one interface is what currently forces same-provider for both.
- **Neutral timeline blocks.** The interleaver emits provider-agnostic blocks; each chat adapter converts to its own wire format. Chronology/tagging logic stays shared and identical.
- **One secret flips the provider:** `supabase secrets set CHAT_PROVIDER=gemini CHAT_MODEL=gemini-3.5-flash` + redeploy.

---

## Step 1 — Neutral interfaces (`providers/types.ts`, new file)

Move/rename from `openai.ts`:

```ts
// Result types — copy as-is from openai.ts (they're already neutral).
export interface TranscriptionResult { segments: SpeechSegment[]; durationSeconds: number; }
// [REVIEW] Add `provider` — cost.ts keys its price table on `${provider}:${model}`
// and ChatResult.model carries the response modelVersion (which differs from the
// configured name), so without this the cost lookup has nothing to key on.
export interface ChatResult { provider: string; content: string; inputTokens: number; outputTokens: number; model: string; }
export interface AudioInput { bytes: Uint8Array; mime: string; filename: string; }

// Neutral timeline block — replaces the OpenAI-shaped UserContentBlock.
export type TimelineBlock =
  | { type: "text"; text: string }
  | { type: "image"; mime: string; base64: string };

export interface SttClient {
  transcribe(audio: AudioInput): Promise<TranscriptionResult>;
}
export interface ChatClient {
  chat(systemPrompt: string, content: TimelineBlock[]): Promise<ChatResult>;
}

// Rename OpenAIError → ProviderError; keep the exact shape and semantics
// (retryable on 429/5xx/timeout/network, terminal otherwise). Add a
// `provider` field ("openai" | "gemini") for log clarity.
export class ProviderError extends Error { ... }
```

Keep `openAIErrorResponse` in `handler.ts` working — rename to `providerErrorResponse`, same status mapping (retryable → 503 `generation_unavailable`/keep `openai_unavailable`, else → 502). **[REVIEW] The response-body error string is NOT a contract concern:** the iOS `ManagedProxyClient.parse` ([Zerro/Services/Managed/ManagedProxyClient.swift:265](Zerro/Services/Managed/ManagedProxyClient.swift)) maps `/generate` purely on HTTP status for 5xx/402/403/429, and reads the body string only for 400/413/415 input-fuse errors (which we don't change). No handler test asserts the 5xx body string either. So the internal `ProviderError.message` codes (`openai_*` / `gemini_*`) are free to diverge per adapter — they're for logs/adapter tests, not the wire. The `provider` field on `ProviderError` (`"openai" | "gemini"`) is for log clarity only.

The 4 `OpenAIError` constructor sites in `handler_test.ts` ([lines 353, 368, 380, 467](supabase/functions/generate/handler_test.ts)) become `ProviderError` — mechanical.

## Step 2 — Neutralize the interleaver (`interleave.ts`)

Change `buildInterleavedContent(frames, segments)` to return `TimelineBlock[]`:

- Frame item → `{ type: "text", text: "\n[M:SS] " }` then `{ type: "image", mime: "image/jpeg", base64 }`.
- Speech item → unchanged text block.
- **Do not touch** `mmss`, sorting, or the frame-before-speech tiebreak.
- `FrameInput` currently carries `dataUrl` (a `data:image/jpeg;base64,…` string). **[REVIEW] The data URL is built in exactly ONE place — [limits.ts:115](supabase/functions/generate/limits.ts:115), NOT handler.ts.** Change `FrameInput` to `{ timestamp, mime, base64 }` raw; `limits.ts` already has `frameMime` and the raw base64 `data` in hand, so it just stops concatenating the `data:` prefix. Data-URL construction moves into the OpenAI adapter.
- `detail: "high"` moves into the OpenAI adapter (it is OpenAI-specific).

## Step 3 — OpenAI adapter (`providers/openai.ts`)

Mostly a move of the existing `HttpOpenAIClient`, split in two:

- `OpenAISttClient implements SttClient` — the existing `transcribe()` verbatim (multipart, `verbose_json`, `timestamp_granularities[]=segment`, single retry, leading-space trim). Unchanged behavior.
- `OpenAIChatClient implements ChatClient` — existing `chat()`, plus a `toOpenAIContent(blocks: TimelineBlock[])` mapper:
  - text block → `{ type: "text", text }`
  - image block → `{ type: "image_url", image_url: { url: `data:${mime};base64,${base64}`, detail: "high" } }`
- Keep constructor injection of model/timeout/base URL (tests rely on `base` override).
- Byte-for-byte requirement: the OpenAI request produced after this refactor must be **identical** to today's. Verify with the existing capture-style tests in `handler_test.ts` (and extend one test to assert the exact content-block JSON if not already covered).

## Step 4 — Gemini adapter (`providers/gemini.ts`, new file)

`GeminiChatClient implements ChatClient`. (No Gemini STT in this phase.)

- **[REVIEW] Model:** there is no `gemini-3-pro`. The adapter is provider-agnostic on the configured `CHAT_MODEL`; ship `gemini-3.5-flash` as the rollout default (GA-class, flat pricing) with `gemini-3.1-pro-preview` also priced (Step 7) for A/B.
- Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/{CHAT_MODEL}:generateContent`
  - Auth header: `x-goog-api-key: <GEMINI_API_KEY>` (do NOT put the key in the URL query string — it ends up in logs).
- **[REVIEW] Request body mapping — verified camelCase against ai.google.dev (2026-06-04). `mediaResolution` nests PER-PART inside each image, not in `generationConfig`:**

```jsonc
{
  "systemInstruction": { "parts": [{ "text": systemPrompt }] },
  "contents": [{
    "role": "user",
    "parts": [
      { "text": "\n[0:00] " },                                   // text block
      {                                                           // image block
        "inlineData": { "mimeType": "image/jpeg", "data": "<base64>" },
        "mediaResolution": { "level": "media_resolution_high" }   // per-part; analog of detail:"high"
      }
      // ...
    ]
  }],
  "generationConfig": {
    "thinkingConfig": { "thinkingLevel": GEMINI_THINKING_LEVEL }  // env secret, default "low" (Step 6)
  }
}
```

  - **[REVIEW]** Thinking level is configurable via the new `GEMINI_THINKING_LEVEL` secret (default `low` — this is a structured rewrite, not a reasoning task; `high` adds latency + billed output tokens). Do NOT also send the legacy `thinking_budget` — combining them is a 400.
  - Re-verify field names against https://ai.google.dev/gemini-api/docs/gemini-3 and https://ai.google.dev/gemini-api/docs/media-resolution at implementation time; the REST API also accepts snake_case aliases, but emit camelCase to match the docs.
- Response mapping → `ChatResult` (set `provider: "gemini"`):
  - `content` ← `candidates[0].content.parts[]` text parts concatenated. Treat empty/missing content, or `promptFeedback.blockReason` / `finishReason` of `SAFETY`/`RECITATION`/`PROHIBITED_CONTENT`, as the existing non-retryable "empty content" case (`gemini_empty_content`). **Note: with `thinkingLevel` set, parts may include `thought`-flagged parts — concatenate only the visible text parts (skip `part.thought === true`).**
  - `inputTokens` ← `usageMetadata.promptTokenCount`
  - `outputTokens` ← `usageMetadata.candidatesTokenCount` + `usageMetadata.thoughtsTokenCount` (present when thinking is on; billed as output, so include it for honest cost).
  - `model` ← `modelVersion` if present, else configured model name. (Used for logging only — cost keys on the *configured* model, see Step 7.)
- Transport: reuse the same pattern as OpenAI — AbortController timeout (`PROVIDER_TIMEOUT_MS`, see Step 6), single retry on 429/5xx, `ProviderError` classification (401/403 → non-retryable auth; 429/5xx → retryable; other 4xx → non-retryable).
- Safety settings: leave defaults in this phase; if screen recordings trip false-positive blocks in practice, revisit with explicit `safetySettings` later.

## Step 5 — Factory (`providers/factory.ts`, new file) + `index.ts` wiring

**[REVIEW] Factories take resolved provider/keys as ARGS — they must NOT read the `config.ts` consts directly.** `config.ts` evaluates `CHAT_PROVIDER` etc. into module-level `const`s at first import, so a factory that closes over them can't be exercised with three different provider values in one test process (Test #5 requires openai / gemini / unknown in the same file). Pass them in; `index.ts` owns env resolution.

```ts
export function makeSttClient(opts: { provider: string; openaiKey: string }): SttClient   // switch on opts.provider
export function makeChatClient(opts: { provider: string; model: string; openaiKey: string; geminiKey?: string; thinkingLevel?: string }): ChatClient
```

- Unknown provider value → throw at startup (fail loud, not at request time).
- `index.ts`: read `OPENAI_API_KEY` always (Whisper STT needs it); read `GEMINI_API_KEY` via `requireEnv` **only when** `CHAT_PROVIDER === "gemini"` (don't hard-require a secret the deployment doesn't use). `index.ts` reads the `config.ts` consts and passes them into the factories.
- `handler.ts` deps change: `{ openai: OpenAIClient }` → `{ stt: SttClient, chat: ChatClient }`. **[REVIEW] Test churn is minimal:** one `StubProvider implements SttClient, ChatClient` passed as `{ stt: stub, chat: stub }` keeps the existing `StubOpenAI` body (transcribe + chat) intact — just rename and update the `deps()` helper.

## Step 6 — Config (`config.ts`)

```ts
export const STT_PROVIDER = optionalEnv("STT_PROVIDER", "openai");
export const STT_MODEL    = optionalEnv("STT_MODEL", "whisper-1");
export const CHAT_PROVIDER = optionalEnv("CHAT_PROVIDER", "openai"); // flip to gemini at rollout
export const CHAT_MODEL    = optionalEnv("CHAT_MODEL", "gpt-4o");    // flip to gemini-3.5-flash at rollout

// [REVIEW] Gemini thinking depth — "low" | "high". Default "low": the generation
// task is a structured rewrite, not a reasoning problem, so high just adds
// latency + billed output (thinking) tokens. Tunable server-side without redeploy.
export const GEMINI_THINKING_LEVEL = optionalEnv("GEMINI_THINKING_LEVEL", "low");

// [REVIEW] Timeout rename with fallback — nest optionalEnvInt, no new helper needed:
export const PROVIDER_TIMEOUT_MS = optionalEnvInt(
  "GENERATE_PROVIDER_TIMEOUT_MS",
  optionalEnvInt("GENERATE_OPENAI_TIMEOUT_MS", 120_000), // legacy fallback so tuned deploys don't reset
);
```

- Keep code defaults = current production behavior (openai/gpt-4o); the Gemini switch happens via secrets at rollout (Step 9), not via code defaults. This keeps the refactor a pure no-op until deliberately flipped.

## Step 7 — Cost table (`cost.ts`)

Replace hard-coded constants with a per-provider/model table. **[REVIEW] Pricing verified at ai.google.dev/gemini-api/docs/pricing on 2026-06-04. `gemini-3.1-pro-preview` is TIERED by prompt size (≤200k vs >200k input tokens) — a 3-min recording with ~90–120 high-res frames can cross 200k input tokens, so a flat rate would misprice. Model `gemini-3.5-flash` is flat. Output rates already include thinking tokens (we fold `thoughtsTokenCount` into `outputTokens` in Step 4).**

```ts
// inPerM/outPerM in USD per 1M tokens. tierThreshold/…Above present only for tiered models.
const CHAT_PRICING: Record<string, {
  inPerM: number; outPerM: number;
  tierThreshold?: number; inPerMAbove?: number; outPerMAbove?: number;
}> = {
  "openai:gpt-4o":               { inPerM: 2.5,  outPerM: 10.0 },                      // 2026-05-28 list
  "gemini:gemini-3.5-flash":     { inPerM: 1.5,  outPerM: 9.0 },                       // 2026-06-04, flat, incl. thinking
  "gemini:gemini-3.1-pro-preview": {                                                   // 2026-06-04, tiered by input tokens
    inPerM: 2.0, outPerM: 12.0, tierThreshold: 200_000, inPerMAbove: 4.0, outPerMAbove: 18.0,
  },
};
const STT_PRICING: Record<string, { perMinute: number }> = {
  "openai:whisper-1": { perMinute: 0.006 },                                            // 2026-05-28 list
};
```

- **[REVIEW] Lookup key = `${provider}:${CONFIGURED_MODEL}`, NOT the response `modelVersion`.** Gemini returns `modelVersion` like `gemini-3.1-pro-preview-…` which won't match the table key → silent `null` cost, violating the acceptance criterion. `chatCostUsd` must take `(provider, configuredModel, inputTokens, outputTokens)`; pass `CHAT_PROVIDER` + `CHAT_MODEL` (or the `provider` stamped on `ChatResult` + the configured model) from the handler — do not pass `chat.model`.
- For a tiered model, pick the rate by `inputTokens` vs `tierThreshold` (Gemini tiers on total input/prompt tokens).
- Unknown key → log a warning and record `est_cost_usd: null` rather than a wrong number (the column is informational; never block generation on a missing price).
- `whisperCostUsd` stays (STT is still whisper); generalize the function names (`sttCostUsd`, `chatCostUsd`) but keep the handler's call sites doing exactly what they do today (whisper cost logged on chat failure, etc.).

## Step 8 — Docs & sync markers

- `README-backend.md`: document `CHAT_PROVIDER`, `STT_PROVIDER`, `GEMINI_API_KEY`, **`GEMINI_THINKING_LEVEL`**, the `GENERATE_PROVIDER_TIMEOUT_MS` rename (with `GENERATE_OPENAI_TIMEOUT_MS` fallback), and the one-secret provider-switch procedure. The existing secrets table is at [README-backend.md:94](README-backend.md) (`OPENAI_API_KEY` / `STT_MODEL` / `CHAT_MODEL` / `GENERATE_OPENAI_TIMEOUT_MS` rows).
- Update KEEP-IN-SYNC headers in `interleave.ts`, `prompt.ts`, and the Swift files they reference: the **interleaving algorithm and system prompt remain byte-identical** across BYOK/Managed, but the **wire format and chat model are now per-provider**; BYOK is intentionally OpenAI-only. State this so a future change doesn't "fix" the divergence.
- `SECURITY-RUNBOOK.md`: add `GEMINI_API_KEY` to the secret inventory/rotation list.

## Step 9 — Rollout (operator steps, include in the PR description)

1. Deploy the refactor with defaults unchanged (`CHAT_PROVIDER=openai`). Verify a real Managed generation still works and `generation_log` rows look normal. This isolates refactor bugs from provider bugs.
2. `supabase secrets set GEMINI_API_KEY=... CHAT_PROVIDER=gemini CHAT_MODEL=gemini-3.5-flash` + redeploy. (For the Pro A/B: `CHAT_MODEL=gemini-3.1-pro-preview`; optionally `GEMINI_THINKING_LEVEL=high`.)
3. Run 3–5 real recordings through both providers (flip the secret back and forth) and compare Instruct/Explain output quality and `est_cost_usd`.
4. **[REVIEW] When A/B-ing `gemini-3.1-pro-preview`, run it at BOTH `GEMINI_THINKING_LEVEL=low` and `=high`** on the same recordings, so model quality is isolated from thinking depth (otherwise a Pro-vs-Flash gap could just be a thinking-level gap). Compare latency + `est_cost_usd` at each level too — `high` bills the extra `thoughtsTokenCount` at the output rate.
5. Keep `CHAT_PROVIDER=openai` as the documented instant-rollback path.

---

## Testing requirements

All in `handler_test.ts` + new `providers/*_test.ts` (Deno test, stub fetch — never hit real APIs, matching the existing pattern):

1. **No-regression:** all existing handler tests pass with the new `{ stt, chat }` deps (mechanical stub rename).
2. **OpenAI wire parity:** a capture test asserting the exact JSON body `OpenAIChatClient` sends for a known `TimelineBlock[]` — must match today's format byte-for-byte (`image_url` data-URL, `detail: "high"`, leading-newline tags, frame-before-speech order).
3. **Gemini mapping:** given the same `TimelineBlock[]`, assert the `generateContent` body — parts order preserved, `inlineData.mimeType`/`data` correct, **per-part `mediaResolution`**, `systemInstruction` populated, `thinkingConfig.thinkingLevel` reflects `GEMINI_THINKING_LEVEL`, and the key is in the `x-goog-api-key` header (NOT the URL).
4. **Gemini response parsing:** content concatenation (**skipping `thought`-flagged parts**), usageMetadata mapping (incl. `thoughtsTokenCount` folded into outputTokens), empty-content / `blockReason` / `finishReason: SAFETY` → non-retryable `ProviderError`, 429/5xx → retryable with single retry.
5. **Factory:** correct client per provider arg; unknown provider throws; **all three branches exercised in one test process** (only possible because factories take args, not frozen config consts); `GEMINI_API_KEY` only required when chat provider is gemini.
6. **Cost:** known keys priced correctly **including the `gemini-3.1-pro-preview` >200k-token tier**; cost keys on the *configured* model (not response `modelVersion`); unknown `provider:model` → null + warning, generation still succeeds.
7. **Money-safety ordering untouched:** transcribe-fail charges nothing; chat-fail logs whisper cost only; credit consumed only after usable chat result. (Existing tests should cover this — confirm they still do.)

## Explicit non-goals (do not do)

- No Swift/BYOK changes beyond comment updates (Step 8).
- No STT provider change (whisper-1 stays; the interleaver needs segment timestamps).
- No prompt or interleaving-order changes (frame resolution / JPEG quality / dedup tuning is a separate follow-up).
- No streaming, no reserve-then-commit billing (Phase G), no client-visible API changes — the `/generate` request/response contract is identical.

## Acceptance criteria

- `deno test` green across the function.
- With secrets unset (defaults): behavior and OpenAI request bytes identical to main.
- With `CHAT_PROVIDER=gemini`: a real recording produces a sensible Instruct/Explain prompt, `generation_log` records token counts and a non-null `est_cost_usd`, and a forced Gemini 500 (stubbed) charges no credit.
- Switching providers requires only `supabase secrets set` + redeploy — zero code changes.
