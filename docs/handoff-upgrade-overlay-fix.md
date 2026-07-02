# Fix: Area-selector overlay blocks clicks on the Upgrade paywall (trial model-lock)

## Bug
In the macOS app, a trial user opens the capture **area selector**, taps the locked
model chip → the in-overlay **"Upgrade" popup** appears → they click **Upgrade** →
the **"Zerro — Upgrade" paywall window** opens, but it's completely non-interactive.
Nothing in the paywall can be clicked (the mouse still shows the area-select
crosshair over it). The paywall is effectively dead behind the selector.

## Root cause
The area-selector overlay is a borderless, non-activating `NSPanel` pinned at
`NSWindow.Level.screenSaver`:

- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift:1587`
  → `win.level = .screenSaver`
- `:1588` → `win.ignoresMouseEvents = false`

`.screenSaver` sits **above** `.floating`, `.modalPanel`, and every normal app
window. The paywall is a plain SwiftUI `Window` scene (normal level), opened via
`AppDelegate.openPaywall()`.

When the trial "Upgrade" button is clicked, `openUpgradePaywall()` opens the paywall
but **never lowers the overlay's level or tears the overlay down**:

```swift
// AreaSelectorWindowController.swift:1408
private func openUpgradePaywall() {
    Log.billing.notice("model-lock: opening voluntary-upgrade paywall")
    Analytics.capture("paywall_opened", [ ... ])
    state?.entitlements?.paywallTrigger = .voluntaryUpgrade
    AppDelegate.openPaywall()      // <-- overlay is still at .screenSaver
}
```

So the still-present `.screenSaver` overlay renders on top of and intercepts every
mouse event destined for the paywall. (Called from the click handler at
`AreaSelectorWindowController.swift:605`.)

## Precedent in this same file
This exact "`.screenSaver` overlay swallows a window below it" problem is already
solved twice for other surfaces — both temporarily drop the overlay to `.normal`:

- **Folder picker** (`presentFolderPicker`), `:1428` — sets `window.level = .normal`,
  raises the `NSOpenPanel`, `runModal()`, then restores the level and re-keys the
  overlay (`:1345`–`:1348` region).
- **TCC / Automation system prompt**, `:1231`–`:1252` — saves `window.level`, sets
  `.normal` while the system prompt is up, restores after.

Both are trivial because they're **modal/blocking** (`runModal`). The paywall is a
**non-modal, async SwiftUI `Window`**, so a "restore right after" isn't available —
hence the fix below.

## Recommended fix
**Tear the overlay down when routing to the paywall.** The overlay is rebuilt fresh
on every `present()` (a new `AreaSelectorState` each time — see the dev-menu
"Reset per overlay presentation" note), so dismissing it is safe and clean. The
upgrade flow takes the user out of the capture surface anyway; after upgrading they
re-trigger capture with the record hotkey.

In `openUpgradePaywall()` (`AreaSelectorWindowController.swift:1408`), set the trigger
first (it lives on the long-lived `EntitlementStore`, so it survives teardown), then
`dismiss()` the overlay, then open the paywall:

```swift
private func openUpgradePaywall() {
    Log.billing.notice("model-lock: opening voluntary-upgrade paywall")
    Analytics.capture("paywall_opened", [
        "trigger": EntitlementStore.PaywallTrigger.voluntaryUpgrade.rawValue,
        "placement": "capture_toolbar"
    ])
    // Set the trigger on the shared EntitlementStore BEFORE teardown (dismiss()
    // nils `state`, but the store is long-lived so the trigger persists).
    state?.entitlements?.paywallTrigger = .voluntaryUpgrade
    // Tear down the .screenSaver-level overlay so it stops intercepting mouse
    // events / rendering above the paywall window. Without this, the paywall
    // opens BELOW the overlay and is un-clickable.
    dismiss()
    AppDelegate.openPaywall()
}
```

Note ordering: `dismiss()` sets `state = nil`, so the `paywallTrigger` assignment
must come first. `AppDelegate.openPaywall()` reads the trigger from the shared
`EntitlementStore`, not from `state`, so it still resolves after teardown.

### Alternative (only if the selector must survive the upgrade)
If product wants the in-progress selection preserved so the user lands back in the
selector after closing the paywall, don't `dismiss()`. Instead mirror the modal
precedent: drop the overlay to `.normal` when opening the paywall and restore it to
`.screenSaver` + re-key when the paywall closes. Because the paywall is non-modal,
you must restore on paywall dismissal — e.g. have `PaywallView`/the paywall opener
notify the `AreaSelectorWindowController`, or observe the paywall window's close, then
run `window.level = .screenSaver; window.makeKeyAndOrderFront(nil)`. This is more
moving parts and more failure modes than the dismiss approach; only take it if the
preserved-selection UX is a hard requirement.

## Acceptance criteria
- As a `.trial` user, open the area selector → tap the locked model chip → click
  **Upgrade** → the paywall opens and **every control is clickable** (Subscribe to
  Managed, Get a license, Activate it, the close button), with the normal arrow
  cursor (no crosshair) over it.
- The menu-bar "Upgrade" entry point still works unchanged.
- `.byok` / `.managed` users are unaffected (they never see the lock/upgrade popup).
- No regression to the folder-picker or TCC-prompt level handling in the same file.

## Files
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift`
  (`openUpgradePaywall()` ~`:1408`; overlay level `:1587`; precedents `:1231`, `:1428`)
- `apps/desktop/Zerro/ZerroApp.swift` (`AppDelegate.openPaywall()` `:1217`;
  paywall `Window` scene ~`:530`)
- `apps/desktop/Zerro/Surfaces/Paywall/PaywallView.swift` (paywall content, if the
  alternative close-notify approach is chosen)
