# Claude Code handoff — expand top-up packs (2 → 7)

> Paste everything below the line into Claude Code from the repo root. It is
> self-contained. Do NOT invent real LemonSqueezy IDs — use the placeholder
> tokens described so unfilled cards/variants softly no-op (existing convention).

---

## Task

Replace the two hard-coded top-up packs (Boost, Power) with a **seven-pack
registry** and reprice Power's display label $22 → $20. The credit-granting,
12-month expiry, Managed-only gating, idempotency, and `$0.01/credit` metering
are all UNCHANGED — only the set of packs and how they're declared changes.

### Final packs (order matters — render top to bottom in this order)

| key | name | price label | credits | badge |
|------|------|------|--------:|-------|
| mini | Mini | $5 | 50 | — |
| boost | Boost | $10 | 200 | — |
| power | Power | $20 | 500 | mostPopular |
| pro | Pro | $40 | 1,000 | — |
| studio | Studio | $90 | 2,500 | bestValue |
| max | Max | $170 | 5,000 | — |
| mega | Mega | $300 | 10,000 | — |

`boost` and `power` reuse their EXISTING env names and existing checkout buy-ids
(don't change those). Only Power's **display price** string changes to `$20`.

## Conventions to follow (already in the codebase)
- **Placeholder buy-ids:** for the 5 new packs, use `test: "TODO-<key>-test"`,
  `live: "TODO-<key>-live"`. `BillingLinks.resolvedURL` already rejects any URL
  containing `TODO-`, so those cards render with a disabled CTA until real ids
  are filled in — do not hard-code fake UUIDs.
- **New env vars default to `""`** so they resolve to "no match" until secrets
  are set. Reuse `optionalEnv` / `optionalEnvInt`.
- Keep the existing DEBUG(test)/Release(live) checkout switch and the
  `.managed`-only gating exactly as they are.

---

## 1. Backend — `supabase/functions/_shared/config.ts`

Replace the four `*_BOOST`/`*_POWER` top-up constants with one ordered registry
(keep `TOPUP_EXPIRY_MONTHS`). Keep the Boost/Power env names:

```ts
export interface TopupPackDef { key: string; credits: number; variantIds: string; }

export const TOPUP_PACKS: TopupPackDef[] = [
  { key: "mini",   credits: optionalEnvInt("TOPUP_MINI_CREDITS",   50),    variantIds: optionalEnv("LS_VARIANT_TOPUP_MINI",   "") },
  { key: "boost",  credits: optionalEnvInt("TOPUP_BOOST_CREDITS",  200),   variantIds: optionalEnv("LS_VARIANT_TOPUP_BOOST",  "") },
  { key: "power",  credits: optionalEnvInt("TOPUP_POWER_CREDITS",  500),   variantIds: optionalEnv("LS_VARIANT_TOPUP_POWER",  "") },
  { key: "pro",    credits: optionalEnvInt("TOPUP_PRO_CREDITS",    1000),  variantIds: optionalEnv("LS_VARIANT_TOPUP_PRO",    "") },
  { key: "studio", credits: optionalEnvInt("TOPUP_STUDIO_CREDITS", 2500),  variantIds: optionalEnv("LS_VARIANT_TOPUP_STUDIO", "") },
  { key: "max",    credits: optionalEnvInt("TOPUP_MAX_CREDITS",    5000),  variantIds: optionalEnv("LS_VARIANT_TOPUP_MAX",    "") },
  { key: "mega",   credits: optionalEnvInt("TOPUP_MEGA_CREDITS",   10000), variantIds: optionalEnv("LS_VARIANT_TOPUP_MEGA",   "") },
];
```

Update the comment block above to document the new env vars.

## 2. Backend — `supabase/functions/lemonsqueezy-webhook/tier.ts`

Generalize `resolveTopupPack` to iterate the registry; widen the return `pack`
from `"boost" | "power"` to `string` (used only for logging). Delete the
`TopupVariantConfig` interface.

```ts
import type { TopupPackDef } from "../_shared/config.ts";

export function resolveTopupPack(
  variantId: string,
  packs: TopupPackDef[],
): { pack: string; credits: number } | null {
  if (!variantId) return null;
  for (const p of packs) {
    if (parseVariantList(p.variantIds).includes(variantId)) {
      return { pack: p.key, credits: p.credits };
    }
  }
  return null;
}
```

## 3. Backend — `supabase/functions/lemonsqueezy-webhook/handler.ts`

Remove the `TOPUP_CONFIG` object and the now-unused imports
(`LS_VARIANT_TOPUP_BOOST`, `_POWER`, `TOPUP_BOOST_CREDITS`, `TOPUP_POWER_CREDITS`,
`TopupVariantConfig`). Import `TOPUP_PACKS` and call
`resolveTopupPack(variantId, TOPUP_PACKS)` in `handleOrderCreated`. No other
logic changes.

## 4. Backend tests
- `lemonsqueezy-webhook/tier_test.ts` — rewrite the resolve tests against a small
  registry fixture: a mid pack (`pro`), the smallest (`mini`), the largest
  (`mega`), an empty/whitespace variant → null, and a non-top-up variant → null.
- `lemonsqueezy-webhook/handler_test.ts` — add an `order_created` test for a new
  pack (e.g. `mega`) asserting the inserted top-up has `credits: 10000`.
- Run `deno test` for the functions dir; all green.

---

## 5. Desktop — `apps/desktop/Zerro/Services/Billing/BillingLinks.swift`

- Add `CheckoutProduct` cases `topupMini`, `topupPro`, `topupStudio`, `topupMax`,
  `topupMega` (raw values `topup_mini` … `topup_mega`). Keep `topupBoost`/`topupPower`.
- Replace the two `*TopupCheckoutURLString` / `*TopupCheckoutURL` members with a
  registry. Reuse the existing `checkout(test:live:)` switch and `resolvedURL`:

```swift
struct TopupPack: Identifiable {
    enum Badge { case mostPopular, bestValue }
    let id: String          // slug, matches backend key + product raw value suffix
    let name: String
    let credits: Int
    let price: String       // DISPLAY ONLY — LS is the source of truth for the charge
    let product: CheckoutProduct
    let checkoutURL: URL?
    let badge: Badge?
}

private static func pack(_ id: String, _ name: String, _ credits: Int, _ price: String,
                         _ product: CheckoutProduct, test: String, live: String,
                         badge: TopupPack.Badge? = nil) -> TopupPack {
    TopupPack(id: id, name: name, credits: credits, price: price, product: product,
              checkoutURL: resolvedURL(checkout(test: test, live: live)), badge: badge)
}

static let topupPacks: [TopupPack] = [
    pack("mini",   "Mini",   50,    "$5",   .topupMini,   test: "TODO-mini-test",   live: "TODO-mini-live"),
    pack("boost",  "Boost",  200,   "$10",  .topupBoost,  test: "f3518fc2-6dff-47e1-bffd-3def5a1c05a6", live: "4bd1167b-a0d8-49ab-b572-e3704fce63fc"),
    pack("power",  "Power",  500,   "$20",  .topupPower,  test: "48b7b929-7d0f-4a12-9098-a2ed75aceba5", live: "a73f69a9-0e23-470a-bc8d-3b272d0c8df5", badge: .mostPopular),
    pack("pro",    "Pro",    1000,  "$40",  .topupPro,    test: "TODO-pro-test",    live: "TODO-pro-live"),
    pack("studio", "Studio", 2500,  "$90",  .topupStudio, test: "TODO-studio-test", live: "TODO-studio-live", badge: .bestValue),
    pack("max",    "Max",    5000,  "$170", .topupMax,    test: "TODO-max-test",    live: "TODO-max-live"),
    pack("mega",   "Mega",   10000, "$300", .topupMega,   test: "TODO-mega-test",   live: "TODO-mega-live"),
]
```

(`resolvedURL`/`checkout` may need to become accessible to the helper — keep them
private to the enum; the helper is a static member so that's fine.)

## 6. Desktop — `apps/desktop/Zerro/Surfaces/Paywall/PaywallView.swift`

- Rewrite `TopupPacksRow` to render **all 7** packs from `BillingLinks.topupPacks`
  in a **2-column grid** (e.g. `LazyVGrid` with two flexible columns,
  `VFSpacing.md` spacing). The window is `.windowResizability(.contentSize)`; let
  it grow taller. Keep the existing card visual (`OptionCardChrome`, bottom-pinned
  CTA, equal heights within a row).
- Parameterize the existing `TopupPackCard` from a `TopupPack`: title = `name`,
  price = `price`, description =
  `"\(credits) credits added to your balance. Carries over for 12 months."`,
  CTA = `"Buy \(name)"`, `url`/`product` from the pack. Map `badge` →
  the existing `MostPopularBadge` (mostPopular) / `BestValueBadge` (bestValue);
  give the badged cards the green CTA tint (`.vfDevAccent`) as today.
- A pack whose `checkoutURL` is nil (placeholder) keeps its card with a disabled
  CTA (existing `isEnabled: url != nil` behaviour) — don't filter it out.

## 7. Desktop — `apps/desktop/Zerro/Surfaces/Settings/Sections/BillingSection.swift`

In `topupPrompt(balance:)`, replace the two hard-coded Boost/Power chips with the
first 2–3 entries of `BillingLinks.topupPacks` (skip any with a nil
`checkoutURL`), each chip labelled `"\(name) · \(credits) · \(price)"`, plus a
"More packs…" secondary button that opens the paywall in the `.topup` context
(`entitlements.paywallTrigger = .topup` then open the paywall window — match how
the menu-bar "Add Credits" entry does it). Remove the stale `$22` literal.

## 8. Desktop tests
- Add a test (new file `ZerroTests/TopupPacksTests.swift`) asserting
  `BillingLinks.topupPacks` has exactly 7 entries in the documented order with the
  right `name`/`credits`/`price`, that `boost`/`power` have non-nil
  `checkoutURL`, and that exactly one `.mostPopular` and one `.bestValue` badge
  exist.
- Build + run the Swift test suite; all green.

## 9. Web copy
- `apps/web/components/templates/axis/pricing.tsx` (~line 124) and
  `apps/web/public/llms-full.txt` (~line 119): replace the
  `"Top up anytime — Boost (200 credits, $10) or Power (500 credits, $22)"` line
  with: `"Top up anytime — packs from $5 (50 credits) to $300 (10,000 credits)"`.

## 10. Do NOT
- Don't change crediting/expiry/idempotency logic in `handler.ts`.
- Don't remove the `.managed`-only gating on top-ups.
- Don't invent real LemonSqueezy variant ids or buy-ids — leave the `TODO-*`
  placeholders and empty env defaults.
- Don't touch `PurchaseSuccessInfo` (the "Added N credits — M total" copy is
  already pack-agnostic).

## 11. Verify before finishing
- `deno test` (functions) green; Swift build + tests green.
- Grep for leftover `Boost`/`Power`/`$22` hard-coded literals outside the
  registry and the LemonSqueezy buy-ids — there should be none in app/UI code.
- Confirm a placeholder pack (e.g. Mega) renders a disabled CTA rather than
  crashing or opening a dead link.
