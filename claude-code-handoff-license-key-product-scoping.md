# Task: Stop a managed subscription key from showing in the BYOK License section (and vice-versa)

## Bug (report #11)
In **Settings → Account & Billing**, a user on a **Managed** subscription who clicks
**"Switch to BYOK"** sees their *managed* license key already populated — and marked
**"✓ Verified"**, with Deactivate/Re-activate buttons — inside the **"BYOK LICENSE →
License Key"** section. The same key therefore appears in BOTH the Managed pane
(as "Subscription Key") and the BYOK pane (as "License Key"). The BYOK License row
should be **empty** for a managed user, showing only the "Paste your license key"
placeholder.

## Root cause
A Managed subscription key and a one-time BYOK license key are *both* LemonSqueezy
keys activated through the same path and stored in the **same Keychain slot**
(`KeychainStore.byokLicenseKey`). The codebase already disambiguates them with a
separate slot, `KeychainStore.licenseProductKind` ("byok" / "managed", see
`KeychainStore.swift:254` and `LicenseProductKind` in `EntitlementStore.swift:38`).

`BillingLicenseModel` (in `apps/desktop/Zerro/Surfaces/Settings/Sections/BillingSection.swift`)
**never consults `licenseProductKind`**. It is product-agnostic:
- `init()` (line ~112) pre-fills `licenseKey` from `byokLicenseKey` and sets
  `phase = .licensed` whenever *any* key is on file.
- `syncToEntitlement(_:)` (line ~136) sets `.licensed` when the entitlement is
  `.managed` **or** `.byok` (line ~140) and re-fills from the Keychain.
- `LicenseKeyRow.isLicensed` (line ~412) likewise returns true for `.managed` **or**
  `.byok`, so the licensed affordances (Verified pill, Deactivate/Re-activate) render
  in whichever pane is on screen.

The Managed pane (`BillingSection`, line ~36/66) and the BYOK pane
(`BYOKLicenseSection`, line ~690/696) each instantiate their own
`BillingLicenseModel` but feed it the same context-free logic, so the on-file key
leaks into both. (A managed user reaches the BYOK pane via the "Switch to BYOK"
override in `AccountBillingPane.swift:80` — `overrideMode`.)

## Goal
Make each license row **product-scoped**: it pre-fills its key, shows "Verified",
and shows the Deactivate/Re-activate affordances **only when the on-file license
belongs to that row's product**.
- Subscription Key row (Managed pane) → only when the entitlement/`licenseProductKind`
  is **managed**.
- License Key row (BYOK pane) → only when it is **byok**.

A managed user previewing the BYOK pane must see an empty BYOK License field with the
"Paste your license key" placeholder and an **unverified** pill — and vice-versa for a
BYOK user previewing the Managed pane.

All files are in `apps/desktop/Zerro/`.

## Implementation steps

### 1. Give `BillingLicenseModel` an expected product
`BillingSection.swift`, `BillingLicenseModel` (around line 96).

Add a stored `expectedProduct: LicenseProductKind` and require it at init. Read the
on-file product-kind slot so the model can decide whether the stored key is "its"
key:

```swift
@ObservationIgnored private let keychain = KeychainStore.byokLicenseKey
@ObservationIgnored private let productKindSlot = KeychainStore.licenseProductKind
let expectedProduct: LicenseProductKind

init(expectedProduct: LicenseProductKind) {
    self.expectedProduct = expectedProduct
    let onFileKind = LicenseProductKind(rawValue: productKindSlot.read() ?? "")
    let stored = keychain.read() ?? ""
    // Only adopt the stored key if it belongs to THIS row's product.
    if !stored.isEmpty, onFileKind == expectedProduct {
        licenseKey = stored
        phase = .licensed
    } else {
        licenseKey = ""
        phase = .unverified
    }
}
```

> Note: `LicenseProductKind` is declared in `EntitlementStore.swift:38` (same module,
> no import needed). `productKindSlot.read()` returns the raw string; map it through
> `LicenseProductKind(rawValue:)`. Reuse `EntitlementStore`'s pattern if you prefer
> (it has a private `readProductKind(from:)` helper at line ~634 — keep the model's
> own read to avoid widening EntitlementStore's API, unless you'd rather expose a
> `var licenseProductKind: LicenseProductKind?` getter on `EntitlementStore` and read
> that instead; either is fine, pick one and be consistent).

### 2. Make `syncToEntitlement` product-aware
Same model, `syncToEntitlement(_:)` (line ~136). The entitlement state maps 1:1 to a
product, so gate `.licensed` on the state matching `expectedProduct`:

```swift
func syncToEntitlement(_ state: EntitlementState) {
    guard phase != .working else { return }
    let matchesThisRow: Bool = {
        switch expectedProduct {
        case .managed: if case .managed = state { return true }; return false
        case .byok:    return state == .byok
        }
    }()
    if matchesThisRow {
        phase = .licensed
        if trimmedKey.isEmpty, let stored = keychain.read() { licenseKey = stored }
    } else if phase == .licensed {
        // This row's product is no longer the active entitlement — clear it.
        phase = .unverified
        licenseKey = ""
    }
}
```

This replaces the current `.managed || .byok` check at line ~140 so a managed
entitlement no longer marks the BYOK row `.licensed` (and vice-versa).

### 3. Pass the expected product through `LicenseKeyRow` and make `isLicensed` product-aware
`LicenseKeyRow` already carries `Context` (`.subscription` / `.byokLicense`) — use it.

`LicenseKeyRow.isLicensed` (line ~412) currently returns true for `.managed` **or**
`.byok`. Scope it to the row's context:

```swift
private var isLicensed: Bool {
    switch context {
    case .subscription:
        if case .managed = entitlements.state { return true }
        return false
    case .byokLicense:
        return entitlements.state == .byok
    }
}
```

`activateLabel` (line ~417) and the Deactivate button (line ~389) both key off
`isLicensed`, so they become correct automatically.

### 4. Construct each model with its product
- `BillingSection` (line ~36): `@State private var model = BillingLicenseModel(expectedProduct: .managed)`
- `BYOKLicenseSection` (line ~692): `@State private var model = BillingLicenseModel(expectedProduct: .byok)`

The `LicenseKeyRow(model:context:)` call sites (lines ~66 and ~696) stay as-is — the
context already matches the product.

### 5. Activation flow — confirm it still pre-fills correctly
`activate(...)` and `deactivate(...)` (lines ~154 / ~175) need no logic change: a user
who is *previewing* the other mode and pastes a real key for THAT product activates
normally; on success the entitlement flips, `AccountBillingPane.onChange` drops the
override (`AccountBillingPane.swift:68`), and `syncToEntitlement` now keeps only the
matching row licensed. Just verify activation still writes `licenseProductKind`
(it does, via `EntitlementStore` at line ~640) so the next launch's init (step 1)
adopts the key for the right row.

## Verification
- Build the **Zerro** scheme → must compile.
- Update/extend tests:
  - `ZerroTests/BYOKLicenseGateTests.swift` and `EntitlementStoreManagedTests.swift`
    are the closest existing coverage — add a case asserting that, with a **managed**
    key on file (`licenseProductKind == .managed`), a `BillingLicenseModel(expectedProduct: .byok)`
    initializes with an **empty** `licenseKey` and `.unverified` phase; and the
    symmetric case (byok key on file → managed-row model stays empty).
  - If any existing test constructs `BillingLicenseModel()` with no argument, update it
    to pass `expectedProduct:`.
- Canvas-render the previews in `BillingSection.swift` (lines ~762–788) and
  `AccountBillingPane.swift` (lines ~131–159):
  - **Managed** preview → Managed pane shows the Subscription Key as Verified; click
    "Switch to BYOK" → BYOK License field is **empty / unverified**.
  - **BYOK** preview → BYOK License shows Verified; "Switch to Managed" → Subscription
    Key field is **empty / unverified**.
  - The `BYOKLicenseSection` preview is pinned to `.byok`, so it should still show
    Verified (a real BYOK key on that path).

## Constraints / notes
- Don't change where keys are stored — both products legitimately share
  `byokLicenseKey`; `licenseProductKind` is the discriminator. Do not add a second key
  slot.
- Don't touch `EntitlementStore`'s state machine or activation logic. This is purely a
  Settings-row display-scoping fix.
- Keep using existing types (`LicenseProductKind`, `EntitlementState`) and the existing
  `Context` enum — no new public surface beyond the `expectedProduct` init parameter
  (and optionally a read-only `licenseProductKind` getter on `EntitlementStore` if you
  go that route in step 1).
- Empty-field state must use the existing "Paste your license key" placeholder
  (`fieldCapsule`, line ~424) and the `.unverified` pill (`statusPill`, line ~452) —
  no new UI.
