# Zerro Refactor: Modes → Typed-Artifact Responses

Implementation plan for Claude Code. Implement ONE PHASE AT A TIME, in order.
Each phase ends with a green build, passing tests, and a working app. Do not
start a phase until the previous one is complete and verified.

---

## 1. What is changing and why

Zerro currently makes the user pick an output mode (**Instruct** = markdown
prompt for an AI coding agent, **Explain** = natural-language explanation)
before recording. This refactor removes modes entirely. Instead, the model
infers intent from the narration and returns:

1. **Chat text** — always present, natural language, addressed to the user.
2. **An optional typed artifact** — a discrete copyable deliverable (agent
   prompt, email draft, formula, etc.) rendered as a card with a dynamic copy
   button ("Copy to Agent", "Copy draft", …).

The Claude/code-block pattern: prose answer + copyable attachment. Developers
were never a special mode — `agent_prompt` is just one artifact type.

### Locked product decisions (do not re-litigate these)

| Decision | Choice |
|---|---|
| Migration | Hard cut — app is unlaunched, no backward compat for `mode` |
| Artifact types in v1 | `agent_prompt`, `message`, `snippet`, `document`, `generic` |
| Artifacts per response | Max ONE |
| Ambiguity default | Chat-only answer; bias toward attaching when narration expresses a concrete change |
| Auto-copy on completion | REMOVED — clipboard changes only on explicit button tap |
| BYOK path | Full parity in v1 (same prompt, same parsing, same UI) |
| Toolbar mode switch | Removed, replaced by nothing (model picker + mic chip remain) |
| Attached Context contents | OCR text + click labels, assembled CLIENT-side (no transcript; no server change) |
| Copy semantics | `agent_prompt` copies body + Attached Context; all other types copy body only |
| Conversion fallback | "Write agent prompt" button on artifact-less responses, lazy generation, charges the user 0 credits |
| Streaming | Stays non-streaming (single JSON response), card auto-expands when ready |
| Response parsing | CLIENT-side (single Swift parser serves both Managed and BYOK paths; server stays pass-through) |

---

## 2. The output contract (the spine of the refactor)

The model emits plain text in this shape. The parser lives in Swift.

```
<chat text — always first, always present, addressed to the user, markdown allowed>

<<<ZERRO_ARTIFACT type="agent_prompt" title="Fix silent promo code failure">>>
<artifact body — markdown>
<<<END_ZERRO_ARTIFACT>>>
```

Contract rules:

- Chat text always comes first. The artifact block, if present, comes after it.
- At most one artifact block. Delimiters must be alone on their own lines.
- `type` is one of exactly: `agent_prompt | message | snippet | document | generic`.
- `title` is a model-written one-liner (≤ 80 chars), used as the card header
  and the history entry title.
- The `<<<ZERRO_ARTIFACT` / `<<<END_ZERRO_ARTIFACT` fences were chosen over
  XML-style tags because the model may legitimately write XML/HTML inside an
  artifact body; the triple-chevron + ZERRO_ prefix at line start is
  collision-proof in practice.

Parser behavior (fail-safe, strict):

- Well-formed block → `ParsedResponse(chatText:, artifact: Artifact(type:, title:, body:))`.
- Unknown `type` string → coerce to `.generic`, keep title/body, log a warning.
- Malformed/unclosed block, multiple blocks, or fence mid-line → treat the
  ENTIRE raw output as chat text with no artifact, log a warning. Never crash,
  never render a broken card.

Recovery tier (§2 amendment, 2026-06-11, approved by Colin after Phase 1
eval): before falling back to chat-only, the parser applies EXACTLY these
three recovery rules — a closed list, no other best-effort recovery. Each
rule still requires the literal `ZERRO_ARTIFACT` / `END_ZERRO_ARTIFACT`
tokens, parseable `type`/`title` attributes, and the single-block discipline;
recovery can rescue a malformed fence, never invent an artifact.

- **R1 — wrong trailing chevron count on the open fence.** A line starting
  with `<<<ZERRO_ARTIFACT` at column 0 whose attributes parse and which ends
  with ≥ 1 `>` (e.g. `…">` or `…">>>>`).
- **R2 — body spillover on the open fence.** As R1, but with text after the
  trailing chevron run on the same line → that text becomes the first body
  line.
- **R3 — close fence glued to the last body line.** A line that ENDS with the
  exact `<<<END_ZERRO_ARTIFACT>>>` token → the text before the token is the
  last body line; the block closes there.

Anything else (open fence mid-line/indented, close token followed by text,
zero chevrons, unparseable attrs, two blocks, open+close on one line) still
falls back to whole-output-as-chat-text. A recovered parse is `valid` but
flagged `recovered`; the eval scorecard reports recovery rate as its own
metric (separate from validity) so a climbing rate under future prompt edits
is visible, not silent. Rationale: Phase 1 measured the default model
(gemini-3.5-flash) plateauing at 95% strict validity on purely mechanical
fence-boundary slips — 10/10 observed slips were exactly R1/R2/R3 and all
parsed type-correct under this tier. The executable spec is
`apps/desktop/Scripts/artifact-eval/parser-tests.json` (strict +
recovery-tier cases, including those 10 real outputs); Phase 2's
`ArtifactParserTests.swift` ports and must pass the same list.

Per-type UI table (single source of truth — implement as a Swift enum):

| type | Button label | Icon | Body rendering | Copy payload | Context tag |
|---|---|---|---|---|---|
| `agent_prompt` | Copy to Agent | `{}` | markdown, mono-leaning | body + "\n\n## Attached Context\n" + context | INCLUDED IN COPY |
| `message` | Copy draft | envelope | prose | body only | FOR REFERENCE |
| `snippet` | Copy snippet | chevron | monospace code | body only (exact) | FOR REFERENCE |
| `document` | Copy text | doc | prose | body only | FOR REFERENCE |
| `generic` | Copy | doc | markdown | body only | FOR REFERENCE |

Attached Context block (client-assembled, shown in the drawer and appended on
`agent_prompt` copy):

```
## Attached Context
**Screen text (OCR excerpts):** <deduped, length-capped OCR from selected frames>
**Clicks:** clicked "Sign in", clicked "Apply", …
```

Cap the assembled context at ~4,000 chars; dedupe repeated OCR lines across
frames; omit either section if empty; omit the whole drawer if both are empty.

---

## 3. Codebase map (verified file paths)

Prompt copies that MUST stay byte-mirrored (existing discipline, keep it):

- `apps/desktop/Zerro/Services/PromptGenerationSystemPrompt.swift` (BYOK base)
- `apps/desktop/Zerro/Services/PromptModes.swift` (BYOK mode layers — will be deleted)
- `supabase/functions/generate/prompt.ts` (Managed copy)
- `apps/desktop/Scripts/eval-models.mjs` (eval mirror)
- `zerro-prompt-system.md` (canonical product-IP doc — update to v2)

Mode touchpoints (all to be removed/refactored):

- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` — `OutputMode` enum, `defaultOutputMode`, `Keys.defaultOutputMode`, `resettable`, `resetToDefaults()`
- `apps/desktop/Zerro/Surfaces/Settings/Sections/OutputModeSection.swift` — delete
- `apps/desktop/Zerro/Surfaces/Settings/SettingsView.swift` — section registration
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorState.swift` — `outputMode`, `hoveredOutputMode`, `setOutputMode`, `setHoveredOutputMode`
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift` — segmented Instruct/Explain switch + hit-testing + hint text
- `apps/desktop/Zerro/AppState.swift` — `recordingOutputMode`, `effectiveOutputMode`, `.confirmingMode` state, `resolveModeSwitch`, `debugForceModeSwitchPill`, `beginRecording(outputMode:)` param, mode-switch check in the processing pipeline
- `apps/desktop/Zerro/Services/ModeSwitchDetector.swift` — delete (~340 lines)
- `apps/desktop/Zerro/Services/ModeSwitchPatterns.swift` + its JSON tuning file — delete
- `apps/desktop/Zerro/PillStateBridge.swift` — `.confirmingMode` mapping
- `apps/desktop/Zerro/Surfaces/Pill/PillView.swift` — `.confirmSwitch` case + confirm-pill view + `onKeepMode`/`onSwitchMode`
- `apps/desktop/Zerro/Services/Managed/ManagedProxyClient.swift` — `mode` in `encodeBody`/`generate`
- `supabase/functions/generate/limits.ts` — `mode` validation
- `supabase/functions/generate/handler.ts` — `composedSystemPrompt(mode)` call site
- `apps/desktop/Zerro/AppBehavior/DiagnosticsCollector.swift`, `Surfaces/MenuBarPanel/MenuBarPanelView.swift`, `Surfaces/Settings/Sections/BillingSection.swift`, `Processing/ClickResolver.swift`, `Services/Gemini/GeminiPromptGenerationService.swift`, `ZerroApp.swift` — grep hits for mode/instruct/explain; audit each during Phase 5

Other load-bearing facts:

- `/generate` request: `{ mode, model, audio{mime,filename,data,duration_seconds}, frames[{timestamp,mime,data,ocr_text}], clicks[{timestamp,label}], has_speech }` + `Idempotency-Key` header. Response: `{ prompt, usage{input_tokens,output_tokens,model}, credits_remaining, credits_charged }`.
- Server money-safety ordering in `handler.ts` (slot → idempotent replay → credit check → STT → true-seconds gate → chat → consume-on-success) MUST NOT be disturbed. The refactor only touches step 11 (prompt composition) and validation.
- Idempotency cache stores the raw `prompt` string — unaffected, since the raw tagged text is what rides the wire and the client parses.
- History: `apps/desktop/Zerro/History/RecentPromptStore.swift`, `RecentPrompt{id,title,prompt,timestamp}`, 50-entry cap, JSON file.
- Clipboard: `apps/desktop/Zerro/Surfaces/Pasteboard.swift` (single copy helper — keep).
- Auto-copy on completion currently happens in AppState's generation completion path ("orchestrator copies verbatim to clipboard") — find and remove in Phase 4.
- BYOK providers: `Services/OpenAI/OpenAIPromptGenerationService.swift`, `Services/Anthropic/…`, `Services/Gemini/…` behind `PromptGenerationService` protocol; system prompt passed at call time, so they need no changes beyond the composed string.
- Eval harness already exists: `apps/desktop/Scripts/eval-models.mjs`, `run-phase0-matrix.sh`, `capture-recording.sh`, `README-eval.md`.

---

## Phase 0 — Eval fixtures + harness extension

Goal: a labeled test set and a scorer for the NEW contract, before any prompt
is written. This is the safety net for everything after.

1. Create `apps/desktop/Scripts/artifact-eval/fixtures.json`: 40 cases minimum.
   Each case: `{ id, transcript, ocr_summary, clicks, expected: { has_artifact, type|null, notes } }`.
   Distribution: ~14 `agent_prompt` (debugging, UI changes, feature asks),
   ~6 `message`, ~5 `snippet` (formulas, commands), ~5 `document`,
   ~8 chat-only (what/why/how-does questions, guidance), ~2 empty-narration
   (sign-off/filler → chat-only "no clear request" handling). Include the hard
   ambiguous cases: "how do I center this?" (expect chat + `agent_prompt`),
   "this is broken" with no fix asked (expect chat-only diagnosis).
2. Extend `eval-models.mjs` with an `--artifact` scoring mode: parse the fenced
   contract (port the parser rules from §2), score (a) attach/no-attach
   accuracy, (b) type accuracy, (c) contract validity rate (well-formed fences),
   (d) voice check — artifact body for `agent_prompt` must not contain "the
   user" (regex), chat text should contain "you"/direct address.
3. Update `Scripts/README-eval.md`.

Verification: harness runs against the CURRENT mode prompts as a smoke test
(scores will be meaningless — it's checking the pipeline runs end to end).

## Phase 1 — Author + tune prompt v2 (eval harness only, no app changes)

Goal: a locked, validated prompt. Nothing in the app or server changes yet.

1. Draft the unified system prompt as v2 of `zerro-prompt-system.md`. Structure:
   - **Layer 1 (input description):** reuse the existing BASE verbatim through
     the "don't merge requests" paragraph. REMOVE the "Output ONLY the final
     result / goes straight to the clipboard" paragraph and the entire OUTPUT
     MODE paragraph.
   - **Layer 2 (response shape):** chat text always, addressed to the user,
     open with substance (port EXPLAIN's no-meta-lead-in rules), markdown ok.
   - **Layer 3 (artifact decision):** "After understanding the narration,
     decide: did the user describe a discrete deliverable destined somewhere
     else (an AI agent, an inbox, a spreadsheet cell, a text field)? If yes,
     attach exactly one artifact block. If they are trying to understand
     something, or they themselves are the executor (settings walkthroughs,
     guidance), attach nothing. When the narration is borderline but names a
     concrete change to their project, attach." Plus the empty-narration rule
     (port from BASE/INSTRUCT: no fabricated tasks).
   - **Layer 4 (types + voice):** the five types with one-paragraph definitions.
     For `agent_prompt`, port the existing INSTRUCT layer near-verbatim
     (second person to the agent, never "the user", frames→specifics, lead
     summary + ordered requirements + constraints). For others: `message` =
     ready-to-send, recipient-appropriate tone; `snippet` = exact, runnable,
     no commentary inside the body; `document` = self-contained prose;
     `generic` = anything copyable that fits none of the above.
   - **Layer 5 (format):** the exact fence syntax from §2, title rules, the
     no-duplication rule (chat text must summarize, never restate the artifact
     body), chat text length cap (~120 words when an artifact is present).
   - **Layer 6 (few-shot):** 6–8 compact narration → output examples covering
     each type, one chat-only, one ambiguous-both case.
2. Iterate against the Phase 0 fixtures across all enabled registry models
   (OpenAI, Gemini, Anthropic) until: attach/no-attach ≥ 90%, contract
   validity ≥ 98%, type accuracy ≥ 85% on the default model.
3. Lock the text in `zerro-prompt-system.md` v2 with a dated changelog entry
   (existing change discipline).

Deliverable: locked prompt text + eval report. STOP and show Colin the scores
before Phase 2.

## Phase 2 — Parser + models (additive Swift code, nothing wired)

1. New `apps/desktop/Zerro/Services/ArtifactParser.swift`: implements §2
   exactly. Pure, `nonisolated`, no dependencies.
2. New `apps/desktop/Zerro/Services/ResponseModels.swift`:
   `ArtifactType` enum (with `buttonLabel`, `iconName`, `includesContextInCopy`,
   `rendersMonospace`), `Artifact`, `ParsedResponse`.
3. New `AttachedContextBuilder.swift`: builds the §2 context block from
   `[ExtractedFrame].ocrText` + `[ResolvedClick]` (dedupe, cap, omit-if-empty).
4. `ZerroTests/ArtifactParserTests.swift`: well-formed (each type), unknown
   type → generic, unclosed fence, two blocks, fence mid-line, fence inside a
   code block in chat text, empty body, title > 80 chars, CRLF input — PLUS
   the recovery-tier cases (R1/R2/R3 + guards): port every case in
   `apps/desktop/Scripts/artifact-eval/parser-tests.json`, which includes the
   10 real model outputs that motivated the tier. The Swift parser must agree
   with the JS reference on all of them.
   `AttachedContextBuilderTests.swift` likewise.
5. `RecentPromptStore` v2: `RecentPrompt` gains `chatText: String?`,
   `artifactType: String?`, `artifactBody: String?` (keep `prompt` as the raw
   text for fallback). Bump the JSON file name or add a version field; old
   file present → start empty (pre-launch, no migration). Title now prefers
   the model's artifact title, falling back to `deriveTitle`.

Verification: all new unit tests pass; app behavior unchanged.

## Phase 3 — Server refactor

1. `supabase/functions/generate/prompt.ts`: replace BASE/INSTRUCT/EXPLAIN with
   the locked v2 text. `composedSystemPrompt()` takes no arguments. Remove the
   `OutputMode` export. Keep the KEEP IN SYNC header, updated to the new files.
2. `limits.ts`: remove `mode` from validation and the parsed value (an old
   client still sending `mode` is silently ignored — hard cut, not a 400, so
   the in-flight dev build doesn't brick mid-rollout).
3. `handler.ts`: step 11 becomes `composedSystemPrompt()`. NOTHING else in the
   money-safety ordering changes.
4. Update `handler_test.ts` + any fixtures referencing mode.
5. Deploy order note: server ships BEFORE the Phase 4 client (old client's
   `mode` field is ignored; old client renders the new tagged text raw — ugly
   but functional, acceptable for the dev-only window).

Verification: `deno test` green across `supabase/functions/`.

## Phase 4 — Client plumbing refactor

1. `PromptGenerationSystemPrompt.swift`: replace with v2 (single `composed()`
   no-arg, or a `static let text`). DELETE `PromptModes.swift`.
2. `ManagedProxyClient.swift`: remove `mode` from `generate()`/`encodeBody`.
3. `AppState.swift`: remove `recordingOutputMode`, `effectiveOutputMode`,
   `.confirmingMode`, `resolveModeSwitch`, `debugForceModeSwitchPill`, the
   mode-switch detection step in the processing pipeline, and the
   `outputMode:` param of `beginRecording`. Run `ArtifactParser` on every
   generation result (both Managed and BYOK paths); store a `ParsedResponse`
   for the pill. REMOVE the auto-copy-to-clipboard on completion. Save to
   history via the v2 store shape.
4. DELETE `ModeSwitchDetector.swift`, `ModeSwitchPatterns.swift` + JSON, and
   their tests. Remove `.confirmingMode` from `PillStateBridge.swift` and
   `.confirmSwitch` + `onKeepMode`/`onSwitchMode` from `PillView.swift`.
5. `AreaSelectorState/View`: remove the output-mode switch + hover + hit-test
   + hint copy. `PreferencesStore`: remove `OutputMode` enum*, the pref, key,
   reset entry. Delete `OutputModeSection.swift`; update `SettingsView`.
   (*Move the enum to deletion only after nothing references it — compiler
   drives the sweep.)
6. Temporary rendering shim so the app stays usable before Phase 5: expanded
   pill body shows `chatText`, and if an artifact exists, its body below a
   plain divider; Copy button copies per the §2 semantics table.
7. Update every test that referenced modes (`ZerroTests/`), including
   `ManagedProxyClient` encode tests and AppState flow tests.

Verification: full Xcode test suite green; manual end-to-end recording on the
Managed path AND the BYOK path produces parsed responses; clipboard untouched
until Copy is tapped.

## Phase 5 — New result UI (the claude.design spec)

Reference: the approved design — artifact card with checkmark + dynamic title
header (no type badge), auto-expanded body, Attached Context drawer row,
single bottom-right primary copy button with per-type label, Hide chevron.

1. Restructure the expanded pill (`PillView.swift`, extracting subviews as
   needed — it is already 1,100 lines; new files under `Surfaces/Pill/`):
   - **Chat section:** `chatText` rendered via `HighlightedMarkdownView`.
   - **Artifact card** (only when artifact present): header = green check +
     model title + Hide chevron; body auto-expanded, monospace for `snippet`,
     markdown otherwise; collapsed **Attached Context row** (paperclip,
     summary like "screen text, 4 clicks", `INCLUDED IN COPY` /
     `FOR REFERENCE` tag per type, expandable); bottom-right primary button
     with `ArtifactType.buttonLabel`, existing copied-feedback animation.
   - **Chat-only responses:** no card; pill expands to the chat text alone.
2. Copy action: route through `Pasteboard.copy` with the §2 payload table.
3. States to preserve: compact ↔ expanded morph, close button, sleep-interrupt
   and degraded-result notes currently shown in the expanded body.
4. Update `RecentPromptsView` rows to show artifact-type icon + title; copying
   a history row uses the same per-type payload.
5. UI tests/snapshots where the project has them; otherwise a manual QA list:
   every type renders, long titles truncate, empty context hides the drawer,
   `generic` fallback renders, chat-only renders.

## Phase 6 — Conversion fallback ("Write agent prompt")

1. New edge function `supabase/functions/convert/`: POST, session-token auth
   (same `verifySessionToken`), body `{ source_text (≤ 20k chars), context
   (≤ 6k chars) }`, reuses the rate-limit check keyed per identity, NO credit
   check/consumption (charges 0 by design), calls the default model with a
   small dedicated system prompt: "Rewrite the following explanation+context
   as an instruction prompt addressed to an AI coding agent… output ONLY the
   §2 artifact block with type agent_prompt." Returns `{ prompt }` (raw
   fenced text). Tests mirror `generate`'s handler tests, minus billing.
2. Conversion system prompt added to `zerro-prompt-system.md` v2 + mirrored in
   Swift for BYOK (BYOK calls its provider directly with the same prompt).
3. Client: `ManagedProxyClient.convert(...)` (or a small sibling client);
   AppState keeps the last `ParsedResponse` + its context block for the
   session; a ghost "✎ Write agent prompt" button renders ONLY on responses
   with no artifact; tap → spinner on the button → parse result → artifact
   card slides in under the existing response; failure → unobtrusive retry
   state, never destroys the chat text.
4. Idempotency: reuse the recording's idempotency key + a `:convert` suffix.

## Phase 7 — Eradication sweep, final eval, docs

1. `grep -ri "instruct\|explain\|outputmode\|modeswitch"` across
   `apps/desktop` and `supabase/functions`; audit every hit (known stragglers:
   `DiagnosticsCollector`, `MenuBarPanelView`, `BillingSection`,
   `ClickResolver`, `GeminiPromptGenerationService` comments, `ZerroApp`).
   Delete the `OutputMode` enum itself.
2. Re-run the full Phase 0 eval against the shipped prompt on all enabled
   models; record scores in `zerro-prompt-system.md` changelog.
3. Update `README-eval.md`, `local-model-test.md`, `rerun-explain.sh` (rename
   or delete), and any onboarding copy that mentions modes
   (`Surfaces/Onboarding/`).
4. Manual QA matrix: Managed + BYOK × (agent_prompt / message / snippet /
   document / chat-only / empty narration / conversion button) × at least two
   models. Verify out-of-credits, rate-limit, and idempotent-retry paths still
   behave (they should be untouched).

---

## Risks & guardrails

- **The money path is sacred.** `handler.ts` steps 1–10 and 12–15 must not
  change in any phase. If a change seems to require touching them, stop and
  flag it.
- **Prompt sync discipline:** v2 lives in `zerro-prompt-system.md`; Swift,
  `prompt.ts`, and `eval-models.mjs` are byte-mirrors. Every prompt edit in
  any phase updates all four or none.
- **Fail-safe parsing:** a malformed model response must always degrade to
  plain chat text. No render path may assume an artifact exists.
- **Phase boundaries:** if a phase reveals a needed decision not covered by
  the locked table above, stop and ask Colin rather than assuming.
