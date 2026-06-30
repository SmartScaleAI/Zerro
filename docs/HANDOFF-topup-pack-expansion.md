# Top-up pack expansion — plan

Replace the 2 packs (Boost, Power) with a 7-pack ladder. Reprice Power $22 → $20.
Everything else (12-month expiry, Managed-only, $0.01/credit metering) stays the same.

## The packs

| Pack | Price | Credits | Badge | Change |
|------|------:|--------:|-------|--------|
| Mini | $5 | 50 | — | new |
| Boost | $10 | 200 | — | none |
| Power | $20 | 500 | Most popular | reprice $22→$20 |
| Pro | $40 | 1,000 | — | new |
| Studio | $90 | 2,500 | Best value | new |
| Max | $170 | 5,000 | — | new |
| Mega | $300 | 10,000 | — | new |

## What you do

1. **In LemonSqueezy:** change Power's price to $20, and create 5 new one-time
   products (Mini, Pro, Studio, Max, Mega) like the existing Boost/Power.
2. For each new product, send me its **variant ID** and **checkout buy-id** —
   from BOTH test and live mode.
3. Pick: paywall layout (show all 7, or 4 + "See all"?), and whether to nudge Pro
   to $38 so it isn't the same per-credit price as Power.

## What I do (once I have the IDs)

1. Backend: turn the 2 hardcoded packs into a 7-pack list + update the webhook + tests.
2. Desktop app: same list drives the paywall cards and Settings chips; update Power's price label.
3. Website: update the top-up line on the pricing page.
4. Test-mode purchase of all 7 packs to confirm the right credits land.

## Notes

- Power's price drop is a LemonSqueezy edit only — credits stay 500, no code change.
- The backend can be built and unit-tested before the LemonSqueezy products exist.
- Top-ups stay Managed-only (subscribers); credits still carry over 12 months.
