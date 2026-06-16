# Task: Add a menu-bar "Upgrade" entry point that opens the (now context-aware) purchase window, and consolidate the scattered upgrade/top-up prompts into it

## Summary
There is no single, always-available way for a user to open the purchase flow
from the menu bar. Today the purchase surfaces are scattered and mostly
reactive: the `PaywallView` only opens when the user is **blocked** (`.expired`),
the Settings → Account & Billing pane buries the same buttons, and the menu-bar
panel shows ad-hoc conditional rows (`trialUpgradeRow`, `topupPackRow`, a Managed
past-due nudge) that only appear in specific states.

We want **one explicit, always-present menu-bar item** ("Upgrade" / context-aware
label) that opens the **existing** purchase window, and we want to **fold the
scattered conditional rows into that single entry**. The purchase window's
headline copy must become **dynamic** based on *why* the user opened it and *what
plan state they're in*, instead of always saying "You've used your free
generations."

This is an entry-point + consolidation + copy task. **The billing plumbing,
checkout links, license activation, and entitlement model already exist** — do
not rebuild them.

---

## Decisions (already made — build to these)

1. **Reuse the existing paywall window. Do NOT build a new window.** The menu-bar
   item opens `PaywallScene` (the `Window("Zerro — Unlock", id: PaywallScene.windowID)`
   in `ZerroApp.swift` ~350) via the existing `AppDelegate.openPaywall()`
   (`ZerroApp.swift` ~671). The window already shows Managed + BYOK side by side
   plus a license-activation field — that's exactly the surface we want.

2. **Make the paywall headline + subheadline dynamic** based on (a) *entry
   context* and (b) *entitlement state*. Drive it off the **already-existing**
   `EntitlementStore.paywallTrigger` (the paywall reads it today in `.onAppear`
   for analytics — `Surfaces/Paywall/PaywallView.swift` ~64–68) plus
   `EntitlementStore.state`. The current hard-coded title
   (`PaywallView.swift` ~78, "You've used your free generations") becomes one
   branch of a computed copy matrix (see Step 1).

3. **Add ONE menu-bar "Upgrade" item and consolidate** the existing conditional
   rows (`trialUpgradeRow`, `topupPackRow`, and the Managed past-due nudge) into
   it. The single item replaces the scattered prompts; its label and the trigger
   it sets vary by state (see Step 3). Keep `trialStatusLine()` (the "N free
   generations left" status text) — that's informational, not a duplicate CTA.

4. **Return-from-checkout: do BOTH** — register a `zerro://` URL scheme AND
   refresh entitlement when the app regains focus. The deep link's job is to
   **bring the user back into the app with the activation field focused**; the
   focus-refresh **silently updates already-activated users** (see Steps 4–5).

5. **Activation reality (important — don't fight it):** a **first-time** plan
   buyer (Managed *or* BYOK) **must paste the license key** Lemon Squeezy gives
   them. There is no account/login, and the backend stores only a **SHA-256 hash**
   of the key, never the raw key (`supabase/migrations/20260601120000_billing_schema.sql`
   §14.3), so the app cannot retrieve a new buyer's key from the backend. The
   license key IS the identity — it's exchanged at `/session` for a token that
   reads `/entitlement` (`Services/Managed/SessionTokenManager.swift`). Therefore:
   - New plan purchase → deep link returns the user with the **activation field
     focused**; they paste the key; `EntitlementStore.activate(licenseKey:)` runs.
   - Top-up credit pack by an **already-activated Managed** user → the key is
     already in the Keychain and top-ups attach by `ls_customer_id`, so a
     `refreshManagedEntitlement()` on return updates credits **silently, no paste**.

6. **Credit packs are Managed-only.** `EntitlementState.byok` carries no credit
   balance, so the top-up packs (Boost/Power) must be **hidden for BYOK users**.

---

## How the current flow works (verified anchors)

All desktop paths are under `apps/desktop/Zerro/`.

### Entitlement model
- `Services/Billing/EntitlementState.swift` — the state enum:
  `case trial(creditsRemaining: Int?)`, `case expired`, `case byok`,
  `case managed(tier: ManagedTier, creditsRemaining: Int, resetDate: Date)`.
- `Services/Billing/EntitlementStore.swift` (≈878 lines) — authoritative store
  (`@Observable`). Key members:
  - `state: EntitlementState`, `canGenerate: Bool` (~262; `false` only for `.expired`).
  - `paywallTrigger` — **already exists**; read+cleared in the paywall's `.onAppear`
    (`PaywallView.swift` ~64–68). This is the hook for dynamic copy.
  - `refresh()` (~289) — recompute from Keychain + persisted snapshot.
  - `refreshManagedEntitlement()` async (~572) — live fetch via SessionTokenManager.
  - `activate(licenseKey:expectedProduct:)` async (~334) — activates BYOK **or**
    Managed; on success sets `state` and the paywall dismisses.
  - `managedSnapshot` / `managedSnapshotKey` — persisted Managed snapshot.

### Purchase window
- `Surfaces/Paywall/PaywallView.swift` — `struct PaywallView` (~46),
  `@Environment(EntitlementStore.self) private var entitlements` (~48), window
  width 760 (~54). Title at ~78. `optionStack` (~97) renders:
  - `SubscriptionOptionCard(tier: .pro, title: "Managed", …)` — Managed plan card.
  - `BuyOnceCard()` — BYOK ($69 one-time).
  - `ActivateLicenseCard(onActivated: { dismissWindow(id: PaywallScene.windowID) })`
    (~129) — shared license-key field; `@FocusState private var fieldFocused`
    (~349), `activationField` (~370). **This `@FocusState` is what the deep link
    should set to bring the user straight to pasting.**
- `ZerroApp.swift` — `Window("Zerro — Unlock", id: PaywallScene.windowID)` (~350);
  `AppDelegate.openPaywall()` (~671) routes through the `requestOpenPaywall`
  registrar; `paywall_shown` analytics already fire on appear.

### Checkout links (all already wired)
- `Services/Billing/BillingLinks.swift`:
  - `enum CheckoutProduct: String` (~29): `subscriptionPro`, `byok`, `topupBoost`,
    `topupPower`.
  - `checkoutURL(_ base: URL, product: CheckoutProduct)` (~44) appends
    `checkout[custom][ph_distinct_id]` and `checkout[custom][product]`.
  - `subscriptionCheckoutURL(tier:)` (~146), plus `byokCheckoutURLString`,
    `boostTopupCheckoutURLString` (200 credits), `powerTopupCheckoutURLString`
    (500 credits). DEBUG vs Release switch already handled.
  - Pricing facts already in copy: Managed = $12/mo billed yearly, 300 credits/mo
    across 6 models; BYOK = $69 one-time.
- Opening a checkout is always `NSWorkspace.shared.open(BillingLinks.checkoutURL(…))`
  preceded by `Analytics.capture("checkout_opened", ["product": …])`
  (`Surfaces/Settings/Sections/BillingSection.swift`, also the paywall cards).

### Menu-bar panel
- `Surfaces/MenuBarPanel/MenuBarPanelView.swift` — SwiftUI `MenuBarExtra(.window)`
  panel (not an `NSMenu`). Contains `trialUpgradeRow`, `topupPackRow`,
  `trialStatusLine()`, a Managed past-due nudge, and a Settings row that opens via
  `openWindow(id: SettingsScene.windowID)` (~265; `Cmd+,` at ~263).

### Activation identity (why paste is unavoidable for new buyers)
- `Services/Managed/SessionTokenManager.swift` — the raw license key (Keychain
  slot `KeychainStore.byokLicenseKey`, shared by Managed + BYOK) rides ONLY to
  `/session` to mint a Bearer token; `/entitlement` and `/generate` see only the
  token. No account, no login.
- `supabase/functions/lemonsqueezy-webhook/handler.ts` — `ph_distinct_id` is
  plumbed for **analytics only**; license keys are stored **hashed**
  (`pending_license_keys.license_key_hash`, `subscriptions.license_key_hash`).
  The backend never holds the raw key, so it cannot hand it back to the app.

### No URL scheme yet
- `grep` for `CFBundleURLSchemes` / `onOpenURL` / `application(_:open:)` /
  `zerro://` returns nothing. The deep-link return is net-new (Step 4).

---

## Implementation plan

### Step 1 — Dynamic paywall copy
Replace the hard-coded title/subtitle (`PaywallView.swift` ~74–88) with a computed
copy struct derived from `entitlements.paywallTrigger` + `entitlements.state`.
Extend the `paywallTrigger` enum with the new entry contexts if they're not
already present (it currently distinguishes the blocked/preflight case from
`manual`). Suggested copy matrix (wording is a starting point — keep it tight):

| Context (trigger + state)                                   | Headline                              | Subheadline emphasis                         |
|-------------------------------------------------------------|---------------------------------------|----------------------------------------------|
| Blocked — `.expired` (trial credits gone)                   | "You've used your free generations"   | (current copy — keep)                        |
| Voluntary upgrade — `.trial` with credits left              | "Upgrade your plan"                   | Lead with Managed value; trial still works   |
| Low balance / top-up — `.managed` low credits               | "Add more credits"                    | Show top-up packs prominently                |
| Manage — `.byok` or `.managed` healthy                      | "Manage your plan"                    | De-emphasize sell; show activation/manage    |

Keep the existing `paywall_shown` analytics; the `trigger` value now carries the
real context. Do not change `ActivateLicenseCard`'s success behavior.

### Step 2 — Set the trigger before opening
Wherever the paywall is opened, set `entitlements.paywallTrigger` to the right
context **before** calling `AppDelegate.openPaywall()`. Add a thin helper, e.g.
`AppDelegate.openPaywall(trigger:)` or set the property then call the existing
`openPaywall()`. The `.onAppear` already reads-then-clears it, so no lifecycle
changes are needed.

### Step 3 — Single menu-bar "Upgrade" item + consolidation
In `MenuBarPanelView.swift`:
- Add one always-present row above Settings. Label + trigger by state:
  - `.trial` → **"Upgrade"** → trigger `voluntaryUpgrade`.
  - `.expired` → **"Upgrade"** → trigger `blocked` (same as today's gate).
  - `.managed` (low credits) → **"Add Credits"** → trigger `topup`.
  - `.managed` (healthy) / `.byok` → **"Manage Plan"** → trigger `manage`.
- Remove `trialUpgradeRow`, `topupPackRow`, and the Managed past-due nudge as
  separate CTAs; their intent now lives in this one row + the dynamic paywall.
  (Keep `trialStatusLine()` informational text.) If the past-due nudge carries a
  distinct *warning* affordance, fold its message into the row's secondary text
  rather than dropping it.
- Each row click sets the trigger (Step 2) then calls `openPaywall()`.

### Step 4 — Register `zerro://` and handle the return deep link
- Add `CFBundleURLTypes` / `CFBundleURLSchemes` = `zerro` to the app's
  `Info.plist`.
- Handle `.onOpenURL` (SwiftUI `App` scene) or `application(_:open:)` in
  `AppDelegate`. On `zerro://checkout-complete?product=<product>`:
  1. `entitlements.refresh()`; for Managed also `await entitlements.refreshManagedEntitlement()`.
  2. If now entitled → bring the relevant window forward / dismiss the paywall.
  3. If **not** yet entitled (new buyer who must paste) → open the paywall via
     `openPaywall(trigger: .manage)` **and focus the activation field** (set the
     `ActivateLicenseCard.fieldFocused` `@FocusState`; thread a "focus activation"
     flag from the deep link into `PaywallView`).
- Set each Lemon Squeezy product's **"Redirect URL after purchase"** to
  `zerro://checkout-complete?product=<product>` so checkout bounces back. (This is
  a Lemon Squeezy dashboard setting per product — note it in the PR description for
  the human to configure; it is not code.)

### Step 5 — Refresh entitlement on app activation (fallback path)
An activation observer was added recently (commit: "add activation observer to
re-arm keyboard when Zerro becomes active") — **locate it and piggyback** a
lightweight, throttled entitlement refresh on the same app-becomes-active signal
(don't hammer `/session`): call `entitlements.refresh()` and, when the user
already has a key (`licenseService.currentLicenseState().presence == .present`),
`refreshManagedEntitlement()`. If that observer isn't easily reused, add a small
`NSApplication.didBecomeActiveNotification` observer instead. This covers users
who return without the deep link firing, and silently updates an already-activated
Managed user after a top-up.

### Step 6 — Analytics source param
When opening checkout from the new menu-bar entry, include a placement tag so the
funnel can distinguish entry points, e.g.
`Analytics.capture("checkout_opened", ["product": …, "placement": "menubar_upgrade"])`
and `"placement": "paywall"` / `"settings"` at the other two sites. Cheap; do it
now so the Tier-3 monetization funnel reads cleanly.

### Step 7 — Add top-up packs to the paywall (Managed/top-up context only)
**Note:** top-up packs are **not** in `PaywallView` today — they currently live
only as `MenuBarPanelView.topupPackRow` (~641, "Boost · 200 credits · $10" and
"Power · 500 credits · $22" chips) and in Settings. Because we're consolidating
`topupPackRow` away (Step 3), the paywall must now be able to surface them, or a
Managed user choosing "Add Credits" would land on a window with no way to buy
credits.

So: add a top-up section to `PaywallView.optionStack` that renders the two chips
(reuse `BillingLinks.boostTopupCheckoutURL` / `powerTopupCheckoutURL` with
products `.topupBoost` / `.topupPower` — same call the menu used), shown **only**
when `entitlements.state` is `.managed` (and lead with it for the `topup`
trigger). **Hide it for `.byok`** (BYOK funds generation with the user's own API
keys; there are no Zerro credits to top up) and for `.expired`/`.trial`, where the
path is a plan purchase, not a top-up. The simplest move is to lift the existing
`topupChip` view (~658) into a shared place both the paywall and any remaining
caller can use, rather than duplicating it.

---

## Edge cases to handle
- **Trigger never set / stale:** if `paywallTrigger` is nil, fall back to the
  `manual`/blocked copy by state so the window never shows wrong context. The
  existing read-then-clear keeps a later open from inheriting a stale trigger.
- **BYOK user taps an "Upgrade" surface:** there is nothing to upgrade *to* and no
  credits to buy — route them to the **"Manage Plan"** copy (deactivate / switch),
  not a sell page. Don't show top-ups.
- **Managed-Pro user (already top tier):** Starter/Pro are the only tiers and
  Starter isn't sold at launch (`BillingLinks` ~148). "Upgrade" for a healthy Pro
  user means **credits**, so show "Add Credits", not a plan ladder.
- **Deep link fires but user isn't entitled yet** (closed the LS tab before the
  webhook landed, or hasn't pasted the key): open paywall with activation focused;
  do NOT claim success. The focus-refresh (Step 5) will also catch it later.
- **Double-open:** opening the paywall when it's already open should focus the
  existing window, not stack a second one (the `requestOpenPaywall` registrar /
  `openWindow(id:)` already dedupes by window id — confirm).
- **Offline on return:** `refresh()` must fail-open and not flip an entitled user
  to `.expired` on a transient network error (the store already fail-opens for
  BYOK — preserve that).
- **Consolidation regressions:** removing `trialUpgradeRow` / `topupPackRow` must
  not break their previews or any tests that assert on them.

## Verification
- Build the `Zerro` scheme (Xcode or `xcodebuild`) → must compile.
- Unit tests (`ZerroTests`): add/adjust coverage for the copy matrix (trigger +
  state → expected headline) and the menu-row label/trigger selection by state.
  Run the existing billing/credit suites green: `CreditDisplayTests`,
  `EntitlementStoreManagedTests`, `BYOKLicenseGateTests`, `BillingHardeningTests`,
  `PendingPaidGenerationTests`. (Note: `BYOKRoutingTests.testAnthropicBodyMatchesServerAdapterShape`
  is a **pre-existing** failure on a clean tree — not a regression from this work.)
- Canvas-render the paywall in each of the four contexts (Step 1) and confirm the
  headline changes.
- Manual smoke test:
  1. Trial user with credits → menu shows **"Upgrade"** → opens paywall titled
     "Upgrade your plan".
  2. Use the DEBUG entitlement picker to force `.expired` → menu still shows
     "Upgrade" → paywall titled "You've used your free generations".
  3. Force `.managed` low credits → menu shows **"Add Credits"** → paywall leads
     with top-up packs; BYOK forced → packs hidden, row reads **"Manage Plan"**.
  4. Click a plan → browser checkout → on return, `zerro://checkout-complete`
     reopens the app with the **activation field focused**; paste a (dev) key →
     `activate()` entitles and the window dismisses.
  5. As an already-activated Managed user, buy a top-up → returning to the app
     **silently** bumps the credit balance (no paste), via Step 5.

## Out of scope
- **No user accounts / login and no raw-key storage.** Silent auto-entitlement of
  a brand-new buyer would require one of those; we are deliberately keeping the
  hash-only, key-as-identity model. New buyers paste their key.
- No change to the checkout links, the Lemon Squeezy webhook, the billing schema,
  or the `/session` `/entitlement` contract.
- No change to `EntitlementState` semantics or `canGenerate` gating.
- No new pricing tiers (Starter stays unsold at launch).
- The paid-block *pill* resume flow (`claude-code-handoff-resume-after-purchase.md`
  + `claude-code-handoff-paidblock-pill-restyle.md`) is unchanged — this task only
  adds an entry point and makes the window's copy contextual.
