# Claude Code handoff — Phase 2 tail: managed/trial hover-deixis (the 2-call flow)

Bring the FULL hover-deixis to the managed (and trial) path. Today BYOK
(`runLocalPromptGeneration`) does the real thing — resolves anchors locally and
ships marked frames to the model — but managed (`runProxyGeneration`) makes a
single `/generate` call with click-only anchoring. Wire the **2-call managed flow**
from the M0 dataflow plan so paying + trial users get the same deixis quality.

This is backend + client + billing-adjacent. Build, then **STOP for review +
the live E2E** before finalizing.

## Read first
- `docs/HANDOFF-dev-mode-phase2-dataflow.md` — the M0 decision + the exact 2-call
  contract and data shapes. **Binding.**
- `AppState.swift`: `runLocalPromptGeneration` (~2144 — the BYOK resolution to
  reuse: `DeixisResolver.resolve` ~2214, `DevAnchorPipeline.build` ~2219, the
  confidence combine, then `finishGenerationOrDispatch`) and `runProxyGeneration`
  (~1914 — the managed/trial path to upgrade). Note both managed AND trial route
  through `runProxyGeneration` (lines ~1787/1794), so this gives trial users
  hover-deixis too.
- `Services/Managed/ManagedProxyClient.swift` (`generate`, `convert`; no
  `devTranscribe` yet).
- `supabase/functions/generate/handler.ts`: `dev-transcribe` (call 1, ~157-166 —
  free, built) and the main generate path (~174 — needs the dev call-2 enrichment).
- `supabase/functions/generate/prompt.ts` (keep the dev prompt in sync with Swift).

## Ground rules
- BYOK behavior unchanged. Normal (non-dev) managed/trial behavior byte-identical.
- The client-side resolution is path-agnostic — **factor it out and reuse it**;
  do NOT duplicate the resolver/pipeline/gate logic for managed.
- Billing: call 1 is FREE (no credit/slot — already enforced server-side); the
  credit is consumed exactly once, on call 2.

## Part 1 — factor out the shared client resolution
Extract the anchor-resolution sequence from `runLocalPromptGeneration` into a
shared helper (e.g. `resolveDevAnchors(processed:transcript:) -> (referringExprs,
markedFrames, ocr, clientResolvedAnchors)`): the `DeixisResolver.resolve` +
`DevAnchorPipeline.build` over the cursor track + native frames + OCR + marker +
client confidence. BYOK and managed both call it; the ONLY differences between the
paths are (a) where the word transcript comes from and (b) where generation runs.

## Part 2 — ManagedProxyClient: the two calls
- `devTranscribe(audio:hasSpeech:) -> Transcript` — POST `/generate`
  `{mode:"dev-transcribe", audio, has_speech}`; parse the word-level transcript.
  (Server side is built + free.)
- Extend `generate` (or add a dev variant) for **call 2**: send the enriched dev
  payload — `mode:"dev"`, the **pre-supplied transcript** (so the server skips
  re-STT), the **marked native-res frames + OCR + referring-expressions**, plus
  the existing frames/clicks — and parse the response's `{ prompt, anchors:[…] }`
  (the structured per-reference anchors). NO audio in call 2 (it rode in call 1).

## Part 3 — runProxyGeneration: the 2-call orchestration
Restructure the managed/trial dev branch to mirror BYOK's outputs:
1. Call 1 `devTranscribe` → word transcript (free; show the `transcribing` pill).
2. Shared `resolveDevAnchors` (Part 1) using that transcript (`resolvingAnchors`).
3. Call 2 enriched `generate` → `agent_prompt` + model anchors (`writingPrompt`).
4. Populate the SAME state BYOK does — `generatedPrompt`/`parsedResponse`,
   `devResolvedAnchors` (client), `devModelAnchors` (from call 2) — then call
   `finishGenerationOrDispatch()`. The existing dispatch tail (checkpoint → the
   `confirmAnchors` gate via `combinedConfidence` → runner) is already shared, so
   no changes there.
Handle `has_speech == false` (no transcript → fall back to click/dwell anchoring,
don't break the flow), and surface call-1/call-2 failures through the existing
managed error mapping.

## Part 4 — server generate, dev mode call 2 (enrichment)
Extend the main generate path's `mode:"dev"` to accept the enriched inputs:
- a **pre-supplied transcript** → skip STT, generate against the exact transcript
  the anchors were resolved against (and don't double-charge STT);
- the **marked frames + OCR strings + referring-expressions** as model inputs;
- return the `agent_prompt` artifact **plus** the structured `anchors:[{ref, label,
  type, region, current_state, confidence, alt_candidates}]` (the M7 contract —
  the SAME shape BYOK's local generation produces).
Keep `prompt.ts`'s dev prompt in sync with the Swift dev prompt; the no-arg/normal
path stays byte-identical (mirror test green). Deno tests for the enriched dev
request/response + the pre-supplied-transcript-skips-STT path.

## Part 5 — billing
Call 1 (`dev-transcribe`) charges nothing / takes no slot (already enforced).
Call 2 consumes the credit once. Confirm: audio uploads only in call 1; call 2
carries transcript + marked frames (no re-upload); idempotency key spans the
dispatch so a retry doesn't double-charge. Verify a managed dev run debits exactly
one charge.

## Part 6 — live E2E (STOP for review)
- **Managed** (your local managed setup): record localhost, say "make *this*
  bigger" while HOVERING (no click) → it resolves to the correct labeled element
  via the 2-call flow and the agent edits it; a deliberately ambiguous point →
  `confirmAnchors`. Confirm exactly one credit charged.
- **BYOK**: the same hover-only E2E (this was never confirmed live) — verify the
  full chain end to end.

## Acceptance criteria
- Managed + trial dev recordings do full hover-deixis (transcribe → resolve →
  enriched generate → anchored prompt), not click-only — verified live.
- The client resolution is shared between BYOK and managed (no duplication).
- Call 1 free, call 2 charges once; no audio re-upload; no double-charge.
- Server dev mode returns the agent_prompt + structured anchors; prompt mirror
  green; BYOK + normal-mode behavior unchanged.

## Notes
- This completes the M0 architecture: client-side resolution on both paths;
  transcript from local Whisper (BYOK) or call 1 (managed); generation local
  (BYOK) or call 2 (managed). Same resolver, same gate, same dispatch.
- Trial rides `runProxyGeneration` too, so it gets hover-deixis for free here.
