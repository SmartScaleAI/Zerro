# Claude Code handoff prompt — Remove GPT-5.4 mini from the model pickers

Copy everything below the line into Claude Code, running from the repo root.

---

You are removing the **OpenAI "GPT-5.4 mini"** model (wire id `gpt-5.4-mini`,
provider `openai`) from the user-selectable model options in the Zerro app, in
**both** the artifact-generation picker ("artifact mode") and the Dev Mode
coding-agent picker ("dev mode"). Read this entire brief and explore the
referenced files before writing any code.

**Approach: disable, do NOT delete.** Use the codebase's built-in kill switch
(`enabled: false`) — do not strip the entry, its pricing rows, or its cost-table
entries. Disabled entries must stay *resolvable* so historical generations that
used `gpt-5.4-mini` still render their model name and cost. This is exactly the
pattern the `enabled` flag was designed for (see the header comments in
`supabase/functions/generate/models.ts` and `ModelRegistry.swift`).

## Background — the two modes source models differently

**Artifact mode** is fed by a THREE-MIRROR registry (each file's header documents
the keep-in-sync contract). `gpt-5.4-mini` is entry #1 in all three:

1. `supabase/functions/generate/models.ts` (~line 62) — the server source of
   truth. `ALLOWED_MODELS` is derived from `enabled` entries only, so flipping
   `enabled` is the complete request-validation kill switch. `modelById()` still
   resolves disabled entries (for historic logs) — leave that working.
2. `apps/desktop/Zerro/Services/ModelRegistry.swift` (~line 95) — the app-side
   mirror. The picker renders `ModelRegistry.enabled` (see
   `AreaSelectorWindowController.swift` ~line 1320), so disabling drops it from
   the toolbar/menu. `ModelRegistry.entry(id:)` still resolves it.
3. `apps/desktop/Scripts/eval-models.mjs` — the eval harness mirror.

**Dev mode** does NOT use that registry. Its OpenAI models come from the
**Codex agent's own per-account list**, read from `~/.codex/models_cache.json`
and parsed by `DevAgentDetection.parseCodexModelsCache(_:)`
(`apps/desktop/Zerro/Services/Dev/DevAgentDetection.swift` ~line 264), surfaced
as `DevAgentDetection.shared.codexModels` and consumed via
`AgentModelManifestStore.models(forAgent:)`. So `gpt-5.4-mini` appears in dev
mode only when the user's local Codex account lists it. There is no server kill
switch for this — it requires an **app-side exclusion filter**. (The Cursor
agent's list, `cursorModels`, could theoretically surface a `gpt-5.4-mini`
family too; apply the same exclusion there defensively.)

## Change 1 — Artifact mode: server registry (models.ts)

In `supabase/functions/generate/models.ts`, the `gpt-5.4-mini` entry (~line 62):
change `enabled: true` → `enabled: false`. Leave everything else on the line
(id, provider, displayName, fallbackCredits) intact.

- This removes it from `ALLOWED_MODELS` → new requests sending `model:
  "gpt-5.4-mini"` will 400. That's intended.
- `DEFAULT_MODEL_ID` is unaffected (the recommended default is
  `gemini-3.5-flash`, still enabled).
- **The `generate` edge function must be redeployed** for the server gate to
  take effect. Note this in your summary; do not deploy yourself unless asked.

Do **not** touch the pricing in `supabase/functions/generate/cost.ts` (~line 47,
`"openai:gpt-5.4-mini"`) — disabled entries must stay priced for historic-cost
resolution.

## Change 2 — Artifact mode: app mirror (ModelRegistry.swift)

In `apps/desktop/Zerro/Services/ModelRegistry.swift`, the `gpt-5.4-mini`
`ModelEntry` (~line 95): add `enabled: false`. It currently relies on the
`enabled` default of `true`, so make it explicit:

```swift
ModelEntry(id: "gpt-5.4-mini", provider: .openai, displayName: "GPT-5.4 mini", enabled: false),
```

- The picker (`ModelRegistry.enabled`) will stop rendering it.
- `ModelRegistry.entry(id:)` / `ModelRegistry.all` still include it (resolvable).
- **Persisted selection auto-migrates — confirm, no code change expected.**
  `PreferencesStore.swift` (~lines 269–273) already only restores a stored
  `selectedModelID` when `ModelRegistry.entry(id:)?.enabled == true`, else falls
  back to `ModelRegistry.defaultModelID`. So a user who had GPT-5.4 mini selected
  will silently move to the default. Verify this path still holds; do not weaken
  it.
- Do **not** touch the BYOK pricing table in
  `apps/desktop/Zerro/Services/BYOKRouting.swift` (~line 109) — keep it priced.

## Change 3 — Artifact mode: eval harness (eval-models.mjs)

Inspect `apps/desktop/Scripts/eval-models.mjs` and keep it consistent with the
two mirrors above: `gpt-5.4-mini` should no longer be part of the **default
model set the harness enumerates/runs**, but **keep its price row** (~line 116)
so any explicitly-requested historic eval still prices. If the harness has no
`enabled` concept, the minimal change is dropping it from the default
`MODELS`/base list while leaving the pricing map entry. Match how the file is
structured rather than forcing a particular shape.

## Change 4 — Dev mode: exclude it from the agent model lists

Add a single, centralized dev-mode exclusion so `gpt-5.4-mini` never appears in
a Dev Mode agent's model picker, regardless of what the user's Codex/Cursor
account advertises.

Implementation guidance (in
`apps/desktop/Zerro/Services/Dev/DevAgentDetection.swift`):

1. Define one small exclusion set near the model-parsing code, e.g.
   `private static let devModelExclusions: Set<String> = ["gpt-5.4-mini"]`.
2. **Codex:** in `parseCodexModelsCache(_:)` (~line 264), drop any model whose
   `slug` is in `devModelExclusions`. Codex slugs come through as-is (no family
   normalization), so an exact-slug match is correct; also drop obvious
   effort/latency variants if present (e.g. a slug whose base before a trailing
   `-high`/`-medium`/etc. is excluded).
3. **Cursor (defensive):** the Cursor curation path already collapses variants
   via `cursorModelFamilyKey(_:)` (~line 233) — e.g. `gpt-5.4-mini-high →
   gpt-5.4-mini`. After curation, drop any representative whose family key is in
   `devModelExclusions`. (Note the example in that function's own doc comment is
   literally `gpt-5.4-mini-high → gpt-5.4-mini`.)
4. Keep both lists fail-safe: filtering must never empty the list in a way that
   breaks Dev Mode — the existing bundled/`auto` fallbacks should still apply.

This is a deliberate app-side exclusion of a model the user's own account lists;
add a brief comment saying so and pointing back to this removal.

## Constraints

- **Disable, never delete.** No removed entries, no stripped pricing/cost rows.
  Historic generations that used `gpt-5.4-mini` must still resolve name + cost.
- Don't change `DEFAULT_MODEL_ID` / `defaultModelID`, the recommended model, or
  the persisted-selection fallback logic — only flip `enabled` and add the dev
  filter.
- Don't touch unrelated models or the broader picker/recovery UX.

## Verification (required)

1. **Builds:** `xcodebuild` (or the project's build command) for `apps/desktop`
   succeeds with no new warnings in touched files; `deno` type-check/lint for the
   edge function passes.
2. **Swift tests** (`apps/desktop/ZerroTests`) — run them; expect and fix
   fallout from the disable:
   - `ModelRegistryTests.swift` (~line 26) asserts `.all` contains
     `("gpt-5.4-mini", .openai)` — should still pass (we keep it in `.all`).
     Add/extend a test asserting it is **absent from `ModelRegistry.enabled`**.
   - `BYOKRoutingTests.swift` (~lines 38, 46) assert routing picks
     `gpt-5.4-mini` as cheapest — update to the new cheapest **enabled** model if
     routing gates on `enabled`. If routing does NOT consider `enabled`, decide
     and state whether it should, and align the tests.
   - `AgentModelManifestTests.swift` (~lines 130–136) assert the parsed Codex
     list includes `gpt-5.4-mini` and the order `["gpt-5.5", "gpt-5.4-mini"]` —
     update to assert `gpt-5.4-mini` is now **filtered out**.
3. **Server tests** (`supabase/functions/generate`):
   - `models_test.ts` (~lines 8, 23) — update so `ALLOWED_MODELS` no longer
     contains `gpt-5.4-mini` (the fallback-map/registry-resolution assertions for
     the disabled entry should still resolve via `modelById`).
   - `handler_test.ts` (~line 1258) makes a real request with
     `model: "gpt-5.4-mini"` expecting success — it will now 400. Either switch
     it to an enabled model or assert the 400. Keep the metered-cost math test
     (~lines 1265–1267) by pointing it at the resolver, not the request gate.
   - `cost_test.ts` (~lines 55–103) prices `gpt-5.4-mini` — should still pass
     (we keep pricing); leave as-is.
4. **Add a focused dev-mode test:** feed `parseCodexModelsCache` a cache
   containing `gpt-5.4-mini` (+ a variant) and assert it's excluded while other
   models survive.

## Deliverable

Make the changes, update/add the tests, run the build + both test suites, and
summarize: every file changed, the exact `enabled: false` flips, where the
dev-mode exclusion lives and which lists it filters, the test deltas, and the
reminder that the `generate` edge function needs a redeploy for the server gate
to take effect. Optionally note (do not change unless asked): docs that still
mention `gpt-5.4-mini` (`docs/README-backend.md`, `docs/DEPLOY-RUNBOOK.md`,
`docs/CAPACITY-PLANNING.md`, `apps/desktop/Scripts/README-eval.md`) and the
SwiftUI preview mock at `AreaSelectorView.swift` ~line 2279.
