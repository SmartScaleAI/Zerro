#!/usr/bin/env node
// =============================================================================
// eval-models.mjs — standalone model A/B harness for Zerro recordings.
// =============================================================================
// Compares chat/vision models on a REAL recording without the app, Supabase,
// JWTs, or credits. It replicates the production pipeline faithfully:
//   1. Transcribes the recording's audio with whisper-1 (verbose_json,
//      segment granularity) — same request as the BYOK/Managed paths.
//   2. Composes the EXACT server-owned system prompt (base + mode layer).
//   3. Interleaves frames + transcript chronologically with the
//      frame-before-speech tiebreak and [M:SS] tags — same algorithm as
//      interleave.ts / InterleavedTimeline.swift.
//   4. Sends the identical payload to each requested model (OpenAI or
//      Gemini wire format, matching providers/openai.ts / gemini.ts).
//   5. Writes side-by-side outputs + token/cost/latency to an output dir.
//
// KEEP IN SYNC (read-only mirrors — if these change upstream, update here):
//   - supabase/functions/generate/prompt.ts        (BASE / INSTRUCT / EXPLAIN)
//   - supabase/functions/generate/interleave.ts    (mmss, tiebreak, tags)
//   - supabase/functions/generate/providers/openai.ts, gemini.ts (wire shapes)
//   - supabase/functions/generate/cost.ts          (pricing table)
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
//   export OPENAI_API_KEY=sk-...          # always required (whisper STT)
//   export GEMINI_API_KEY=...             # required for gemini:* models
//   node Scripts/eval-models.mjs <workingDir> \
//     --mode instruct \
//     --models gemini:gemini-3.5-flash,gemini:gemini-3.1-pro-preview,openai:gpt-4o \
//     [--thinking low|high]               # gemini only, default low
//     [--out eval-results]                # output dir, default ./eval-results
//
// The transcript is cached per working dir (transcript.eval.json) so repeated
// runs against different models don't re-pay Whisper.
// =============================================================================

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, basename, relative } from "node:path";

// ---------- system prompt (verbatim mirror of generate/prompt.ts) -----------

const BASE = `You convert a screen recording into clean text output. Your input is:
- A sequence of JPEG frames sampled from the recording, interleaved in time order with the narration. Each frame is marked with its timestamp [M:SS] and immediately precedes the speech spoken just after it.
- A timestamped transcript of the user speaking while recording.
- Some frames are followed by an \`on-screen text:\` line — text extracted from that frame by on-device OCR. Prefer it for exact strings (names, filenames, values, code, URLs); it may be partial or imperfect, and any secrets are shown as [REDACTED]. The frames remain the source of truth for layout and anything OCR didn't capture.
- Lines like \`clicked "X"\` mark where the user clicked during the recording (the label is the on-screen element under the cursor, from OCR). Use them to resolve deictic references and to understand the sequence of actions the user took.

The transcript is raw speech: it contains filler words, false starts, self-corrections, and informal phrasing. Treat it as intent, not literal text. When the user corrects themselves, follow the corrected version and ignore the abandoned one.

The frames show what the user was looking at or pointing to. Use them to ground vague spoken references ("this button", "that error", "here") in concrete on-screen detail. When speech and frames conflict, the frames are the source of truth for what exists; the speech is the source of truth for what the user wants.

Resolving a vague reference to what the frames clearly show is correct and expected. Inventing specifics that are neither shown nor stated is not. When the user gestures at something without naming the exact mechanism, stay at the level of detail the frames and speech support — do not fabricate precise values, names, or settings the user never provided. If a reference is genuinely ambiguous and the frames cannot resolve it, note the ambiguity briefly rather than guessing.

Never invent a request, task, or goal the user did not actually express. A request to review, assess, explain, summarize, analyze, or ask about what is shown is itself an actionable request — handle it normally. Only when the narration contains no request of any kind — a bare sign-off (e.g. "thanks for watching", "like and subscribe"), filler or boilerplate (including transcription artifacts on near-silent audio), or talk unrelated to the screen — do not manufacture a request from what happens to be on screen; how to handle that empty case is defined by the selected output mode below.

The user may speak mostly about what they want changed or done, rather than describing what is on screen. Capture their actual intent regardless of how it is phrased; do not let the form of their speech distort the output format. A single recording may contain more than one request, or a sequence of related changes — capture every distinct one; do not merge them into a single vague ask or drop the later ones.

Output ONLY the final result. No preamble, no "Here is...", no closing remarks, and never wrap the whole output in a code fence. Markdown structure within the output — short headings, lists, inline code — is welcome where it makes the result clearer. The output goes straight to the clipboard.

OUTPUT MODE: The user has selected an output mode (provided below). Treat it as the default. Only override it if the user's speech contains a direct, explicit request for a different output format (e.g. "actually, just explain this" or "write this as instructions instead"). Do NOT switch modes because format-related words happen to appear while the user is describing their screen or content. When in doubt, follow the selected mode.`;

const INSTRUCT = `TASK: Rewrite the user's spoken request as a clear, structured instruction addressed to an AI coding/assistant agent that will carry it out.

Write in second person ("you"), imperative and specific — you are addressing the agent directly. The output is pasted straight into that agent, so phrase everything as direct instructions to it and NEVER refer to "the user", "the recording", "the speaker", or what someone "wants" or "instructed" — say "Rename \`handleTap\` to \`handleSubmit\`", not "The user wants \`handleTap\` renamed". The agent did NOT see the recording, so translate everything shown or referenced into explicit description it can act on without the visuals.

Use the frames to extract the concrete specifics the agent needs: exact labels, filenames, function names, endpoints, values, and UI element names. Pull these in so the agent is not guessing. When the user refers to something vaguely ("this", "here", "that thing"), resolve it against the frames and state it plainly.

When the user describes an outcome without naming the exact technical mechanism, express the requirement at the level of intent the agent can implement, rather than inventing a specific implementation detail the user did not state. If a requirement is genuinely ambiguous and the frames do not resolve it, surface it as a brief open question rather than guessing. If the narration points out a problem or error without explicitly asking for a fix, capture it as the issue to address — describe the problem precisely, but don't invent a specific solution that wasn't indicated.

Structure:
- Lead with a one-sentence summary of the goal.
- Then the specific requirements as a tight, ordered list. If the recording contains several distinct requests, give each its own item (or short section) so none is blended together or dropped.
- Weave the concrete specifics (exact labels, filenames, values, paths) into the requirement they belong to, rather than listing them separately.
- End with any constraints or "do not" conditions the user stated.

Keep it lean. Do not pad with explanation of why — the agent needs what to do. Drop the user's emotional framing and asides; keep only what is actionable.

If the recording contains no actionable request to rewrite, do not fabricate a task from the frames. Output a single plain line stating that no clear request was captured (for example: "No actionable request found in this recording.") and nothing else.`;

const EXPLAIN = `TASK: Produce a clear, thorough explanation of what the recording shows, tailored to who it is for.

Infer the audience and purpose from the narration:
- The user asking for their own understanding — "how does this work?", "what is this?", "where do I find X?" — answer them directly and completely, as a reply to their question; you may address them as "you."
- An explanation meant to be passed on to someone or something else ("so I can send this to a coworker", "explain this for the team") — write a self-contained explanation for that recipient, in neutral third person.
- Audience unclear — default to a self-contained explanation any reader who did not see the recording could follow.

When the user asks a specific question, answer it. Ground the answer in the frames, the on-screen text, and the narration; you may use general knowledge of well-known tools or sites to fill small gaps, but the recording is the source of truth — say plainly when something cannot be determined from it rather than guessing.

Be thorough: cover the full picture the recording supports — components, behavior, how the parts relate, and the order things happen — at the depth the content warrants. Favor completeness over brevity, but stay substantive: no filler, no restating the obvious. If the recording covers several distinct things or screens, explain each rather than forcing them into one.

If the user voices a wish or intention without asking you to do or answer anything ("I want to fix this", "make it do X"), do not turn it into an instruction — render it as a described characteristic of the subject (e.g. "the error handling is currently fragile," as an observed property). Surface what the user emphasized as notable.

Structure:
- Open directly with the substance — the first sentence should BE the answer, the title of what this is, or the first real point, not a meta lead-in. Do NOT open with "This recording shows...", "The recording shows...", "Based on the recording...", "Here is...", "In this video...", or any framing-about-the-recording phrasing; begin with the actual content.
- If the recording is mainly a process or how-to (steps in sequence), lay it out as those ordered steps so the reader could follow them; otherwise explain the components and behavior in plain language, in the depth the recording supports.
- Include any characteristic the user clearly treated as important.

Do not invent facts, steps, or details the recording and the user's question don't support.`;

const composedSystemPrompt = (mode) => `${BASE}\n\n${mode === "explain" ? EXPLAIN : INSTRUCT}`;

// ---------- pricing (PINNED MIRROR of generate/cost.ts) ----------------------
// Keep this a complete, 1:1 mirror of CHAT_PRICING in
// supabase/functions/generate/cost.ts — EVERY model in the eval matrix
// (README-eval.md) must be priced here so no run shows "unpriced". If a model
// is added to the matrix, add it here AND in cost.ts. USD per 1M tokens; Gemini
// output rates already fold in thinking tokens (we add thoughtsTokenCount into
// outputTokens, matching the server). Anthropic output rates likewise fold in
// any thinking tokens that ride in output_tokens.
//
// PHASE 0 NOTE (multi-model gate): cost.ts has NOT been updated yet — that lands
// in Phase 2. This table is ahead of cost.ts on purpose so the harness can price
// the six candidate models now. Re-sync cost.ts against this block in Phase 2.
//
// Rates verified against provider docs 2026-06-09:
//   OpenAI    https://developers.openai.com/api/docs/pricing
//   Gemini    https://ai.google.dev/gemini-api/docs/pricing
//   Anthropic https://platform.claude.com/docs/en/about-claude/models/overview
//
// ⚠️ FLAG: the plan's §1.1 "GPT-5 mini" placeholder model id `gpt-5-mini` does
// NOT exist at OpenAI (confirmed against the pricing/models docs above). The
// current cheapest GPT-5-family mini is `gpt-5.4-mini` ($0.75/$4.50), priced
// below as the stand-in "Lowest cost" OpenAI model. Confirm the intended id with
// Colin before Phase 2 wires the registry.
const CHAT_PRICING = {
  // — legacy / prior eval baseline —
  "openai:gpt-4o": { inPerM: 2.5, outPerM: 10.0 }, // 2026-05-28 list
  // — the six Phase 0 candidates —
  "openai:gpt-5.4-mini": { inPerM: 0.75, outPerM: 4.5 }, // stand-in for plan's "gpt-5-mini" (does not exist)
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

// ---------- interleaving (mirror of generate/interleave.ts) ------------------

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
      // Phase 3: redacted on-screen text after the image (mirror interleave.ts).
      if (it.ocrText) blocks.push({ type: "text", text: `\n[${mmss(it.start)}] on-screen text: ${it.ocrText}` });
    } else if (it.kind === "click") {
      // Phase 4: a click line (mirror interleave.ts / encodeBody).
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

// ---------- chat adapters (mirror providers/openai.ts + gemini.ts) -----------

// One retry on a transient fault (429 / 5xx), mirroring the single retry the
// production openai.ts / gemini.ts adapters do. Keeps a flaky 503 from one
// provider on one clip from torpedoing a whole matrix run.
async function fetchRetry(url, init) {
  try {
    const res = await fetch(url, init);
    if (res.status === 429 || res.status >= 500) {
      await new Promise((r) => setTimeout(r, 1500));
      return await fetch(url, init);
    }
    return res;
  } catch {
    // Network-level throw (DNS, reset, "fetch failed") — retry once before giving up.
    await new Promise((r) => setTimeout(r, 1500));
    return await fetch(url, init);
  }
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

// chatAnthropic — Phase 0 mirror of what Phase 3's providers/anthropic.ts will
// send on the Messages API. Maps the neutral interleaved blocks to Anthropic
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

const workingDir = process.argv[2];
if (!workingDir || workingDir.startsWith("--")) {
  console.error("usage: node Scripts/eval-models.mjs <workingDir> --mode instruct|explain --models provider:model,... [--thinking low|high] [--out dir]");
  process.exit(1);
}

const mode = arg("mode", "instruct");
const models = arg("models", "gemini:gemini-3.5-flash,openai:gpt-4o").split(",").map((s) => s.trim());
const thinkingLevel = arg("thinking", "low");
const outDir = arg("out", "eval-results");

const openaiKey = process.env.OPENAI_API_KEY;
const geminiKey = process.env.GEMINI_API_KEY;
const anthropicKey = process.env.ANTHROPIC_API_KEY;
if (!openaiKey) { console.error("OPENAI_API_KEY required (whisper STT)"); process.exit(1); }
if (models.some((m) => m.startsWith("gemini:")) && !geminiKey) {
  console.error("GEMINI_API_KEY required for gemini models"); process.exit(1);
}
if (models.some((m) => m.startsWith("anthropic:")) && !anthropicKey) {
  console.error("ANTHROPIC_API_KEY required for anthropic models"); process.exit(1);
}

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
// (hasSpeech === false), skip Whisper entirely — exactly as the live BYOK and
// Managed paths do — and run on an empty transcript (timeline = frames + OCR +
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

const systemPrompt = composedSystemPrompt(mode);
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
    `Small-text fidelity = read on-screen code/UI text correctly · Deixis = resolved "this/that/here" to the right frame · Hallucination = invented nothing not shown/said (5 = none) · Faithfulness = to intent (instruct) / accuracy (explain).`,
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
