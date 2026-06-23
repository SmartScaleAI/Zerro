// =============================================================================
// `convert` request parsing + input fuse (Phase 6).
// =============================================================================
// Wire shape (the client sends plain text — no audio, no frames):
//   {
//     "source_text": "<the previous response's chat text>",   // required
//     "context": "## Attached Context\n…",                    // optional
//     "model": "gemini-3.5-flash"                              // optional
//   }
// Caps are the plan's contract (source_text ≤ 20k chars, context ≤ 6k). A real
// client can't trip them (chat text is model output; the context builder caps
// at ~4k) — they only reject a forged payload before any provider call.
// `model` is validated against the same ALLOWED_MODELS registry as generate
// (read-only import — this phase does not touch generate/**).
// =============================================================================

import { ALLOWED_MODELS, CHEAPEST_ENABLED_MODEL_ID, DEFAULT_MODEL_ID } from "../generate/models.ts";
import { CONVERT_MAX_CONTEXT_CHARS, CONVERT_MAX_SOURCE_CHARS } from "./config.ts";

export interface ParsedConvertRequest {
  /** The text to rewrite — the previous response's chat text. */
  sourceText: string;
  /** The recording's Attached Context block, when the client has one. */
  context: string | null;
  /** Validated model id (absent on the wire → the registry default). Selects
   *  the provider adapter ONLY — never the (server-owned) prompt. */
  model: string;
}

export type ConvertValidationResult =
  | { ok: true; value: ParsedConvertRequest }
  | { ok: false; status: number; error: string };

function reject(status: number, error: string): ConvertValidationResult {
  return { ok: false, status, error };
}

export function validateConvertBody(body: unknown): ConvertValidationResult {
  if (typeof body !== "object" || body === null) return reject(400, "invalid_body");
  const b = body as Record<string, unknown>;

  // source_text — required, non-empty after trim, char-capped.
  const rawSource = b.source_text;
  if (typeof rawSource !== "string" || rawSource.trim().length === 0) {
    return reject(400, "missing_source_text");
  }
  if (rawSource.length > CONVERT_MAX_SOURCE_CHARS) return reject(413, "source_text_too_long");

  // context — optional. A non-string value is tolerated as absent (same
  // drop-don't-reject posture as generate's clicks); an over-cap string is a
  // forged payload → reject.
  let context: string | null = null;
  if (typeof b.context === "string" && b.context.trim().length > 0) {
    if (b.context.length > CONVERT_MAX_CONTEXT_CHARS) return reject(413, "context_too_long");
    context = b.context;
  }

  // model — optional; absent → registry default; present-but-unknown → 400
  // (ALLOWED_MODELS is also the kill switch, same as generate).
  let model: string = DEFAULT_MODEL_ID;
  if (b.model !== undefined && b.model !== null) {
    if (typeof b.model !== "string" || !ALLOWED_MODELS.has(b.model)) {
      return reject(400, "invalid_model");
    }
    model = b.model;
  }

  return { ok: true, value: { sourceText: rawSource, context, model } };
}

/**
 * The effective conversion model for a given token kind (X-01 / B-01).
 * `convert` is a structured rewrite, so the priciest models add no value but cost
 * the most against the metered trial pool. A TRIAL token is therefore pinned to
 * the cheapest enabled model regardless of the client's selection — the model is
 * NOT caller-selectable for trials. A managed/subscription token keeps full model
 * choice (it's already paying; behavior unchanged). This is the convert-side
 * "cheap model subset" allow-list: the subset for trials is exactly {cheapest}.
 */
export function modelForConvert(kind: "subscription" | "trial", requested: string): string {
  return kind === "trial" ? CHEAPEST_ENABLED_MODEL_ID : requested;
}
