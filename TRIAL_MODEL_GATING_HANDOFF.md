# Implementation Task: Lock premium models behind upgrade for trial users

## Goal

Replicate Cursor's "free model + locked premium models" pattern in our model picker. While a user is on a **trial** plan, the only model they may use is **Gemini 3.5 Flash** (`gemini-3.5-flash`). All other models are "premium" and gated.

For trial users specifically:
1. The toolbar model chip always shows **Gemini 3.5 Flash** as the selected model, and the chip's trailing glyph is a **lock icon** (`lock.fill`) instead of the usual `chevron.down`.
2. Clicking the chip does **not** open the normal model list. Instead it opens an **upgrade popup** explaining that the other models are premium and only available on paid plans, with a single primary button labeled **Upgrade** (white button, dark text).
3. Clicking **Upgrade** opens our existing managed-subscription checkout in the browser.

Non-trial users (byok / managed) keep the existing model picker behavior with the full model list and `chevron.down` — nothing changes for them.

## Reference (how Cursor does it)

Cursor shows the locked model name in the toolbar with a lock glyph where the dropdown chevron would be. Clicking it pops a small card: a title ("Upgrade to unlock premium models"), one line of body copy ("Premium models are only available on paid plans."), and a blue "Upgrade to Pro" button. We want the same structure, styled to match our existing dark menu panels, with the button in **white** per the request.

---

## Codebase context (already located — use these exact references)

### Model picker UI
`apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift`
- The toolbar model chip (sparkles icon + model name + `chevron.down`) lives around lines 301–360.
- The dropdown panel is `modelMenu(in:)` around lines 962–1008.
- Reuse the `menuPanel(frame:_:)` helper (~lines 891–909) and `menuCaret` for the upgrade popup so it visually matches existing menus. Do **not** introduce Radix/shadcn/AppKit popovers — this is native SwiftUI drawn the same way as the existing menus.

### Model registry
`apps/desktop/Zerro/Services/ModelRegistry.swift`
- `ModelRegistry.all` (lines ~77–92) defines the models. The trial-allowed model is `gemini-3.5-flash` (displayName "Gemini 3.5 Flash", `recommended: true`).
- Note: the model list is mirrored in `supabase/functions/generate/models.ts` (server source of truth) and `apps/desktop/Scripts/eval-models.mjs`. **Do not change the model list** for this task — gating is a client UI/entitlement concern, not a registry change.

### Plan / trial detection
`apps/desktop/Zerro/Services/Billing/EntitlementStore.swift` and `EntitlementState.swift`
- `EntitlementState` enum has cases: `.trial(creditsRemaining:)`, `.expired`, `.byok`, `.managed(creditsRemaining:resetDate:)`.
- Read `entitlements?.state`. Treat **only `.trial`** as the gated state for this feature.
- `EntitlementStore` is held by `AppState` (the model picker already has access to app state via `AreaSelectorState` — wire the entitlement state through to `AreaSelectorState` if it isn't already exposed there).

### Upgrade / checkout
`apps/desktop/Zerro/Services/Billing/BillingLinks.swift`
- Use `BillingLinks.subscriptionCheckoutURL()` for the Upgrade button (managed subscription, i.e. the "Pro" plan).
- Open via `NSWorkspace.shared.open(url)`, matching the existing pattern in `BillingSection` / `PaywallView`.
- The URL can be `nil` (placeholder not filled). If `nil`, disable/soften the Upgrade button rather than opening a dead link — follow the existing soft-gating convention.
- Decorate with analytics custom-data params the same way other checkout entry points do (`BillingLinks.checkoutURL(_:product:)` adds PostHog `ph_distinct_id` + a `product` tag). Use a distinct product tag like `subscription_pro_model_lock` so we can attribute upgrades that originate from this popup.

### Icons & styling
- SF Symbols via `Image(systemName:)`. Lock glyph: `lock.fill`. Existing chevron: `chevron.down`.
- Colors in `apps/desktop/Zerro/DesignSystem/Colors.swift`. For the white Upgrade button use `vfBrandAccent` (white) as fill and `vfOnBrand` (near-black) as text. Panel/text tokens: `menuFill`, `vfTextPrimary`, `vfTextSecondary`, `vfHairline`.

---

## Implementation requirements

### 1. Derive a "trial gating" flag
In `AreaSelectorState` (or wherever the picker reads entitlement state), add a computed property, e.g.:
```swift
var isModelPickerLocked: Bool {
    if case .trial = entitlements?.state { return true }
    return false
}
```
Ensure the entitlement state is observable so the chip/popup react to plan changes (e.g. if a trial converts to managed mid-session, the lock disappears without a relaunch).

### 2. Force the selected model to Gemini 3.5 Flash while locked
While `isModelPickerLocked` is true:
- The chip must display **Gemini 3.5 Flash** regardless of any previously persisted `selectedModelID`.
- The effective model used for generation must be `gemini-3.5-flash`. Do **not** silently overwrite the user's persisted preference — compute an *effective* model id (`isModelPickerLocked ? "gemini-3.5-flash" : selectedModelID`) at the point of use, so when they upgrade their old preference (if any) is restored. Verify the generation path reads this effective id, not the raw preference.

### 3. Swap the chip glyph
In the toolbar chip, render `lock.fill` instead of `chevron.down` when `isModelPickerLocked` is true. Keep size/baseline consistent with the existing chevron (~8pt). The lock should read as muted/secondary, matching the current chevron treatment.

### 4. Intercept the chip tap
When `isModelPickerLocked` is true, tapping the chip must open the **upgrade popup** instead of `toggleModelMenu()`. Add state like `isUpgradePopupOpen` to `AreaSelectorState` and a `toggleUpgradePopup()` / `closeUpgradePopup()`. Do not open the normal model list at all while locked.

### 5. Build the upgrade popup
Add an `@ViewBuilder upgradeMenu(in:)` modeled on `modelMenu(in:)`, rendered through `menuPanel(frame:)` + `menuCaret` so it's anchored to the chip the same way the model menu is. Contents, top to bottom:
- **Title:** "Upgrade to unlock premium models" — `vfTextPrimary`, ~13pt semibold.
- **Body:** "Premium models are only available on paid plans." — `vfTextSecondary`, ~12pt.
- **Button:** "Upgrade" — full-width or right-aligned, fill `vfBrandAccent` (white), text `vfOnBrand` (near-black), ~13pt semibold, rounded corners consistent with our pills. On tap: open `BillingLinks.subscriptionCheckoutURL()` (decorated, analytics-tagged) via `NSWorkspace.shared.open`; if `nil`, render the button disabled/softened.

Add a frame helper (sibling to `modelMenuFrame`) sized for this content, and reuse the downward/upward caret logic so it flips above the chip when there's no room below.

### 6. Dismissal
The popup dismisses on outside click / Esc the same way the existing menus do. Opening the upgrade popup should close the model/mic menus and vice-versa (mutual exclusion with existing menu state).

---

## Out of scope / do not do
- Do not modify `ModelRegistry.all`, `supabase/functions/generate/models.ts`, or `eval-models.mjs`.
- Do not change behavior for `.byok` or `.managed` users.
- Do not hardcode a fake plan check — read the real `EntitlementState`.
- Do not add new dependencies or UI frameworks.

## Acceptance criteria
1. On a `.trial` entitlement: chip shows "Gemini 3.5 Flash" + `lock.fill`; clicking opens the upgrade popup (not the model list); generation uses `gemini-3.5-flash`.
2. Upgrade button opens the managed-subscription checkout in the default browser (and is disabled when the checkout URL is `nil`).
3. On `.managed` / `.byok`: model picker is unchanged — full model list, `chevron.down`, free model selection.
4. Converting from trial to paid (state change) flips the chip back to the normal dropdown without a relaunch, and restores the user's prior model preference if one existed.
5. Upgrade taps from this popup are attributable in analytics via a distinct product tag.

## Verification before you finish
- Build the desktop app target and confirm no warnings/errors from the touched files.
- Manually (or via a debug toggle) exercise all three entitlement states and confirm the chip glyph, tap behavior, and effective model id in each.
- Confirm the popup matches the visual treatment of the existing model menu (panel fill, hairline, shadow, caret).
- Grep the generation path to confirm it consumes the *effective* model id, not the raw persisted preference.
