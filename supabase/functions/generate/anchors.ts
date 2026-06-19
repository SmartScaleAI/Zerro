// =============================================================================
// Dev Mode anchor extraction (Phase 2 §7) — pull the structured per-reference
// anchors out of the model's `zerro_anchors` block so the dev CALL 2 response
// can return them as `anchors[]` (the M7 contract). DEFENSIVE by construction:
// any absence / malformation degrades to [] (never throws), mirroring the Swift
// `DevAnchorParser` discipline — the client then coerces each entry leniently
// (`DevAnchorParser.parseJSON`) into its `[DevAnchor]`, so server + client agree
// on the same lenient interpretation.
//
// The block is metadata the dev prompt emits OUTSIDE the ZERRO_ARTIFACT fence
// (prompt.ts PROMPT_DEV "DEIXIS ANCHORS"); the agent_prompt artifact itself is
// parsed separately, client-side, by ArtifactParser. We pass the parsed JSON
// array through verbatim rather than re-coercing it here — the client owns the
// field-level coercion (one canonical parser), and the array IS the structured
// shape the handoff contract specifies.
//   KEEP IN SYNC with Zerro/Services/Dev/DevAnchor.swift (DevAnchorParser.extractBlock)
// =============================================================================

/** Extract the anchor array from a model response's `zerro_anchors` block.
 *  Returns the parsed JSON array verbatim (the client coerces field-by-field),
 *  or [] for any absence / non-array / parse failure. */
export function extractAnchors(raw: string): unknown[] {
  const block = extractBlock(raw);
  if (block === null) return [];
  try {
    const parsed = JSON.parse(block);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/** Pull the inner text of a ```zerro_anchors … ``` fence (the lowercase tag the
 *  prompt emits, with an uppercase fallback). Falls back to a bare top-level JSON
 *  array that looks like our anchor list. null when neither is present. Mirrors
 *  Swift `DevAnchorParser.extractBlock`. */
function extractBlock(raw: string): string | null {
  const fenced = between(raw, "```zerro_anchors", "```") ?? between(raw, "```ZERRO_ANCHORS", "```");
  if (fenced !== null) return fenced;
  // Bare-array fallback: a `[ … ]` that looks like our anchor list (only reached
  // when the model omitted the fence — the same fallback the Swift parser uses).
  const l = raw.indexOf("[");
  const r = raw.lastIndexOf("]");
  if (l !== -1 && r !== -1 && l < r) {
    const slice = raw.slice(l, r + 1);
    if (slice.includes("label") || slice.includes("confidence")) return slice;
  }
  return null;
}

function between(s: string, open: string, close: string): string | null {
  const start = s.indexOf(open);
  if (start === -1) return null;
  const afterOpen = start + open.length;
  const end = s.indexOf(close, afterOpen);
  if (end === -1) return null;
  return s.slice(afterOpen, end).trim();
}
