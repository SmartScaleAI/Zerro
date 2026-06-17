# Task: Auto-activate a license from the checkout-return deep link, and confirm the purchase in-app

## Summary
Today the `zerro://checkout-complete` deep link only refreshes entitlement and,
for a brand-new buyer, opens the paywall with the activation field focused so the
user can **paste** their license key. We want to remove the paste: when the deep
link carries a `license_key` (LemonSqueezy's `[license_key]` link variable), the
app should **activate it automatically** and then show a **success confirmation**
with the user's new plan and credit balance. Manual paste and the silent top-up
refresh both remain as fallbacks for anyone who doesn't click "Return to Zerro."

The web side is already done — `apps/web/app/checkout-complete/page.tsx` forwards
every query param (including `license_key`) from the LemonSqueezy `https://`
button into the `zerro://checkout-complete` deep link. **This task is app-side
(Swift) plus a LemonSqueezy dashboard config.**

---

## Decisions (build to these)
1. **The key rides in on the deep link.** LemonSqueezy puts the real key in the
   confirmation button URL via `[license_key]`; the getzerro.app bounce page
   forwards it into `zerro://checkout-complete?...&license_key=<key>`. No backend
   lookup, no account — the key is the identity, same as today.
2. **Only the two activation products carry a key.** Managed subscription and
   BYOK get `&license_key=[license_key]`. **Top-up packs do NOT** — they attach to
   the existing subscription server-side, so their deep link stays
   `?product=topup_*` and just triggers the existing silent refresh.
3. **Auto-activation is best-effort and user-initiated** (they click "Return to
   Zerro"). Never claim success unless `activate()` actually succeeds. Anyone who
   closes the tab falls back to manual paste (the key is also in their receipt
   email) + the `didBecomeActive` refresh.
4. **Treat all deep-link params as untrusted external input.** Anyone can invoke
   `zerro://...`. The only trust boundary is `activate()`'s server-side validation
   against LemonSqueezy — a bogus key simply fails and routes to the fallback.
5. **Reuse the existing paywall window for the success confirmation** (a new
   success state), not a brand-new window. And route the **manual** paste success
   (the existing `ActivateLicenseCard`) through the same confirmation so every
   activation ends on the same clear note.

---

## How it works today (verified anchors)
All desktop paths under `apps/desktop/Zerro/`.

- **Deep-link entry:** `AppDelegate.application(_:open:)` (`ZerroApp.swift` ~692)
  loops `zerro://` URLs into `handleCheckoutReturn(_:)` (~703).
- **Current `handleCheckoutReturn`** (~703–732): guards `host == "checkout-complete"`,
  then **`guard let entitlements else { return }`** — i.e. it **drops the URL if
  the store isn't wired yet** (the cold-launch gap, Step 6). On success it
  `refresh()` + `await refreshManagedEntitlement()`, then: if `isPaidEntitled`
  → `NSApp.activate` + `requestDismissPaywall?()`; else set
  `paywallTrigger = .manage`, `focusActivationFieldOnOpen = true`, `openPaywall()`.
- **Activation:** `EntitlementStore.activate(licenseKey:expectedProduct:) async
  throws -> ActivationResult` (~334). **Inspect `ActivationResult`** — use its
  success / already-active signal for Steps 3–4. `LicenseProductKind` (~38) has
  `.byok` and `.managed`.
- **Entitlement reads:** `isPaidEntitled` (~567), `state: EntitlementState`
  (`.trial` / `.expired` / `.byok` / `.managed(tier, credits, resetDate)`).
- **Paywall plumbing:** `PaywallView` reads `paywallTrigger` + `focusActivationFieldOnOpen`
  (consumed by `ActivateLicenseCard`'s `@FocusState`). `ActivateLicenseCard(onActivated:
  { dismissWindow(id: PaywallScene.windowID) })` — the **manual** success path
  that currently just dismisses. Registrars: `requestOpenPaywall` / `requestDismissPaywall`
  (`ZerroApp.swift` ~604/619, mounted ~737/849), `AppDelegate.openPaywall()` (~776).
- **Web bounce page (done):** `apps/web/app/checkout-complete/page.tsx` forwards
  the full query string into the deep link.
- **Analytics:** existing pattern `Analytics.capture("checkout_opened", [...])`.

---

## Implementation plan

### Step 1 — Parse `license_key` + `product` from the deep link
In `handleCheckoutReturn`, build `URLComponents` and read query items:
`license_key` (optional) and `product` (optional). Map `product` →
`LicenseProductKind?`: `subscription_pro` → `.managed`, `byok` → `.byok`,
`topup_*`/missing → `nil`. Treat both as untrusted strings (length/charset sanity
check on the key before use; no force-unwraps).

### Step 2 — Auto-activate when a key is present
If `license_key` is present **and** the user isn't already entitled with it:
- `let result = try await entitlements.activate(licenseKey: key, expectedProduct: kind)`.
- **Success** → Step 4 (success confirmation).
- **Failure** (throws) → Step 5 (graceful fallback).

If `license_key` is **absent** (top-up or an older link): keep the existing path
— `refresh()` + `refreshManagedEntitlement()`, then silent-if-`isPaidEntitled`
(optionally Step 7's confirmation) / else paywall focused.

### Step 3 — Idempotency / already-active
A user can click "Return to Zerro" twice, or re-open the email link. Activating an
already-active key/device **must not surface an error**. Detect the already-active
case (via `ActivationResult`, or a pre-check on `isPaidEntitled` with the same key
on file) and route to the success confirmation (Step 4) — or a silent refresh —
instead of an error. Mirror the idempotency stance from the resume-after-purchase
work (reuse, don't double-charge / don't re-error).

### Step 4 — Success confirmation (shared by deep-link AND manual paste)
Add a **success state** to the paywall surface. Suggested: a
`purchaseSuccess: PurchaseSuccessInfo?` flag on `EntitlementStore` (`@Observable`)
carrying what to show; `PaywallView` observes it and renders the confirmation
**instead of** the sell/copy matrix when set. Copy by plan (read from
`entitlements.state` right after activation, so it's accurate):
- `.managed` → "You're all set — Managed is active. **N credits** available, resets <date>."
- `.byok` → "You're all set — bring-your-own-key is active."
- top-up (Step 7) → "Added **N credits** — **M** total."

Primary button "Start using Zerro" clears `purchaseSuccess` and dismisses the
window. Set the flag, then `openPaywall()` (it brings the existing window forward).
**Also route the manual path through this**: change `ActivateLicenseCard`'s
`onActivated` so a successful paste sets `purchaseSuccess` (and shows the
confirmation) rather than bare-dismissing — one consistent success moment.

### Step 5 — Graceful failure fallback
On activation failure, open the paywall (`paywallTrigger = .manage`,
`focusActivationFieldOnOpen = true`) **and prefill the attempted key** into the
field so the user sees it and can retry/correct — add a `prefillLicenseKey: String?`
on `EntitlementStore` that `ActivateLicenseCard` reads on appear. Map the
`LicenseError` cases to clear messages: invalid key, **activation limit reached**
(the LS license has a device cap — saw "0/5"), expired/revoked, and offline
("couldn't reach the server — try again"). Never crash; never blank-fail.

### Step 6 — Cold-launch buffering (fix the existing gap)
Clicking "Return to Zerro" when Zerro isn't running launches the app, and
`application(_:open:)` can fire **before** the one-shot block sets
`AppDelegate.entitlements` — today that URL is silently dropped. Fix:
- When `handleCheckoutReturn` finds `entitlements == nil`, **stash the URL** in a
  `static var pendingCheckoutURL: URL?` instead of returning.
- In `ZerroApp.init`'s one-shot wiring block, right after `AppDelegate.entitlements
  = ent`, **replay** any `pendingCheckoutURL` (then clear it).
Confirm both running and cold-launch opens work.

### Step 7 — Confirm top-ups too (recommended)
For a top-up deep link (no key, already entitled), show the lightweight success
confirmation ("Added N credits — M total") instead of a fully silent return, so
every purchase ends on a clear note. Derive N/M from the credit delta after
`refreshManagedEntitlement()`. Keep it driven off the `product=topup_*` param.

### Step 8 — Analytics
Capture `purchase_activated` with `{ product, method: "deeplink" | "manual_paste",
outcome: "success" | "already_active" | "failed" }`, and `purchase_success_shown`
when the confirmation renders. Reuse the existing `Analytics.capture` pattern.

---

## LemonSqueezy config (manual — not code, do after the app build ships)
Set each product's **Confirmation modal → Button link** (the field forces an
`https://` prefix; type the rest):
- **Managed** → `getzerro.app/checkout-complete?product=subscription_pro&license_key=[license_key]`
- **BYOK** → `getzerro.app/checkout-complete?product=byok&license_key=[license_key]`
- **Boost** → `getzerro.app/checkout-complete?product=topup_boost`  *(no key)*
- **Power** → `getzerro.app/checkout-complete?product=topup_power`  *(no key)*

Requirements:
- **Licensing must be enabled** on the Managed and BYOK products so `[license_key]`
  actually populates (BYOK already issues one; confirm the subscription does too —
  the test order showed a generated license, so it does).
- Set this on **both test-mode and live** products.
- Keep the "Return to Zerro" button text.

---

## Edge cases to handle
- **Garbage/forged `license_key`** (anyone can call `zerro://`) → `activate()`
  fails server-side → Step 5 fallback. No crash, no false success.
- **Activation limit reached** (device cap) → specific, friendly message.
- **Offline at click time** → can't activate → message + leave paywall open;
  recovery via the `didBecomeActive` refresh or a manual retry.
- **Double-click / re-opened link** → idempotent success (Step 3), never an error.
- **Cold launch vs already-running** → both must activate (Step 6).
- **Product/key mismatch** (e.g. `product=subscription_pro` but a BYOK key) →
  `activate(expectedProduct:)` should reject; surface a clear message + fallback.
- **Tab closed, never clicked** → no deep link; unchanged manual paste + silent
  `didBecomeActive` refresh still entitle the user.
- **`license_key` with odd characters** → URL-decode via `URLComponents`; don't
  hand-parse the query string.

## Verification
- Build the `Zerro` scheme → compiles. Run billing suites green
  (`EntitlementStoreManagedTests`, `BYOKLicenseGateTests`, `BillingHardeningTests`,
  `PaywallCopyTests`, `MenuBarBillingActionTests`).
- New unit tests:
  - Deep-link parsing: extracts `license_key` + `product`; maps product → kind.
  - Success → `purchaseSuccess` set + confirmation copy matches plan/credits.
  - Failure → paywall opens focused with the key prefilled + mapped error.
  - Already-active key → success/silent, no error.
  - No-key (top-up) path unchanged (+ Step 7 confirmation if built).
  - Cold-launch buffer: a URL arriving before wiring is replayed once wired.
- Manual smoke test (test mode):
  1. Buy Managed → click "Return to Zerro" → app **auto-activates**, success
     screen shows "Managed active — N credits."
  2. Click the link again → still success, no error.
  3. Force an invalid key in the URL → paywall opens with the key **prefilled**
     and a clear error.
  4. Buy a Boost top-up → credits bump (+ optional confirmation), no paste.
  5. Quit Zerro, click a fresh return link cold → app launches **and** activates.
  6. Manually paste a key in the paywall → same success confirmation appears.

## Out of scope
- No accounts/login; the hash-only, key-as-identity model is unchanged.
- No change to the LemonSqueezy webhook, billing schema, or `/session` `/entitlement`
  proxy contract.
- Web bounce page is already built — no further web changes.
- No change to `EntitlementState` semantics or `canGenerate` gating.
