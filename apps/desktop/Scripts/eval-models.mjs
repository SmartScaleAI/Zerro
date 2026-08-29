#!/usr/bin/env node
// =============================================================================
// eval-models.mjs — standalone model A/B harness for Zerro recordings.
// =============================================================================
// Compares chat/vision models on a REAL recording without the app, using your
// own provider keys. It replicates the app's generation pipeline faithfully:
//   1. Transcribes the recording's audio with whisper-1 (verbose_json,
//      segment granularity) — same request as the app.
//   2. Composes the EXACT locked system prompt (the v2 text, extracted at
//      run time from Scripts/artifact-eval/prompt-v2.md).
//   3. Interleaves frames + transcript chronologically with the
//      frame-before-speech tiebreak and [M:SS] tags — same algorithm as
//      InterleavedTimeline.swift.
//   4. Sends the identical payload to each requested model (OpenAI or
//      Gemini wire format, matching the app's provider requests).
//   5. Writes side-by-side outputs + token/cost/latency to an output dir.
//
// KEEP IN SYNC (read-only mirrors; the app's Swift pipeline is the live
// counterpart — if it changes, update here):
//   - Scripts/artifact-eval/prompt-v2.md           (prompt — READ AT RUN TIME,
//     never copied here; the Swift copy is byte-identity-tested against the
//     same mirror)
//   - Zerro/Services/InterleavedTimeline.swift     (mmss, tiebreak, tags)
//   (Historical: the prompt, interleaving, wire shapes, and pricing were
//   first mirrored from the server-side generate function — interleave.ts,
//   providers/openai.ts, providers/gemini.ts, cost.ts — which has since been
//   removed from the repository and is no longer a copy to keep in sync.)
//
// INPUT: a Zerro working directory (manifest.json + audio + frame JPEGs).
// Find one by recording with the app; the working dir is cleaned up after a
// successful generation, so either grab it mid-flight or use a debug build
// that preserves it. You can also hand-build one: manifest.json with
// { audioFilename, durationSeconds, frames: [{ index, filename, timestampSeconds }] }.
// Optional Phase 6 field: `hasSpeech: false` makes the harness skip Whisper
// (empty transcript), mirroring the live no-speech gate; absent → transcribe.
//
// USAGE:
//   The harness uses DEDICATED DEV KEYS ONLY — never production keys. Each must
//   be minted in a separate, rate-capped project/workspace; the harness hard-stops
//   if the relevant one is unset and never falls back to the plain *_API_KEY, so
//   test bursts can't rate-limit your live users.
//   export OPENAI_API_KEY_DEV=sk-...         # required (Whisper STT + openai:* models)
//   export GEMINI_API_KEY_DEV=...            # required for gemini:* models
//   export ANTHROPIC_API_KEY_DEV=sk-ant-...  # required for anthropic:* models
//       (Anthropic's cap lives on a separate Console *workspace* — org limits are
//        shared, so a bare second key does NOT isolate them. For OpenAI/Gemini,
//        mint the dev key in a separate project with its own limits/quota.)
//   node Scripts/eval-models.mjs <workingDir> \
//     --models gemini:gemini-3.5-flash,gemini:gemini-3.1-pro-preview,openai:gpt-4o \
//     [--thinking low|high]               # gemini only, default low
//     [--out eval-results]                # output dir, default ./eval-results
//
// The transcript is cached per working dir (transcript.eval.json) so repeated
// runs against different models don't re-pay Whisper.
//
// ARTIFACT MODE (refactor Phase 0 — docs/refactor-artifact-response-plan.md):
//   node Scripts/eval-models.mjs --artifact \
//     --models gemini:gemini-3.5-flash,anthropic:claude-sonnet-4-6 \
//     [--fixtures Scripts/artifact-eval/fixtures.json]   # default
//     [--system-prompt path]                # default: the locked v2 mirror;
//                                           # .md → first fenced block, .txt → raw
//     [--only ap-01-...,ch-04-...]          # run a subset of fixture ids
//     [--concurrency 2]                     # default 2 (gentle ramp); raise for
//                                           # high-limit keys, drop to 1 if throttled
//     [--thinking low|high] [--out eval-results/artifact]
// Scores text-only labeled fixtures against the typed-artifact output contract
// (plan §2). No recording, no Whisper, no images — see the section below.
// =============================================================================

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, basename, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

// ---------- system prompt (extracted from the locked in-repo mirror) ---------
// Typed-artifact refactor: the v1 BASE/INSTRUCT/EXPLAIN copies are gone. The
// harness now reads the LOCKED v2 prompt from Scripts/artifact-eval/
// prompt-v2.md (first fenced block) at run time — the same mirror
// PromptV2MirrorTests holds the Swift copy byte-identical to — so this file
// can no longer drift from the app's prompt text.

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROMPT_MIRROR_PATH = join(SCRIPT_DIR, "artifact-eval", "prompt-v2.md");

function composedSystemPrompt() {
  const md = readFileSync(PROMPT_MIRROR_PATH, "utf8");
  const m = md.match(/(?:^|\n)\u0060\u0060\u0060\n([\s\S]*?)\n\u0060\u0060\u0060(?:\n|$)/);
  if (!m) {
    console.error(`no fenced block found in ${PROMPT_MIRROR_PATH} — mirror format changed?`);
    process.exit(1);
  }
  return m[1];
}

// ---------- pricing (CHAT_PRICING; Swift twin: BYOKCostEstimator) ----------
// EVERY model in the eval matrix (README-eval.md) must be priced here so no
// run shows "unpriced". If a model is added to the matrix, add it here. USD per 1M tokens; Gemini
// output rates already fold in thinking tokens (we add thoughtsTokenCount into
// outputTokens, matching the app's Gemini adapter). Anthropic output rates
// likewise fold in any thinking tokens that ride in output_tokens.
//
// KEEP IN SYNC: the app's BYOKCostEstimator (Zerro/Services/BYOKRouting.swift)
// carries the same rates for the in-app cost display, pinned literally by
// BYOKRoutingTests. Neither table leads the other; a rate change lands in
// BOTH. (This table was originally mirrored from the server-side cost.ts,
// since removed from the repository.)
//
// Rates verified against provider docs 2026-06-09:
//   OpenAI    https://developers.openai.com/api/docs/pricing
//   Gemini    https://ai.google.dev/gemini-api/docs/pricing
//   Anthropic https://platform.claude.com/docs/en/about-claude/models/overview
//
// NOTE: `gpt-5.4-mini` is the cheapest GPT-5-family mini that actually exists at
// OpenAI (the plan's §1.1 "gpt-5-mini" id was a non-existent placeholder). It is
// now DISABLED in the app registry (ModelRegistry.swift `enabled: false`), so it is not part of
// the harness's default model set — but its price row stays so an explicitly
// `--models openai:gpt-5.4-mini` run (e.g. re-pricing a historic eval) still
// prices instead of showing "unpriced".
const CHAT_PRICING = {
  // — legacy / prior eval baseline —
  "openai:gpt-4o": { inPerM: 2.5, outPerM: 10.0 }, // 2026-05-28 list
  // — the six Phase 0 candidates —
  "openai:gpt-5.4-mini": { inPerM: 0.75, outPerM: 4.5 }, // registry-disabled; priced for historic/explicit runs
  "openai:gpt-5.5": { inPerM: 5.0, outPerM: 30.0 },
  "gemini:gemini-3.5-flash": { inPerM: 1.5, outPerM: 9.0 }, // flat
  "gemini:gemini-3.1-pro-preview": { // tiered by input tokens (>200k raises both rates)
    inPerM: 2.0, outPerM: 12.0, tierThreshold: 200_000, inPerMAbove: 4.0, outPerMAbove: 18.0,
  },
  "anthropic:claude-sonnet-4-6": { inPerM: 3.0, outPerM: 15.0 },
  "anthropic:claude-opus-4-7": { inPerM: 5.0, outPerM: 25.0 },
};
const WHISPER_PER_MINUTE = 0.006;

function chatCostUsd(key, inputTokens, outputTokens) {
  const p = CHAT_PRICING[key];
  if (!p) return null;
  const tiered = p.tierThreshold !== undefined && inputTokens > p.tierThreshold;
  const inRate = tiered ? p.inPerMAbove : p.inPerM;
  const outRate = tiered ? p.outPerMAbove : p.outPerM;
  return (inputTokens / 1e6) * inRate + (outputTokens / 1e6) * outRate;
}

// ---------- interleaving (mirror of InterleavedTimeline.swift) --------------

function mmss(seconds) {
  const total = Math.floor(Math.max(0, seconds));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

/** Neutral timeline: text blocks + image blocks, chronological, frame<click<speech. */
function buildTimeline(frames, segments, clicks = []) {
  const tieRank = (k) => (k === "frame" ? 0 : k === "click" ? 1 : 2);
  const items = [
    ...frames.map((f) => ({ kind: "frame", start: f.timestampSeconds, base64: f.base64, ocrText: f.ocrText })),
    ...segments.map((s) => ({ kind: "speech", start: s.start, end: s.end, text: s.text })),
    // Phase 4: clicks join the same merge; empty labels are dropped.
    ...clicks.filter((c) => c.label).map((c) => ({ kind: "click", start: c.timestampSeconds, label: c.label })),
  ];
  items.sort((a, b) => (a.start !== b.start ? a.start - b.start : tieRank(a.kind) - tieRank(b.kind)));
  const blocks = [];
  for (const it of items) {
    if (it.kind === "frame") {
      blocks.push({ type: "text", text: `\n[${mmss(it.start)}] ` });
      blocks.push({ type: "image", mime: "image/jpeg", base64: it.base64 });
      // Phase 3: redacted on-screen text after the image (mirror InterleavedTimeline.swift).
      if (it.ocrText) blocks.push({ type: "text", text: `\n[${mmss(it.start)}] on-screen text: ${it.ocrText}` });
    } else if (it.kind === "click") {
      // Phase 4: a click line (mirror InterleavedTimeline.swift / encodeBody).
      blocks.push({ type: "text", text: `\n[${mmss(it.start)}] clicked "${it.label}"` });
    } else {
      blocks.push({ type: "text", text: `\n[${mmss(it.start)}–${mmss(it.end)}] "${it.text}"` });
    }
  }
  return blocks;
}

// ---------- STT (whisper-1, same request as production) ----------------------

async function transcribe(audioPath, openaiKey) {
  const bytes = readFileSync(audioPath);
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: "audio/m4a" }), basename(audioPath));
  form.append("model", "whisper-1");
  form.append("response_format", "verbose_json");
  form.append("timestamp_granularities[]", "segment");
  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${openaiKey}` },
    body: form,
  });
  if (!res.ok) throw new Error(`whisper ${res.status}: ${await res.text()}`);
  const json = await res.json();
  return {
    segments: (json.segments ?? []).map((s) => ({
      start: Number(s.start), end: Number(s.end), text: String(s.text ?? "").trim(),
    })),
    durationSeconds: Number(json.duration ?? 0),
  };
}

// ---------- chat adapters (mirror the app's OpenAI / Gemini services) --------

// Exponential backoff with jitter on a transient fault (429 / 5xx / network),
// honoring a 429's Retry-After header. This deliberately RAMPS GENTLY instead of
// the old fixed 1.5s single retry: a hard, immediate re-fire on 429 just stacks
// more requests onto an already-throttled key. Anthropic enforces an
// *acceleration limit* org-wide — a sharp usage spike from a cold/idle key reads
// as abuse and gets 429'd even well under the steady ITPM/RPM ceilings — so a
// burst eval run is exactly the shape that trips it. Backing off (and obeying
// Retry-After) lets the token bucket refill before we try again.
const RETRY_MAX_ATTEMPTS = 5; // total tries (1 initial + 4 retries) before giving up
const RETRY_BASE_MS = 1000; // first backoff ~1s, doubling: 1s, 2s, 4s, 8s (+jitter)
const RETRY_CAP_MS = 30_000; // never sleep more than 30s between tries

function backoffDelayMs(attempt, retryAfterSeconds) {
  // A server-sent Retry-After (seconds) wins — it tells us exactly when capacity
  // returns. Jitter on top avoids the pool's workers all re-firing in lockstep.
  if (Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0) {
    return Math.min(RETRY_CAP_MS, retryAfterSeconds * 1000) + Math.random() * 250;
  }
  const expo = Math.min(RETRY_CAP_MS, RETRY_BASE_MS * 2 ** (attempt - 1));
  return expo / 2 + Math.random() * (expo / 2); // full-jitter in [expo/2, expo]
}

async function fetchRetry(url, init) {
  for (let attempt = 1; ; attempt++) {
    const lastAttempt = attempt >= RETRY_MAX_ATTEMPTS;
    try {
      const res = await fetch(url, init);
      if (!lastAttempt && (res.status === 429 || res.status >= 500)) {
        const retryAfter = Number(res.headers.get("retry-after"));
        await new Promise((r) => setTimeout(r, backoffDelayMs(attempt, retryAfter)));
        continue;
      }
      // Success, a non-retryable status, or out of attempts: hand the response
      // back so the caller's existing non-2xx handling reports it.
      return res;
    } catch (e) {
      // Network-level throw (DNS, reset, "fetch failed"). Out of attempts → rethrow.
      if (lastAttempt) throw e;
      await new Promise((r) => setTimeout(r, backoffDelayMs(attempt, NaN)));
    }
  }
}

// API-key separation (rate-limit hygiene). The eval harness fans out bursts of
// requests; pointed at a PRODUCTION key that serves live users, those bursts can
// trip provider rate limits and degrade real traffic — Anthropic enforces an
// *acceleration limit* org-wide, and this is what happened 2026-06-12. So the
// harness REFUSES to use any production key: every provider requires its own
// dedicated *_API_KEY_DEV, minted in a separate, rate-capped dev project /
// workspace. There is intentionally NO fallback to the plain *_API_KEY — a
// missing dev key is a hard stop, never a silent switch to prod.
//   • anthropic → the rate cap lives on a separate Anthropic Console *workspace*
//     (org-level limits are shared, so a bare second key does NOT isolate them).
//   • openai / gemini → mint the dev key in a separate project with its own
//     limits/quota (a Google Cloud project for Gemini; an OpenAI project).
const DEV_KEY_ENV = {
  anthropic: "ANTHROPIC_API_KEY_DEV",
  openai: "OPENAI_API_KEY_DEV",
  gemini: "GEMINI_API_KEY_DEV",
};

function requireDevKey(provider) {
  const envVar = DEV_KEY_ENV[provider];
  const dev = process.env[envVar];
  if (dev) return dev;
  console.error(
    `${envVar} is required to run ${provider} models in the eval harness.\n` +
      "  This is deliberate: the harness must NOT use your production key, or its\n" +
      "  request bursts can rate-limit your live users. Mint a separate, rate-capped\n" +
      "  development key (in its own project/workspace) and export it:\n" +
      `    export ${envVar}=...\n` +
      "  (Keep production keys out of this harness entirely.)",
  );
  process.exit(1);
}

async function chatOpenAI(model, systemPrompt, blocks, key) {
  const content = blocks.map((b) =>
    b.type === "text"
      ? { type: "text", text: b.text }
      : { type: "image_url", image_url: { url: `data:${b.mime};base64,${b.base64}`, detail: "high" } }
  );
  const res = await fetchRetry("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      messages: [{ role: "system", content: systemPrompt }, { role: "user", content }],
    }),
  });
  if (!res.ok) throw new Error(`openai ${res.status}: ${await res.text()}`);
  const json = await res.json();
  const text = json?.choices?.[0]?.message?.content ?? "";
  return {
    content: text,
    inputTokens: json?.usage?.prompt_tokens ?? 0,
    outputTokens: json?.usage?.completion_tokens ?? 0,
    reportedModel: json?.model ?? model,
  };
}

async function chatGemini(model, systemPrompt, blocks, key, thinkingLevel) {
  const parts = blocks.map((b) =>
    b.type === "text"
      ? { text: b.text }
      : {
        inlineData: { mimeType: b.mime, data: b.base64 },
        mediaResolution: { level: "media_resolution_high" },
      }
  );
  const res = await fetchRetry(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
    {
      method: "POST",
      headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: systemPrompt }] },
        contents: [{ role: "user", parts }],
        generationConfig: { thinkingConfig: { thinkingLevel } },
      }),
    },
  );
  if (!res.ok) throw new Error(`gemini ${res.status}: ${await res.text()}`);
  const json = await res.json();
  const blockReason = json?.promptFeedback?.blockReason;
  if (blockReason) throw new Error(`gemini blocked: ${blockReason}`);
  const candidate = json?.candidates?.[0];
  const text = (candidate?.content?.parts ?? [])
    .filter((p) => p.thought !== true && typeof p.text === "string")
    .map((p) => p.text)
    .join("");
  if (!text) throw new Error(`gemini empty content (finishReason: ${candidate?.finishReason})`);
  const usage = json?.usageMetadata ?? {};
  return {
    content: text,
    inputTokens: usage.promptTokenCount ?? 0,
    outputTokens: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
    reportedModel: json?.modelVersion ?? model,
  };
}

// chatAnthropic — mirror of the app's AnthropicPromptGenerationService.swift
// request on the Messages API (written in Phase 0, before that adapter
// existed). Maps the neutral interleaved blocks to Anthropic
// content blocks: text → {type:"text"}, image → {type:"image", source:{base64}}.
// The system prompt rides the top-level `system` field (Anthropic's analog of
// OpenAI's system message / Gemini's systemInstruction), so `model` never
// influences the prompt — same invariant as the other two adapters.
//
// Request shape notes (verified against the Messages API, 2026-06-09):
//   - `max_tokens` is REQUIRED (unlike OpenAI/Gemini here). 8192 is ample for
//     this workload (~966 output tokens typical) and stays well under the
//     non-streaming ceiling.
//   - NO sampling params and NO `thinking` field: on Opus 4.7 `temperature`/
//     `top_p`/`top_k` and `budget_tokens` all 400, and an absent `thinking`
//     field means thinking is OFF — the cleanest minimal mirror, and the right
//     way to test whether the model obeys "Output ONLY the final result" without
//     a thinking scaffold doing the work. Sonnet 4.6 accepts the same shape.
async function chatAnthropic(model, systemPrompt, blocks, key) {
  const content = blocks.map((b) =>
    b.type === "text"
      ? { type: "text", text: b.text }
      : { type: "image", source: { type: "base64", media_type: b.mime, data: b.base64 } }
  );
  const res = await fetchRetry("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: 8192,
      system: systemPrompt,
      messages: [{ role: "user", content }],
    }),
  });
  if (!res.ok) throw new Error(`anthropic ${res.status}: ${await res.text()}`);
  const json = await res.json();
  // A safety refusal yields stop_reason "refusal" (and usually no text) — surface
  // it as a failure so the scorecard records a contract break, not empty output.
  if (json?.stop_reason === "refusal") {
    throw new Error(`anthropic refusal (stop_reason: refusal)`);
  }
  const text = (json?.content ?? [])
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => b.text)
    .join("");
  if (!text) throw new Error(`anthropic empty content (stop_reason: ${json?.stop_reason})`);
  const usage = json?.usage ?? {};
  return {
    content: text,
    inputTokens: usage.input_tokens ?? 0,
    // Anthropic bills thinking tokens inside output_tokens already; thinking is
    // off here, so output_tokens is just the visible text — mirror it directly.
    outputTokens: usage.output_tokens ?? 0,
    reportedModel: json?.model ?? model,
  };
}

// ---------- main -------------------------------------------------------------

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

// =============================================================================
// ARTIFACT MODE — typed-artifact contract scoring (refactor Phase 0)
// =============================================================================
// `--artifact` swaps the recorded-working-dir input for the labeled text-only
// fixture set (Scripts/artifact-eval/fixtures.json) and scores each model's
// raw output against the typed-artifact contract
// (docs/refactor-artifact-response-plan.md §2). Four metrics, per the plan:
//   (a) attach / no-attach accuracy — artifact attached iff the label says so
//   (b) type accuracy               — right type, among cases where the label
//                                     expects an artifact AND the model attached
//   (c) contract validity rate      — fences well-formed per the §2 parser
//                                     (chat-only with no fence material = valid)
//   (d) voice check                 — agent_prompt bodies never say "the user";
//                                     chat text addresses the user as "you"
// Fixtures carry no audio or frames, so there is no Whisper call and no image
// blocks — each case is synthesized into the same timeline TEXT shape the
// production interleaver emits (`on-screen text:` line, `clicked "X"` lines,
// [M:SS] speech segments), so the model sees familiar input structure.
//
// parseArtifactResponse below is the JS reference for the §2 parser that
// Phase 2 implements as OutputParser.swift — keep the two in sync once that
// file exists (same KEEP IN SYNC discipline as the prompt mirrors).

const ARTIFACT_TYPES = ["agent_prompt", "message", "snippet", "document", "generic"];
const ARTIFACT_OPEN_PREFIX = "<<<ZERRO_ARTIFACT";
const ARTIFACT_CLOSE = "<<<END_ZERRO_ARTIFACT>>>";
// Empty-case sentinel — emitted by generation on its own line when there was
// no request. Not a fence: it only flips requestPresent off (so the convert
// affordance is suppressed) and is stripped from chat text. KEEP IN SYNC with
// OutputParser.swift's noRequestSentinel.
const NO_REQUEST_SENTINEL = "<<<ZERRO_NO_REQUEST>>>";
const DIRECT_ADDRESS_RE = /\byou(?:r|'re|'ll|'ve|'d)?\b/i;
const THE_USER_RE = /\bthe user\b/i;

/**
 * §2 parser (fail-safe, strict + bounded recovery tier). Returns
 *   { chatText, artifact: { type, rawType, title, body } | null,
 *     valid, recovered, warnings }
 * - no fence material anywhere            → chat-only, valid
 * - exactly one well-formed block         → parsed, valid (unknown `type`
 *                                           coerces to generic with a warning)
 * - anything else — unclosed, multiple,
 *   mid-line open fence, bad attrs        → ENTIRE raw output becomes chat
 *                                           text, artifact null, valid=false
 *
 * RECOVERY TIER (§2 amendment, 2026-06-11 — Colin-approved closed list).
 * Recovery rescues a malformed fence; it can never invent an artifact: every
 * rule still requires the literal ZERRO_ARTIFACT / END_ZERRO_ARTIFACT tokens,
 * parseable type/title attrs, and the single-block discipline. Exactly three
 * rules, nothing else:
 *   R1 — open fence with wrong trailing chevron count: line starts with
 *        `<<<ZERRO_ARTIFACT` at column 0, attrs parse, ends with ≥1 `>`
 *        (e.g. `...">` or `...">>>>`)  → accepted as the open fence.
 *   R2 — open-fence body spillover: as R1, but text follows the trailing
 *        chevron run on the same line → that text becomes the first body line.
 *   R3 — close fence glued to the last body line: a line that ENDS with the
 *        exact `<<<END_ZERRO_ARTIFACT>>>` token → the text before the token
 *        is the last body line and the block closes there.
 * A parse that used any rule sets recovered=true (still valid=true) and
 * records which rule fired in warnings — the scorer reports recovery rate as
 * its own metric so a climbing rate is visible, not silent.
 * Over-long title (> 80) and trailing text after the close fence remain
 * warnings, not validity failures.
 */
const ARTIFACT_OPEN_STRICT = /^<<<ZERRO_ARTIFACT\s+type="([^"]*)"\s+title="([^"]*)"\s*>>>$/;
const ARTIFACT_OPEN_RECOVERY = /^<<<ZERRO_ARTIFACT\s+type="([^"]*)"\s+title="([^"]*)"\s*(>+)(.*)$/;

// Defense-in-depth scrubber (handoff-artifact-fence-leak). KEEP IN SYNC with
// OutputParser.swift's openFenceToken/openFenceStraggler/closeFenceToken +
// scrubFenceTokens. A response that degrades to chat-only (e.g. a truncated
// generation leaving one open fence and no close) must never show the raw wire
// delimiter; this strips it from the fallback text while keeping real spillover.
const OPEN_FENCE_TOKEN_RE = /<<<ZERRO_ARTIFACT\s+type="[^"]*"\s+title="[^"]*"\s*>+/g;
// J-05: [^>\n]* stops at the first chevron, (?:>+|$) consumes the closing
// chevron run — malformed-but-chevron'd tokens drop without eating the real
// content after `>>>`; chevron-less truncated tokens still scrub to EOL via $.
const OPEN_FENCE_STRAGGLER_RE = /<<<ZERRO_ARTIFACT[^>\n]*(?:>+|$)/g;
const CLOSE_FENCE_TOKEN_RE = /<<<END_ZERRO_ARTIFACT>*/g;
function scrubFenceTokens(text) {
  return text
    .split("\n")
    .map((line) => {
      const scrubbed = line
        .replace(OPEN_FENCE_TOKEN_RE, "")
        .replace(OPEN_FENCE_STRAGGLER_RE, "")
        .replace(CLOSE_FENCE_TOKEN_RE, "");
      if (scrubbed === line) return line; // no fence material — keep verbatim
      return scrubbed.trim() === "" ? null : scrubbed; // drop pure-fence lines
    })
    .filter((l) => l !== null)
    .join("\n");
}

function parseArtifactResponse(raw) {
  const warnings = [];
  const rawLines = raw.split(/\r?\n/);
  // Empty-case sentinel: record its presence, then strip it before
  // classification/assembly so it never leaks into chat text. Substring-based
  // (not own-line equality): an inline marker still gates and is removed; a
  // sentinel-only line vanishes, an inline one keeps its surrounding text.
  // (Mirror of OutputParser.swift.)
  const requestPresent = !rawLines.some((l) => l.includes(NO_REQUEST_SENTINEL));
  const lines = rawLines.flatMap((l) => {
    if (!l.includes(NO_REQUEST_SENTINEL)) return [l];
    const stripped = l.split(NO_REQUEST_SENTINEL).join("");
    return stripped.trim() === "" ? [] : [stripped];
  });
  const opens = [];
  const closes = []; // { index, strict, prefix }
  let midline = false;
  lines.forEach((line, i) => {
    if (line.startsWith(ARTIFACT_OPEN_PREFIX)) opens.push(i);
    else if (line.includes(ARTIFACT_OPEN_PREFIX)) midline = true;
    const trimmed = line.trimEnd();
    if (trimmed === ARTIFACT_CLOSE && line.startsWith(ARTIFACT_CLOSE)) {
      closes.push({ index: i, strict: true, prefix: "" });
    } else if (trimmed.endsWith(ARTIFACT_CLOSE)) {
      // R3 — close token at end of line, content (or indent) before it.
      closes.push({ index: i, strict: false, prefix: trimmed.slice(0, -ARTIFACT_CLOSE.length) });
    } else if (line.includes("<<<END_ZERRO_ARTIFACT")) {
      midline = true; // close token NOT at end of line (or wrong chevrons) — unrecoverable
    }
  });
  const asChatOnly = (valid) => ({ chatText: scrubFenceTokens(lines.join("\n")).trim(), artifact: null, valid, recovered: false, warnings, requestPresent });
  if (opens.length === 0 && closes.length === 0 && !midline) return asChatOnly(true);
  if (midline) {
    warnings.push("fence delimiter not alone at line start");
    return asChatOnly(false);
  }
  if (opens.length !== 1 || closes.length !== 1) {
    warnings.push(`expected exactly one artifact block: ${opens.length} open / ${closes.length} close fences`);
    return asChatOnly(false);
  }
  const [o] = opens;
  const close = closes[0];
  const c = close.index;
  if (c <= o) {
    warnings.push("close fence does not follow the open fence");
    return asChatOnly(false);
  }
  const openLine = lines[o].trimEnd();
  let m = openLine.match(ARTIFACT_OPEN_STRICT);
  let openStrict = true;
  let spill = "";
  if (!m) {
    const r = openLine.match(ARTIFACT_OPEN_RECOVERY);
    if (!r) {
      warnings.push(`unparseable open fence: ${lines[o].trim().slice(0, 120)}`);
      return asChatOnly(false);
    }
    openStrict = false;
    m = r;
    spill = r[4].trim();
    warnings.push(spill
      ? `recovered (R2): open fence with body spillover ("${r[3]}" + text)`
      : `recovered (R1): open fence ended "${r[3]}" instead of ">>>"`);
  }
  if (!close.strict) warnings.push("recovered (R3): close fence at end of last body line");
  const recovered = !openStrict || !close.strict;
  const rawType = m[1];
  const title = m[2];
  let type = rawType;
  if (!ARTIFACT_TYPES.includes(type)) {
    warnings.push(`unknown type "${rawType}" coerced to generic`);
    type = "generic";
  }
  if (title.length > 80) warnings.push(`title is ${title.length} chars (contract caps at 80)`);
  const chatText = lines.slice(0, o).join("\n").trim();
  const bodyLines = lines.slice(o + 1, c);
  if (close.prefix.trim()) bodyLines.push(close.prefix);
  if (spill) bodyLines.unshift(spill);
  const body = bodyLines.join("\n").trim();
  const trailing = lines.slice(c + 1).join("\n").trim();
  if (!chatText) warnings.push("no chat text before the artifact block");
  if (!body) warnings.push("empty artifact body");
  if (trailing) warnings.push("text after the close fence (contract: chat first, artifact last)");
  return { chatText, artifact: { type, rawType, title, body }, valid: true, recovered, warnings, requestPresent };
}

/** Synthesize a fixture into the production timeline text shape (no images). */
function fixtureBlocks(c) {
  const blocks = [];
  if (c.ocr_summary) blocks.push({ type: "text", text: `\n[${mmss(0)}] on-screen text: ${c.ocr_summary}` });
  const sentences = c.transcript.split(/(?<=[.!?…])\s+/).map((s) => s.trim()).filter(Boolean);
  const clicks = [...(c.clicks ?? [])];
  // Distribute clicks roughly evenly between speech segments, like a real
  // recording where the user clicks while narrating; leftovers go at the end.
  const every = clicks.length ? Math.max(1, Math.floor(sentences.length / (clicks.length + 1))) : 0;
  let t = 1;
  let clickIdx = 0;
  sentences.forEach((s, i) => {
    const end = t + Math.max(2, Math.min(8, Math.round(s.length / 12)));
    blocks.push({ type: "text", text: `\n[${mmss(t)}–${mmss(end)}] "${s}"` });
    t = end + 1;
    if (clickIdx < clicks.length && every && (i + 1) % every === 0) {
      blocks.push({ type: "text", text: `\n[${mmss(t)}] clicked "${clicks[clickIdx++]}"` });
      t += 1;
    }
  });
  while (clickIdx < clicks.length) {
    blocks.push({ type: "text", text: `\n[${mmss(t)}] clicked "${clicks[clickIdx++]}"` });
    t += 1;
  }
  return blocks;
}

/** Score one parsed response against its fixture label. */
function scoreArtifactCase(c, parsed) {
  const got = parsed.artifact;
  const attachOk = (got !== null) === c.expected.has_artifact;
  // Type accuracy compares the RAW emitted type (a hallucinated type string
  // that coerces to generic is still a type miss, even against expected generic).
  const typeOk = c.expected.has_artifact && got ? got.rawType === c.expected.type : null;
  const chatVoiceOk = parsed.chatText ? DIRECT_ADDRESS_RE.test(parsed.chatText) : null;
  const agentVoiceOk = got && got.type === "agent_prompt" ? !THE_USER_RE.test(got.body) : null;
  return {
    attachOk, typeOk, valid: parsed.valid, recovered: parsed.recovered, chatVoiceOk, agentVoiceOk,
    gotType: got?.rawType ?? null, gotTitle: got?.title ?? null,
  };
}

/** Aggregate one model's per-case records into the four plan metrics. */
function artifactMetrics(records) {
  const ok = records.filter((r) => !r.error);
  const pct = (n, d) => (d === 0 ? "n/a" : `${((100 * n) / d).toFixed(0)}% (${n}/${d})`);
  const typed = ok.filter((r) => r.typeOk !== null);
  const chatVoiced = ok.filter((r) => r.chatVoiceOk !== null);
  const agentVoiced = ok.filter((r) => r.agentVoiceOk !== null);
  const violations = agentVoiced.filter((r) => r.agentVoiceOk === false).length;
  // Recovery rate — recovered parses / artifact-bearing responses. Recovered
  // counts as valid, but the rate gets its own row: a climbing rate under
  // future prompt edits is degradation that validity alone would hide.
  const withArtifact = ok.filter((r) => r.gotType !== null);
  const recoveredCount = ok.filter((r) => r.recovered).length;
  return {
    errors: records.length - ok.length,
    attachLabel: pct(ok.filter((r) => r.attachOk).length, ok.length),
    typeLabel: pct(typed.filter((r) => r.typeOk).length, typed.length),
    validLabel: pct(ok.filter((r) => r.valid).length, ok.length),
    recoveryLabel: withArtifact.length === 0
      ? "n/a"
      : `${recoveredCount}/${withArtifact.length} artifacts (${((100 * recoveredCount) / withArtifact.length).toFixed(1)}%)`,
    chatVoiceLabel: pct(chatVoiced.filter((r) => r.chatVoiceOk).length, chatVoiced.length),
    agentVoiceLabel: `${violations} violation${violations === 1 ? "" : "s"} / ${agentVoiced.length} agent_prompt`,
    totalIn: ok.reduce((a, r) => a + r.inputTokens, 0),
    totalOut: ok.reduce((a, r) => a + r.outputTokens, 0),
    meanLatency: ok.length ? ok.reduce((a, r) => a + r.seconds, 0) / ok.length : 0,
  };
}

/** Small concurrency pool — keeps a 40-case run from being fully serial. */
async function mapPool(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i], i);
      }
    }),
  );
  return out;
}

function buildArtifactScorecard(perModel, { stamp, fixturesPath, promptLabel, fixtures }) {
  const out = [];
  const specs = perModel.map((p) => p.spec);
  const metrics = perModel.map((p) => artifactMetrics(p.records));
  out.push(
    `# Artifact-contract scorecard`, ``,
    `- fixtures: \`${fixturesPath}\` (${fixtures.length} cases)`,
    `- system prompt: ${promptLabel}`,
    `- generated: ${stamp}`, ``,
    `Metrics (plan Phase 0): **attach** = artifact attached iff the label says so · ` +
    `**type** = right type among cases where the label expects an artifact AND the model attached · ` +
    `**validity** = §2 fences well-formed (clean chat-only counts as valid) · ` +
    `**voice** = chat text addresses "you"; agent_prompt bodies never say "the user".`, ``,
    `## Metrics`, ``,
    `| metric | ${specs.join(" | ")} |`,
    `|---|${specs.map(() => "---").join("|")}|`,
  );
  const row = (label, f) => out.push(`| ${label} | ${metrics.map(f).join(" | ")} |`);
  row("attach / no-attach accuracy", (m) => m.attachLabel);
  row("type accuracy", (m) => m.typeLabel);
  row("contract validity", (m) => m.validLabel);
  row("recovery rate (tier, counts valid)", (m) => m.recoveryLabel);
  row("chat voice (direct address)", (m) => m.chatVoiceLabel);
  row('agent_prompt voice ("the user")', (m) => m.agentVoiceLabel);
  row("API errors", (m) => String(m.errors));
  row("mean latency", (m) => `${m.meanLatency.toFixed(1)}s`);
  out.push(`| est chat cost | ${perModel.map((p, i) => {
    const c = chatCostUsd(p.spec, metrics[i].totalIn, metrics[i].totalOut);
    return c === null ? "unpriced" : `$${c.toFixed(4)}`;
  }).join(" | ")} |`, ``);

  out.push(
    `## Per-case results`, ``,
    `Cell: ✓/✗ on attach+type, then the type the model emitted (\`!\` = malformed contract, \`~R\` = recovery tier, ERR = API error).`, ``,
    `| case | expected | ${specs.join(" | ")} |`,
    `|---|---|${specs.map(() => "---").join("|")}|`,
  );
  for (const c of fixtures) {
    const cells = perModel.map(({ records }) => {
      const r = records.find((x) => x.id === c.id);
      if (!r) return "—";
      if (r.error) return "ERR";
      const pass = r.attachOk && r.typeOk !== false;
      return `${pass ? "✓" : "✗"} ${r.gotType ?? "chat-only"}${r.valid ? "" : " !"}${r.recovered ? " ~R" : ""}`;
    });
    out.push(`| ${c.id} | ${c.expected.has_artifact ? c.expected.type : "chat-only"} | ${cells.join(" | ")} |`);
  }
  out.push(``);

  // Recovery-tier visibility: every recovered parse, with the rule that fired.
  for (const { spec, records } of perModel) {
    const rec = records.filter((r) => !r.error && r.recovered);
    if (!rec.length) continue;
    out.push(`## Recovered (tier) — ${spec}`, ``);
    for (const r of rec) {
      const rules = (r.warnings ?? []).filter((w) => w.startsWith("recovered")).join("; ");
      out.push(`- ${r.id} → ${r.gotType} — ${rules}`);
    }
    out.push(``);
  }

  for (const { spec, records } of perModel) {
    const bad = records.filter(
      (r) => r.error || !r.attachOk || r.typeOk === false || !r.valid || r.agentVoiceOk === false,
    );
    if (!bad.length) continue;
    out.push(`## Failures — ${spec}`, ``);
    for (const r of bad) {
      const why = r.error
        ? `API error: ${r.error}`
        : [
            !r.valid && "malformed contract",
            !r.attachOk && "attach mismatch",
            r.typeOk === false && `type mismatch (got ${r.gotType ?? "chat-only"})`,
            r.agentVoiceOk === false && '"the user" in agent_prompt body',
          ].filter(Boolean).join("; ");
      out.push(`### ${r.id} — ${why}`, ``);
      if (r.warnings?.length) out.push(`warnings: ${r.warnings.join(" · ")}`, ``);
      if (!r.error) {
        out.push("```", r.raw.slice(0, 800) + (r.raw.length > 800 ? "\n… (truncated)" : ""), "```", ``);
      }
    }
  }
  return out.join("\n");
}

async function runArtifactEval() {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const fixturesPath = arg("fixtures", join(scriptDir, "artifact-eval", "fixtures.json"));
  const models = arg("models", "gemini:gemini-3.5-flash,openai:gpt-4o").split(",").map((s) => s.trim());
  const thinkingLevel = arg("thinking", "low");
  const outDir = arg("out", "eval-results/artifact");
  // Per-model request concurrency. Default 2 keeps the ramp gentle so a cold key
  // doesn't trip Anthropic's acceleration limit; raise it with --concurrency for
  // high-limit models/workspaces, or drop to 1 for the most rate-limited ones.
  const concurrency = Math.max(1, Number(arg("concurrency", "2")) || 2);
  // --system-prompt: a .txt path is read raw; a .md path yields its FIRST
  // fenced code block (so the in-repo prompt mirror artifact-eval/prompt-v2.md
  // can carry a provenance header without it riding into the prompt).
  const promptFile = arg("system-prompt", null);
  const loadPromptFile = (p) => {
    const text = readFileSync(p, "utf8");
    if (!p.endsWith(".md")) return text;
    const m = text.match(/(?:^|\n)```\n([\s\S]*?)\n```(?:\n|$)/);
    if (!m) { console.error(`--system-prompt: no fenced block found in ${p}`); process.exit(1); }
    return m[1];
  };
  const systemPrompt = promptFile ? loadPromptFile(promptFile) : composedSystemPrompt();
  const promptLabel = promptFile
    ? `\`${promptFile}\``
    : `locked v2 mirror (${relative(process.cwd(), PROMPT_MIRROR_PATH)})`;

  // No Whisper in this mode — each key is required only for its own provider.
  const need = (p) => models.some((m) => m.startsWith(`${p}:`));
  // Each provider uses its dedicated DEV key only (hard stop if unset) — never a
  // production key. No Whisper in artifact mode, so a key is needed only when its
  // own provider appears in the model list.
  const openaiKey = need("openai") ? requireDevKey("openai") : undefined;
  const geminiKey = need("gemini") ? requireDevKey("gemini") : undefined;
  const anthropicKey = need("anthropic") ? requireDevKey("anthropic") : undefined;

  let fixtures = JSON.parse(readFileSync(fixturesPath, "utf8"));
  const problems = [];
  const seen = new Set();
  for (const c of fixtures) {
    const id = c.id ?? "(missing id)";
    if (!c.id) problems.push("case missing id");
    else if (seen.has(c.id)) problems.push(`duplicate id ${c.id}`);
    else seen.add(c.id);
    if (typeof c.transcript !== "string" || !c.transcript) problems.push(`${id}: transcript must be a non-empty string`);
    if (typeof c.ocr_summary !== "string") problems.push(`${id}: ocr_summary must be a string`);
    if (!Array.isArray(c.clicks)) problems.push(`${id}: clicks must be an array`);
    if (!c.expected || typeof c.expected.has_artifact !== "boolean") problems.push(`${id}: expected.has_artifact must be a boolean`);
    else if (c.expected.has_artifact && !ARTIFACT_TYPES.includes(c.expected.type)) problems.push(`${id}: expected.type "${c.expected.type}" is not a valid artifact type`);
    else if (!c.expected.has_artifact && c.expected.type !== null) problems.push(`${id}: expected.type must be null when has_artifact is false`);
  }
  if (problems.length) {
    console.error(`fixtures invalid (${fixturesPath}):\n  ${problems.join("\n  ")}`);
    process.exit(1);
  }
  const dist = {};
  for (const c of fixtures) {
    const k = c.expected.has_artifact ? c.expected.type : "chat-only";
    dist[k] = (dist[k] ?? 0) + 1;
  }
  console.error(`fixtures: ${fixtures.length} cases — ${Object.entries(dist).map(([k, v]) => `${k}:${v}`).join(", ")}`);

  const only = arg("only", null);
  if (only) {
    const want = new Set(only.split(",").map((s) => s.trim()));
    fixtures = fixtures.filter((c) => want.has(c.id));
    console.error(`--only: running ${fixtures.length} of ${seen.size} cases`);
    if (!fixtures.length) { console.error("no fixture ids matched --only"); process.exit(1); }
  }

  mkdirSync(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const perModel = [];

  for (const spec of models) {
    const [provider, ...rest] = spec.split(":");
    const model = rest.join(":");
    console.error(`\n=== ${spec} (artifact mode, ${fixtures.length} cases${provider === "gemini" ? `, thinking=${thinkingLevel}` : ""}) ===`);
    const records = await mapPool(fixtures, concurrency, async (c) => {
      const blocks = fixtureBlocks(c);
      const t0 = Date.now();
      try {
        const r = provider === "gemini"
          ? await chatGemini(model, systemPrompt, blocks, geminiKey, thinkingLevel)
          : provider === "anthropic"
          ? await chatAnthropic(model, systemPrompt, blocks, anthropicKey)
          : await chatOpenAI(model, systemPrompt, blocks, openaiKey);
        const seconds = (Date.now() - t0) / 1000;
        const parsed = parseArtifactResponse(r.content);
        const s = scoreArtifactCase(c, parsed);
        const mark = s.attachOk && s.typeOk !== false && s.valid ? "ok  " : "MISS";
        console.error(`  ${mark} ${c.id} — expected ${c.expected.has_artifact ? c.expected.type : "chat-only"}, got ${s.gotType ?? "chat-only"}${parsed.valid ? "" : " [INVALID]"}${parsed.recovered ? " [RECOVERED]" : ""} (${seconds.toFixed(1)}s)`);
        return {
          id: c.id, expected: c.expected, ...s,
          warnings: parsed.warnings, chatText: parsed.chatText,
          body: parsed.artifact?.body ?? null, raw: r.content,
          seconds, inputTokens: r.inputTokens, outputTokens: r.outputTokens,
        };
      } catch (e) {
        console.error(`  ERR  ${c.id} — ${e.message ?? e}`);
        return { id: c.id, expected: c.expected, error: String(e.message ?? e) };
      }
    });
    const slug = spec.replace(/[:.]/g, "_");
    writeFileSync(join(outDir, `${stamp}_artifact_${slug}.json`), JSON.stringify({ spec, promptLabel, records }, null, 2));
    perModel.push({ spec, records });
  }

  const scorecardPath = join(outDir, "ARTIFACT-SCORECARD.md");
  writeFileSync(scorecardPath, buildArtifactScorecard(perModel, { stamp, fixturesPath, promptLabel, fixtures }));
  console.error(`\nscorecard → ${scorecardPath}`);

  console.error("\n=== artifact summary ===");
  console.table(perModel.map(({ spec, records }) => {
    const m = artifactMetrics(records);
    return { model: spec, attach: m.attachLabel, type: m.typeLabel, validity: m.validLabel, errors: m.errors };
  }));
}

// --parser-tests [file] — run the §2 parser edge-case suite (no API calls).
// The suite (artifact-eval/parser-tests.json) is the contract's executable
// spec: strict cases + the recovery-tier cases (including the real model
// outputs that motivated the tier). Phase 2's OutputParserTests.swift must
// port/pass this same list. Exits non-zero on any failure.
function runParserTests() {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const i = process.argv.indexOf("--parser-tests");
  const next = process.argv[i + 1];
  const testsPath = next && !next.startsWith("--") ? next : join(scriptDir, "artifact-eval", "parser-tests.json");
  const tests = JSON.parse(readFileSync(testsPath, "utf8"));
  let failures = 0;
  for (const t of tests) {
    const got = parseArtifactResponse(t.input);
    const problems = [];
    const e = t.expect;
    if (e.valid !== undefined && got.valid !== e.valid) problems.push(`valid: ${got.valid} ≠ ${e.valid}`);
    if (e.recovered !== undefined && got.recovered !== e.recovered) problems.push(`recovered: ${got.recovered} ≠ ${e.recovered}`);
    if (e.hasArtifact !== undefined && (got.artifact !== null) !== e.hasArtifact) problems.push(`hasArtifact: ${got.artifact !== null} ≠ ${e.hasArtifact}`);
    if (e.requestPresent !== undefined && got.requestPresent !== e.requestPresent) problems.push(`requestPresent: ${got.requestPresent} ≠ ${e.requestPresent}`);
    if (e.type !== undefined && got.artifact?.type !== e.type) problems.push(`type: ${got.artifact?.type} ≠ ${e.type}`);
    if (e.rawType !== undefined && got.artifact?.rawType !== e.rawType) problems.push(`rawType: ${got.artifact?.rawType} ≠ ${e.rawType}`);
    if (e.title !== undefined && got.artifact?.title !== e.title) problems.push(`title: ${JSON.stringify(got.artifact?.title)} ≠ ${JSON.stringify(e.title)}`);
    if (e.bodyStartsWith !== undefined && !(got.artifact?.body ?? "").startsWith(e.bodyStartsWith)) problems.push(`body does not start with ${JSON.stringify(e.bodyStartsWith)}`);
    if (e.bodyEndsWith !== undefined && !(got.artifact?.body ?? "").endsWith(e.bodyEndsWith)) problems.push(`body does not end with ${JSON.stringify(e.bodyEndsWith)}`);
    if (e.bodyContains !== undefined && !(got.artifact?.body ?? "").includes(e.bodyContains)) problems.push(`body does not contain ${JSON.stringify(e.bodyContains)}`);
    if (e.chatTextContains !== undefined && !got.chatText.includes(e.chatTextContains)) problems.push(`chatText does not contain ${JSON.stringify(e.chatTextContains)}`);
    if (e.chatTextNotContains !== undefined && got.chatText.includes(e.chatTextNotContains)) problems.push(`chatText must not contain ${JSON.stringify(e.chatTextNotContains)}`);
    if (e.warningsContain !== undefined && !got.warnings.some((w) => w.includes(e.warningsContain))) problems.push(`no warning containing ${JSON.stringify(e.warningsContain)}`);
    if (problems.length) {
      failures++;
      console.error(`FAIL [${t.tier}] ${t.name}\n  ${problems.join("\n  ")}`);
    } else {
      console.error(`pass [${t.tier}] ${t.name}`);
    }
  }
  console.error(`\n${tests.length - failures}/${tests.length} parser tests passed`);
  process.exit(failures ? 1 : 0);
}

if (process.argv.includes("--parser-tests")) {
  runParserTests();
}

if (process.argv.includes("--artifact")) {
  await runArtifactEval();
  process.exit(0);
}

// ---------- recording mode (the original harness) ----------------------------

const workingDir = process.argv[2];
if (!workingDir || workingDir.startsWith("--")) {
  console.error("usage: node Scripts/eval-models.mjs <workingDir> --models provider:model,... [--thinking low|high] [--out dir]");
  process.exit(1);
}

// Typed-artifact refactor: there is one unified prompt — `mode` is gone. The
// label survives only in output filenames/scorecards as "v2" for continuity
// with pre-refactor result directories.
const mode = "v2";
const models = arg("models", "gemini:gemini-3.5-flash,openai:gpt-4o").split(",").map((s) => s.trim());
const thinkingLevel = arg("thinking", "low");
const outDir = arg("out", "eval-results");

// Each provider uses its dedicated DEV key only — requireDevKey() hard-stops if
// it's unset, so a production key can never be used by the harness. OpenAI is
// ALWAYS required here (Whisper STT), independent of the chat model picked.
const openaiKey = requireDevKey("openai");
const geminiKey = models.some((m) => m.startsWith("gemini:")) ? requireDevKey("gemini") : undefined;
const anthropicKey = models.some((m) => m.startsWith("anthropic:")) ? requireDevKey("anthropic") : undefined;

const manifest = JSON.parse(readFileSync(join(workingDir, "manifest.json"), "utf8"));
const frames = manifest.frames.map((f) => ({
  timestampSeconds: f.timestampSeconds,
  filename: f.filename, // kept for the scorecard's inline frame references
  base64: readFileSync(join(workingDir, f.filename)).toString("base64"),
  ocrText: f.ocrText, // Phase 3: redacted on-device-OCR text from the manifest
}));
console.error(`recording: ${manifest.durationSeconds.toFixed(1)}s, ${frames.length} frames`);

// Optional per-recording ground-truth note. Lives beside the working dir's
// manifest as meta.json: { scenario, groundTruth, expectation }. Surfaced at
// the top of the scorecard so hallucination / accuracy scoring has a reference.
const recordingName = basename(workingDir.replace(/\/+$/, "")) || "recording";
let meta = null;
const metaPath = join(workingDir, "meta.json");
if (existsSync(metaPath)) {
  try {
    meta = JSON.parse(readFileSync(metaPath, "utf8"));
    console.error(`meta.json: scenario="${meta.scenario ?? "—"}"`);
  } catch (e) {
    console.error(`meta.json present but unreadable: ${e.message ?? e}`);
  }
}

// Transcribe once, cache beside the recording.
// Phase 6 mirror: when the manifest says the audio carried no detectable speech
// (hasSpeech === false), skip Whisper entirely — exactly as the app does — and
// run on an empty transcript (timeline = frames + OCR +
// clicks only). Additive: a manifest without the key (older extraction) defaults
// to transcribing, the safe direction.
const hasSpeech = manifest.hasSpeech !== false;
const cachePath = join(workingDir, "transcript.eval.json");
let transcript;
if (!hasSpeech) {
  transcript = { segments: [], durationSeconds: 0 };
  console.error("transcript: skipped — manifest hasSpeech=false (Phase 6 gate)");
} else if (existsSync(cachePath)) {
  transcript = JSON.parse(readFileSync(cachePath, "utf8"));
  console.error(`transcript: cached (${transcript.segments.length} segments)`);
} else {
  console.error("transcribing with whisper-1…");
  transcript = await transcribe(join(workingDir, manifest.audioFilename), openaiKey);
  writeFileSync(cachePath, JSON.stringify(transcript, null, 2));
  console.error(`transcript: ${transcript.segments.length} segments, ${transcript.durationSeconds.toFixed(1)}s measured`);
}

const systemPrompt = composedSystemPrompt();
// Phase 4: clicks (if any) from the manifest, mirrored into the timeline.
const clicks = manifest.clicks ?? [];
const blocks = buildTimeline(frames, transcript.segments, clicks);
const whisperCost = (transcript.durationSeconds / 60) * WHISPER_PER_MINUTE;

mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
const summary = [];
const results = []; // full per-model records for the combined scorecard

for (const spec of models) {
  const [provider, ...rest] = spec.split(":");
  const model = rest.join(":");
  console.error(`\n=== ${spec} (mode=${mode}${provider === "gemini" ? `, thinking=${thinkingLevel}` : ""}) ===`);
  const t0 = Date.now();
  try {
    const r = provider === "gemini"
      ? await chatGemini(model, systemPrompt, blocks, geminiKey, thinkingLevel)
      : provider === "anthropic"
      ? await chatAnthropic(model, systemPrompt, blocks, anthropicKey)
      : await chatOpenAI(model, systemPrompt, blocks, openaiKey);
    const seconds = (Date.now() - t0) / 1000;
    const chatCost = chatCostUsd(spec, r.inputTokens, r.outputTokens);
    const total = chatCost === null ? null : chatCost + whisperCost;
    const slug = spec.replace(/[:.]/g, "_");
    const outPath = join(outDir, `${stamp}_${mode}_${slug}.md`);
    const costLabel = total === null ? "unpriced" : `$${total.toFixed(4)}`;
    writeFileSync(outPath, [
      `# ${spec}`,
      ``,
      `- recording: ${recordingName}`,
      `- frames: ${frames.length}`,
      `- mode: ${mode}${provider === "gemini" ? `  |  thinking: ${thinkingLevel}` : ""}`,
      `- reported model: ${r.reportedModel}`,
      `- latency: ${seconds.toFixed(1)}s`,
      `- input tokens: ${r.inputTokens}`,
      `- output tokens: ${r.outputTokens}`,
      `- est cost: ${costLabel} (incl. whisper $${whisperCost.toFixed(4)})`,
      ``,
      `---`,
      ``,
      r.content,
      ``,
    ].join("\n"));
    summary.push({ model: spec, latency: `${seconds.toFixed(1)}s`, in: r.inputTokens, out: r.outputTokens, cost: costLabel, file: outPath });
    results.push({
      spec, provider, content: r.content, reportedModel: r.reportedModel,
      seconds, inputTokens: r.inputTokens, outputTokens: r.outputTokens, costLabel,
    });
    console.error(`ok — ${seconds.toFixed(1)}s, ${r.inputTokens} in / ${r.outputTokens} out → ${outPath}`);
  } catch (e) {
    summary.push({ model: spec, error: String(e.message ?? e) });
    results.push({ spec, provider, error: String(e.message ?? e) });
    console.error(`FAILED: ${e.message ?? e}`);
  }
}

// ---------- combined scorecard (all models side by side, per run-batch) ------
writeFileSync(join(outDir, "SCORECARD.md"), buildScorecard());
console.error(`\nscorecard → ${join(outDir, "SCORECARD.md")}`);

console.error("\n=== summary ===");
console.table(summary);

/**
 * One human-judgeable markdown doc per run-batch: ground-truth note (if any),
 * recording stats, an inline visual index of the frames, every model's output
 * side by side, and a 1–5 rubric grid (cost + latency pre-filled, judgement
 * fields blank). Frames are linked by path RELATIVE to the scorecard so the
 * images render in-place with no copying and no npm dependency.
 */
function buildScorecard() {
  const out = [];
  out.push(`# Scorecard — ${recordingName}`, ``);

  if (meta) {
    out.push(`## Ground truth`, ``);
    if (meta.scenario) out.push(`**Scenario:** ${meta.scenario}`, ``);
    if (meta.groundTruth) out.push(`**Key on-screen facts:** ${meta.groundTruth}`, ``);
    if (meta.expectation) out.push(`**A good output:** ${meta.expectation}`, ``);
  }

  out.push(
    `## Recording`, ``,
    `- frames: **${frames.length}**`,
    `- duration: ${manifest.durationSeconds.toFixed(1)}s`,
    `- mode: ${mode}`,
    `- transcript: ${transcript.segments.length} segments`,
    `- generated: ${stamp}`,
    ``,
  );

  // Inline visual index — sample evenly so a dense recording stays scannable.
  // Paths are relative to outDir (where this file lives) so images render
  // wherever the scorecard is opened (VS Code, GitHub if committed, etc.).
  const MAX_THUMBS = 16;
  const step = Math.max(1, Math.ceil(frames.length / MAX_THUMBS));
  const sampled = frames.filter((_, i) => i % step === 0);
  out.push(
    `## Frames (${sampled.length} of ${frames.length} shown — full set in \`${relative(outDir, workingDir) || "."}\`)`,
    ``,
  );
  for (const f of sampled) {
    const rel = relative(outDir, join(workingDir, f.filename));
    out.push(`\`[${mmss(f.timestampSeconds)}]\` ![${f.filename}](${rel})`);
  }
  out.push(``);

  // Every model's output, side by side (stacked for full-width reading).
  out.push(`## Outputs`, ``);
  for (const r of results) {
    out.push(`### ${r.spec}`, ``);
    if (r.error) {
      // Collapse to a single line so a multi-line provider error body doesn't
      // spill raw JSON past the blockquote and break the doc's flow.
      const oneLine = String(r.error).replace(/\s+/g, " ").slice(0, 300);
      out.push(`> **FAILED:** ${oneLine}`, ``);
      continue;
    }
    out.push(
      `_${r.seconds.toFixed(1)}s · ${r.inputTokens} in / ${r.outputTokens} out · ${r.costLabel} (incl. whisper $${whisperCost.toFixed(4)})_`,
      ``,
      "```",
      r.content,
      "```",
      ``,
    );
  }

  // Rubric grid: judgement rows blank, cost/latency auto-filled.
  const ok = results.filter((r) => !r.error);
  const header = `| Criterion | ${ok.map((r) => r.spec).join(" | ")} |`;
  const divider = `|---|${ok.map(() => "---").join("|")}|`;
  const blankRow = (label) => `| ${label} | ${ok.map(() => " ").join(" | ")} |`;
  out.push(
    `## Rubric (score 1–5)`, ``,
    `Small-text fidelity = read on-screen code/UI text correctly · Deixis = resolved "this/that/here" to the right frame · Hallucination = invented nothing not shown/said (5 = none) · Faithfulness = chat text + artifact capture what was actually asked (attach iff a deliverable was named).`,
    ``,
    header,
    divider,
    blankRow("Small-text fidelity"),
    blankRow("Deixis"),
    blankRow("Hallucination (5=none)"),
    blankRow("Faithfulness / accuracy"),
    `| Cost (USD) | ${ok.map((r) => r.costLabel).join(" | ")} |`,
    `| Latency (s) | ${ok.map((r) => `${r.seconds.toFixed(1)}s`).join(" | ")} |`,
    ``,
  );

  return out.join("\n");
}
