# Claude Code handoff — Tier 3 analytics (monetization)

Instrument the money funnel in the Zerro macOS app and the LemonSqueezy webhook.
This is the only tier that touches the Supabase edge function, and it depends on
one identity decision (read §0 first).

## Read first
- `docs/HANDOFF-tier1-core-funnel.md`, `docs/HANDOFF-tier2-reliability.md`,
  `docs/ANALYTICS-POSTHOG-PLAN.md` §4.8 (billing) + §2 (identity) + §7 (privacy).
- App billing surfaces: `Services/Billing/EntitlementStore.swift`,
  `Services/Billing/BillingLinks.swift`, `Surfaces/Paywall/PaywallView.swift`,
  `Surfaces/Settings/Sections/APIAuthSection.swift`,
  `Preferences/KeychainStore.swift`.
- Webhook: `supabase/functions/lemonsqueezy-webhook/handler.ts` (+ `store.ts`).

## Ground rules (binding)
- App events go through `Observability/Analytics.swift`. Metadata only — enums,
  counts, durations, tiers, providers. NEVER email, customer name, license key,
  raw balance, or any PII. The webhook must capture `tier` only — never the
  customer email/name.
- Stay behind the existing opt-out gate on the app side.
- Keep diffs focused; match surrounding style.

---

## 0. Identity decision (implement as specified)

Capture `subscription_activated` / `subscription_lapsed` **server-side from the
webhook** (reliable even if the app is closed). To keep these on the SAME
PostHog person as the app's funnel, plumb the app's anonymous PostHog
`distinct_id` through the LemonSqueezy checkout `custom_data`:

- Add an accessor to `Analytics`:
  `static var distinctId: String? { didStart ? PostHogSDK.shared.getDistinctId() : nil }`.
- When opening ANY checkout URL, append LemonSqueezy custom-data query params:
  `?checkout[custom][ph_distinct_id]=<distinctId>&checkout[custom][product]=<product>`
  (URL-encode). LemonSqueezy surfaces these in webhook `meta.custom_data`, which
  the handler already reads for tier.
- The webhook captures under `meta.custom_data.ph_distinct_id` when present,
  else falls back to `ls:<subscription_id>` (still counted, just not stitched).

Keep the purely-local trial events (`trial_started`, `trial_exhausted`)
client-side — they have no server equivalent. Do NOT also fire `subscription_*`
client-side, so the webhook stays the single source and nothing double-counts.

---

## 1. App: `paywall_shown` + `trigger`

`PaywallView.onAppear` currently fires `paywall_shown` with no properties. The
paywall is opened only by the recording-start gate, which knows the reason via
`EntitlementStore.PreflightBlock` (`outOfCredits` / `subscriptionInactive` /
`apiKeyMissing`).

- Thread the block reason to the paywall: stash the triggering reason where
  `PaywallView` can read it on appear (e.g. a `paywallTrigger` value set on the
  store/AppState when the gate routes to the paywall in `presentPreflightBlock`),
  and read it in `onAppear`.
- Map to `trigger`: `out_of_credits` / `subscription_inactive` /
  `api_key_missing` / `manual` (fallback if no reason was set).

```
paywall_shown { trigger: out_of_credits | subscription_inactive | api_key_missing | manual }
```

## 2. App: `checkout_opened`

Every checkout opens through `BillingLinks` + `NSWorkspace.shared.open`. There
are four entry points: subscription (Pro) and BYOK in `PaywallView`, plus the
two top-up packs (Boost/Power) in the low-balance prompt.

- At each open site, fire `checkout_opened { product }` where `product` ∈
  `subscription_pro` / `byok` / `topup_boost` / `topup_power`.
- At the same site, build the URL with the §0 custom-data params appended
  (`ph_distinct_id` + `product`). A small `BillingLinks` helper that takes a base
  URL + product and returns the URL with custom-data query items keeps this DRY.
- If the checkout URL is a nil placeholder (unfilled product), fire nothing —
  match the existing no-op-on-nil behavior.

## 3. App: `byok_key_added` / `byok_key_removed`

BYOK provider keys live in three Keychain slots (`openAIAPIKey`, `geminiAPIKey`,
`anthropicAPIKey`) and are edited in `Settings/Sections/APIAuthSection.swift`.

- Fire `byok_key_added { provider }` when a slot goes empty→non-empty (a key is
  saved), and `byok_key_removed { provider }` when it goes non-empty→empty.
  `provider` ∈ `openai` / `gemini` / `anthropic`.
- Detect the transition at the save/clear site in `APIAuthSection` (compare
  prior presence to new). NEVER include the key value — presence only.

## 4. App: trial transitions via the `EntitlementStore.state` didSet

The `didSet` on `EntitlementStore.state` (added in Tier 1 for super-properties)
is the natural chokepoint. Add `oldValue`→`state` transition events there:

| Event | Transition | Properties |
|---|---|---|
| `trial_started` | `.trial(nil)`/no balance → `.trial(n)` with a real balance (first grant) | `credits_granted` = n |
| `trial_exhausted` | `.trial(_)` → `.expired` | — |

Do NOT emit `subscription_activated` / `subscription_lapsed` here (webhook owns
them). Keep it to the two trial events. Note the super-property update call
already in this didSet must remain.

---

## 5. Webhook: server-side `subscription_activated` / `subscription_lapsed`

In `supabase/functions/lemonsqueezy-webhook/`:

- Add a tiny PostHog capture helper (e.g. `posthog.ts`): POST to
  `${POSTHOG_HOST||https://us.i.posthog.com}/capture/` with
  `{ api_key, event, distinct_id, properties }`. Read `POSTHOG_API_KEY` /
  `POSTHOG_HOST` from `Deno.env`. If `POSTHOG_API_KEY` is unset, no-op (so dev
  and tests don't transmit). Never throw into the webhook path — wrap in
  try/catch and log; analytics must not break billing.
- `distinct_id` = `payload.meta?.custom_data?.ph_distinct_id ?? "ls:" + <subscription_id>`.
- Fire ONLY on the paths where the DB change actually applied — NOT on the
  stale/redelivery `stale_ignored` no-op branches — so webhook redeliveries
  (which the handler already dedupes/idempotently 200s) don't double-count:
  - In `handleSubscriptionUpsert` on `subscription_created`, after the upsert
    succeeds (the `upserted+period_opened` path): `subscription_activated { tier }`.
  - In `handleSubscriptionStatusChange` for `subscription_cancelled` →
    `subscription_lapsed { previous_tier: <tier>, reason: "cancelled" }`, and for
    `subscription_expired` → `subscription_lapsed { previous_tier: <tier>, reason: "expired" }`.
- `tier` is the already-resolved `ManagedTier` string (`starter`/`pro`).
  Properties are tier + reason ONLY — no email, customer id, or order id.

```
subscription_activated { tier: starter|pro }
subscription_lapsed    { previous_tier: starter|pro, reason: cancelled|expired }
```

> Note on `out_of_credits`: not a separate event — it's already covered by
> `paywall_shown{trigger:out_of_credits}` and `generation_failed{reason:out_of_credits}`.

---

## Verify before finishing
- App builds (Xcode/`xcodebuild`); webhook tests pass
  (`deno test` in `supabase/functions/lemonsqueezy-webhook/`), and your new
  PostHog helper is a no-op when `POSTHOG_API_KEY` is unset (so existing
  handler tests don't transmit or break).
- `paywall_shown.trigger` reflects the real gate reason; `manual` only when none.
- `checkout_opened` fires once per open with the right `product`, and the opened
  URL carries `checkout[custom][ph_distinct_id]` + `checkout[custom][product]`
  (verify the constructed URL string).
- `byok_key_added`/`_removed` fire on presence transitions only, never carry a
  key value.
- `trial_started`/`trial_exhausted` fire on the right entitlement transitions;
  `subscription_*` do NOT fire client-side.
- Webhook: a `subscription_created` emits one `subscription_activated{tier}` to
  PostHog under the passed distinct_id; a redelivery (stale) emits nothing;
  cancelled/expired emit `subscription_lapsed`. No email/PII in any property.
- Show me the final diff (app + webhook), how each point holds, and the event list:
```
App:     paywall_shown (+trigger), checkout_opened{product},
         byok_key_added{provider}, byok_key_removed{provider},
         trial_started{credits_granted}, trial_exhausted
Webhook: subscription_activated{tier}, subscription_lapsed{previous_tier,reason}
Plumbing: Analytics.distinctId; checkout URLs carry ph_distinct_id + product
```
