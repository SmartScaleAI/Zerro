# LemonSqueezy Setup Checklist — Multi-Model Credits Launch

Manual dashboard work (only you can do this — it's account/storefront config, not code). The backend code is already wired to read the IDs below; until they're filled, top-ups are inert and yearly billing may misbehave.

**Two things to fill for each product you create:** the **variant ID** (goes into a Supabase secret the webhook reads) and, for purchasable-from-app items, the **checkout URL** (goes into the Swift `BillingLinks`).

---

## What already exists (verify, don't recreate)

The app already has real checkout URLs for three products — confirm these still match what you want:

- **BYOK** — `BillingLinks.byokCheckoutURLString` → `store.getzerro.app/checkout/buy/1e36ae90-…`. ⚠️ **Price must be updated to $69** (was the old model). Confirm it includes the "1 year of updates" terms.
- **Starter subscription** — `starterCheckoutURLString` → `…/90ffa6e4-…`
- **Pro subscription** — `proCheckoutURLString` → `…/4ab963c6-…`

> Note: the app's "Managed" plan = the **Pro** tier (300 credits). "Starter" (100) is a dormant cheaper tier for later. Make sure the app's Subscribe button points at the Pro/Managed checkout.

---

## 1. Managed subscription — monthly + yearly (one product, two variants)

The Managed plan needs BOTH a monthly and a yearly variant, both mapping to the **`pro` tier (300 credits)**.

| Create | Price | → Variant ID goes into secret |
|---|---|---|
| Managed **monthly** variant | $15/mo | `LS_VARIANT_PRO` (comma-separated list — include this id) |
| Managed **yearly** variant | $144/yr ($12/mo) | `LS_VARIANT_PRO` (same list, add this id too) **AND** `LS_VARIANT_YEARLY` (this id only) |

- `LS_VARIANT_PRO` holds **both** ids (comma-separated) → both resolve to `pro`/300.
- `LS_VARIANT_YEARLY` holds **only the yearly id** → drives `billing_interval = 'yearly'`.
- Checkout URLs: the app currently has one `proCheckoutURL`. Decide whether the Subscribe button offers a monthly/yearly choice in-app or links to one LS checkout with a toggle. (App copy already says "$15/month, or $12/month billed yearly".)

---

## 2. Top-up packs — Boost + Power (two one-time products)

These don't exist yet. Create both as **one-time** purchases (not subscriptions).

| Create | Price | Credits | → Variant ID secret | → App checkout URL |
|---|---|---|---|---|
| **Boost** | $10 | 200 | `LS_VARIANT_TOPUP_BOOST` | `BillingLinks.boostTopupCheckoutURLString` (currently `TODO:`) |
| **Power** | $22 | 500 | `LS_VARIANT_TOPUP_POWER` | `BillingLinks.powerTopupCheckoutURLString` (currently `TODO:`) |

- Credits are also config: `TOPUP_BOOST_CREDITS=200`, `TOPUP_POWER_CREDITS=500` (defaults already match — only set if you change them).
- `TOPUP_EXPIRY_MONTHS=12` (default already 12).
- Until the two checkout URLs are filled in `BillingLinks.swift`, the app shows the "Running low" notice **without** the buy chips (by design).
- **Important:** top-ups attach to the buyer's existing subscription via LS customer id. The store/app should only offer top-ups to Managed users (a BYOK/trial buyer has no subscription to attach to → credited nothing + a warn log).

---

## 3. BYOK license — update to $69

- Update the existing BYOK product price to **$69 one-time**, terms "includes 1 year of updates."
- No new variant secret needed for BYOK (it's gated app-side by license activation, sub-task E), but confirm the `license_key_created` webhook still fires for it.

---

## 4. Supabase secrets to set (after creating products)

```
supabase secrets set \
  LS_VARIANT_PRO="<monthly_id>,<yearly_id>" \
  LS_VARIANT_YEARLY="<yearly_id>" \
  LS_VARIANT_TOPUP_BOOST="<boost_id>" \
  LS_VARIANT_TOPUP_POWER="<power_id>" \
  TRIAL_CREDITS="40"
  # CREDITS_PRO already 300, TOPUP_*_CREDITS / TOPUP_EXPIRY_MONTHS already defaulted
  # ANTHROPIC_API_KEY / GEMINI_API_KEY / OPENAI_API_KEY — confirm set (Phases 3/4)
```

Then fill the two top-up checkout URLs in `apps/desktop/Zerro/Services/Billing/BillingLinks.swift` (grep `TODO: top-up checkout`).

---

## 5. ✅ E2 — RESOLVED: yearly credit refresh is a pg_cron job (2026-06-11)

Confirmed against LS docs: LemonSqueezy fires `subscription_payment_success`
(`billing_reason = "renewal"`) for an annual subscription **once a year**, not
monthly. The fix is built: migration `20260611120000_yearly_credit_refresh.sql`
adds `refresh_yearly_credit_periods()` + the hourly pg_cron job
**`refresh-yearly-credits`**, which rolls a fresh 300-credit period monthly for
active yearly subs (idempotent, bounded by the paid year's end). See
README-backend.md → "Yearly subscriptions" and DEPLOY-RUNBOOK.md step 4.

**Remaining launch gate for yearly:** after `supabase db push` on prod, verify
pg_cron is enabled (Database → Extensions) and the `cron.job` row exists —
don't enable the yearly variant until it does.

---

## ⚠️ Webhook events (the gotcha that bit us in test)

Both the **test** and **live** webhooks must subscribe to these events. `order_created` was MISSING on the test webhook and top-up purchases silently didn't credit until it was enabled — **verify it's checked on the LIVE webhook before launch or real top-ups won't credit.**

Required (code handles): `order_created`, `order_refunded`, `subscription_created`, `subscription_updated`, `subscription_cancelled`, `subscription_expired`, `subscription_payment_success`, `subscription_payment_recovered`, `subscription_payment_failed`, `subscription_payment_refunded`, `license_key_created`.

Confirmed working in TEST mode (2026-06-11): subscription → pro/300 mapping, and `order_created → topup_boost_credited_200`. Both paths validated end to end.

## Launch gate summary

- [ ] Managed monthly + yearly variants created, both → `LS_VARIANT_PRO`, yearly also → `LS_VARIANT_YEARLY`
- [ ] Boost ($10/200) + Power ($22/500) one-time products created → topup secrets + app URLs
- [ ] BYOK product updated to $69 / 1-year-updates
- [ ] Secrets set; top-up checkout URLs filled in `BillingLinks.swift`
- [ ] E2: `refresh-yearly-credits` pg_cron job verified on prod (`cron.job` row) — **before yearly goes live**
- [ ] Test-mode end-to-end: buy each product, confirm webhook credits/maps correctly
