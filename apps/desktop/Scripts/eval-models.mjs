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

The transcript is raw speech: it contains filler words, false starts, self-corrections, and informal phrasing. Treat it as intent, not literal text. When the user corrects themselves, follow the corrected version and ignore the abandoned one.

The frames show what the user was looking at or pointing to. Use them to ground vague spoken references ("this button", "that error", "here") in concrete on-screen detail. When speech and frames conflict, the frames are the source of truth for what exists; the speech is the source of truth for what the user wants.

Resolving a vague reference to what the frames clearly show is correct and expected. Inventing specifics that are neither shown nor stated is not. When the user gestures at something without naming the exact mechanism, stay at the level of detail the frames and speech support — do not fabricate precise values, names, or settings the user never provided. If a reference is genuinely ambiguous and the frames cannot resolve it, note the ambiguity briefly rather than guessing.

The user may speak mostly about what they want changed or done, rather than describing what is on screen. Capture their actual intent regardless of how it is phrased; do not let the form of their speech distort the output format.

Output ONLY the final result. No preamble, no "Here is...", no closing remarks, no markdown fences around the whole thing. The output goes straight to the clipboard.

OUTPUT MODE: The user has selected an output mode (provided below). Treat it as the default. Only override it if the user's speech contains a direct, explicit request for a different output format (e.g. "actually, just explain this" or "write this as instructions instead"). Do NOT switch modes because format-related words happen to appear while the user is describing their screen or content. When in doubt, follow the selected mode.`;

const INSTRUCT = `TASK: Rewrite the user's spoken request as a clear, structured instruction addressed to an AI coding/assistant agent that will carry it out.

Write in second person ("you"), imperative and specific. The agent did NOT see the recording — translate everything the user showed or referenced into explicit description the agent can act on without the visuals.

Use the frames to extract the concrete specifics the agent needs: exact labels, filenames, function names, endpoints, values, and UI element names. Pull these in so the agent is not guessing. When the user refers to something vaguely ("this", "here", "that thing"), resolve it against the frames and state it plainly.

When the user describes an outcome without naming the exact technical mechanism, express the requirement at the level of intent the agent can implement, rather than inventing a specific implementation detail the user did not state. If a requirement is genuinely ambiguous and the frames do not resolve it, surface it as a brief open question rather than guessing.

Structure:
- Lead with a one-sentence summary of the goal.
- Then the specific requirements as a tight list, in execution order.
- Include the concrete details pulled from the frames.
- End with any constraints or "do not" conditions the user stated.

Keep it lean. Do not pad with explanation of why — the agent needs what to do. Drop the user's emotional framing and asides; keep only what is actionable.`;

const EXPLAIN = `TASK: Produce a clear explanation of what the user is showing, for a reader who has not seen the recording.

Write in third person, descriptive and neutral. Describe what the thing is, what it does, and how its parts relate, based on what is visible in the frames and what the user narrates.

Use the frames to reconstruct structure and sequence for the reader: what the components are, how they relate, and the order in which things happen across the recording. Favor a coherent picture of the whole over isolated details.

The user may phrase things as requests or intentions ("I want to fix this", "make it do X"). Do not turn these into instructions. Instead, translate them into described characteristics of the subject. For example, if the user says they want to fix fragile error handling, the explanation may note that the error handling is currently fragile — as an observed property, not a task. Surface what the user verbally emphasized as notable, framed descriptively.

Structure:
- Open with a one-sentence "what this is."
- Then explain the key components or behavior in plain language.
- Include any characteristic the user clearly treated as important.

Do not give instructions or next steps unless the user explicitly asked. This is an explanation, not a task.`;

const composedSystemPrompt = (mode) => `${BASE}\n\n${mode === "explain" ? EXPLAIN : INSTRUCT}`;

// ---------- pricing (PINNED MIRROR of generate/cost.ts) ----------------------
// Keep this a complete, 1:1 mirror of CHAT_PRICING in
// supabase/functions/generate/cost.ts — EVERY model in the eval matrix
// (README-eval.md) must be priced here so no run shows "unpriced". If a model
// is added to the matrix, add it here AND in cost.ts. USD per 1M tokens; Gemini
// output rates already fold in thinking tokens (we add thoughtsTokenCount into
// outputTokens, matching the server). Pinned to the 2026-06-04 list.
const CHAT_PRICING = {
  "openai:gpt-4o": { inPerM: 2.5, outPerM: 10.0 }, // 2026-05-28 list
  "gemini:gemini-3.5-flash": { inPerM: 1.5, outPerM: 9.0 }, // 2026-06-04 list, flat
  "gemini:gemini-3.1-pro-preview": { // 2026-06-04 list, tiered by input tokens
    inPerM: 2.0, outPerM: 12.0, tierThreshold: 200_000, inPerMAbove: 4.0, outPerMAbove: 18.0,
  },
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

/** Neutral timeline: text blocks + image blocks, chronological, frame-before-speech. */
function buildTimeline(frames, segments) {
  const items = [
    ...frames.map((f) => ({ kind: "frame", start: f.timestampSeconds, base64: f.base64, ocrText: f.ocrText })),
    ...segments.map((s) => ({ kind: "speech", start: s.start, end: s.end, text: s.text })),
  ];
  items.sort((a, b) =>
    a.start !== b.start ? a.start - b.start : (a.kind === "frame" ? 0 : 1) - (b.kind === "frame" ? 0 : 1)
  );
  const blocks = [];
  for (const it of items) {
    if (it.kind === "frame") {
      blocks.push({ type: "text", text: `\n[${mmss(it.start)}] ` });
      blocks.push({ type: "image", mime: "image/jpeg", base64: it.base64 });
      // Phase 3: redacted on-screen text after the image (mirror interleave.ts).
      if (it.ocrText) blocks.push({ type: "text", text: `\n[${mmss(it.start)}] on-screen text: ${it.ocrText}` });
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

async function chatOpenAI(model, systemPrompt, blocks, key) {
  const content = blocks.map((b) =>
    b.type === "text"
      ? { type: "text", text: b.text }
      : { type: "image_url", image_url: { url: `data:${b.mime};base64,${b.base64}`, detail: "high" } }
  );
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
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
  const res = await fetch(
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
if (!openaiKey) { console.error("OPENAI_API_KEY required (whisper STT)"); process.exit(1); }
if (models.some((m) => m.startsWith("gemini:")) && !geminiKey) {
  console.error("GEMINI_API_KEY required for gemini models"); process.exit(1);
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
const cachePath = join(workingDir, "transcript.eval.json");
let transcript;
if (existsSync(cachePath)) {
  transcript = JSON.parse(readFileSync(cachePath, "utf8"));
  console.error(`transcript: cached (${transcript.segments.length} segments)`);
} else {
  console.error("transcribing with whisper-1…");
  transcript = await transcribe(join(workingDir, manifest.audioFilename), openaiKey);
  writeFileSync(cachePath, JSON.stringify(transcript, null, 2));
  console.error(`transcript: ${transcript.segments.length} segments, ${transcript.durationSeconds.toFixed(1)}s measured`);
}

const systemPrompt = composedSystemPrompt(mode);
const blocks = buildTimeline(frames, transcript.segments);
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
