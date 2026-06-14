# Handoff: raw `<<<ZERRO_ARTIFACT>>>` fence leaks into chat text on long recordings

## Symptom
After a long (~2 minute) recording, the result pill renders the **raw** artifact wire
format as plain chat text instead of a proper artifact card / code block. The visible
output literally starts with:

```
<<<ZERRO_ARTIFACT type="agent_prompt" title="Update Zerro landing page copy and remove FAQ">>> Update the Zerro landing page copy ...
```

…and there is **no** `<<<END_ZERRO_ARTIFACT>>>` close fence anywhere in the response.
The whole body (numbered steps, etc.) shows as chat text. Short recordings render the
artifact card correctly, so this only reproduces when the generated response is large.

## Most likely root cause (confirm before fixing)
The response is being **truncated by the output token limit** before the model emits the
close fence, so the parser sees one open fence and zero close fences and correctly
degrades to chat-only — but the unterminated open fence is then dumped into the UI.

Evidence:
- `apps/desktop/Zerro/Services/ArtifactParser.swift` only emits an artifact when
  `opens.count == 1 && closes.count == 1` (see the guard around line 139). With an open
  fence and no close fence it falls through to `chatOnly(valid: false)`, whose `chatText`
  is the entire raw output — including the literal `<<<ZERRO_ARTIFACT …>>>` line. That is
  exactly the screenshot.
- `apps/desktop/Zerro/Services/Anthropic/AnthropicPromptGenerationService.swift` sets
  `maxTokens = 8192` and only inspects `stop_reason` for `"refusal"` (line ~109). It does
  **not** detect `stop_reason == "max_tokens"`, so a truncated generation is treated as a
  complete success and handed to the parser as-is.
- `apps/desktop/Zerro/Services/Gemini/GeminiPromptGenerationService.swift` likewise treats
  `finishReason == "MAX_TOKENS"` as a usable finish (line ~114).

Please verify this is what's happening (e.g. log `stop_reason` / `finishReason` and output
token usage for a reproducing long recording) before committing to the fix. If truncation
is **not** the cause, fall back to the secondary hypothesis below.

### Secondary hypothesis
If the response is NOT truncated, then a complete-but-malformed fence is leaking. In that
case treat it as a parser gap: the open fence is present and well-formed but the close
fence shape isn't being recognized. Add the failing real-world response as a new case in
the parser spec (see "Keep in sync" below) and extend the recovery tier rather than
loosening the strict path.

## What to do
1. **Detect truncation at the generation boundary** so a cut-off response never reaches the
   parser as if it were complete. In each generation service
   (`Anthropic`, `Gemini`, and the OpenAI service under
   `apps/desktop/Zerro/Services/OpenAI`, plus the managed path in
   `apps/desktop/Zerro/Services/Managed`), check the provider's stop/finish reason for the
   max-output-tokens case (`stop_reason == "max_tokens"` for Anthropic,
   `finishReason == "MAX_TOKENS"` for Gemini, `finish_reason == "length"` for OpenAI) and
   surface it as a distinct, recoverable failure rather than a silent success.
2. **Decide the product behavior for truncation** and implement it consistently across
   Managed and BYOK (they share the `.done` tail in
   `AppState.acceptGenerationResult`, ~line 1799). Options to weigh — pick the simplest that
   prevents a leaked fence:
   - Raise `maxTokens` (currently 8192) to a headroom value appropriate for long recordings,
     AND still handle the limit case so a future longer response can't regress this.
   - On a detected truncation, present a clear failure/retry state (reuse the existing
     expanded failure-card path — see `lastFailureDetail` / `state = .failed(reason:)` in
     `AppState.swift`) instead of rendering a half artifact.
3. **Harden the parser as defense-in-depth** so an unterminated open fence can never be shown
   verbatim. In `ArtifactParser.parse`, when there is exactly one open fence and zero close
   fences, the `chatText` fallback should **not** include the raw open-fence line. At minimum
   strip/normalize the leaked `<<<ZERRO_ARTIFACT …>>>` token from the chat-only fallback text
   so the user never sees wire syntax, while keeping `isValid == false` for telemetry. This is
   a safety net — it is NOT a substitute for step 1/2.

## Keep in sync (hard constraint)
`ArtifactParser.swift` has a mirrored JS reference and an executable spec. Per the header
comment in that file, any behavior change to the parser **must** change all three together:
- `apps/desktop/Zerro/Services/ArtifactParser.swift`
- the `parseArtifactResponse` reference in `apps/desktop/Scripts/eval-models.mjs`
- the cases in `apps/desktop/Scripts/artifact-eval/parser-tests.json`
- and the §2 plan in `docs/refactor-artifact-response-plan.md`

`ArtifactParserTests.swift` loads the JSON directly, so add a regression case there that
encodes this bug (an open fence with no close fence → chat-only fallback that contains no
raw `<<<ZERRO_ARTIFACT` token).

## Acceptance criteria
- A long recording whose generation hits the output-token limit no longer shows any raw
  `<<<ZERRO_ARTIFACT` / `<<<END_ZERRO_ARTIFACT` token in the pill — it either renders a
  complete artifact card or shows a clear failure/retry state.
- Truncation (`max_tokens` / `MAX_TOKENS` / `length`) is detected in every generation path
  and no longer treated as a clean success.
- New parser regression case added to `parser-tests.json`, mirrored in `eval-models.mjs`,
  and passing in `ArtifactParserTests`.
- All existing `ArtifactParserTests` still pass; `xcodebuild` test suite is green.

## Files to start in
- `apps/desktop/Zerro/Services/ArtifactParser.swift`
- `apps/desktop/Zerro/Services/Anthropic/AnthropicPromptGenerationService.swift`
- `apps/desktop/Zerro/Services/Gemini/GeminiPromptGenerationService.swift`
- `apps/desktop/Zerro/Services/OpenAI/` and `apps/desktop/Zerro/Services/Managed/`
- `apps/desktop/Zerro/AppState.swift` (`acceptGenerationResult`, failure-state plumbing)
- `apps/desktop/Scripts/eval-models.mjs`, `apps/desktop/Scripts/artifact-eval/parser-tests.json`
- `apps/desktop/ZerroTests/ArtifactParserTests.swift`
