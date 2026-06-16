# Plan — Managed Generation Costs in PostHog (via Supabase data warehouse)

Status: proposal · Scope: surface `generation_log` cost/token data in PostHog · Date: 2026-06-16

## Goal & approach

Get per-generation **cost and token** visibility for managed + trial users into
PostHog, alongside the product analytics we already built — without sending any
LLM content and without new code in the `generate` function.

**Why the data-warehouse route (not `$ai_generation` events):** you already log
every managed/trial generation to Supabase `generation_log` with the exact
metadata PostHog AI observability would capture — and it's *better* (it's your
billing source of truth, already content-free, tied to `subscription_id`).
Emitting `$ai_generation` events would just duplicate it. Instead, **connect
`generation_log` to PostHog's data warehouse** (read-only) and build cost
insights directly on it. This reuses authoritative data and lets you correlate
cost with the funnels we already have.

> The PostHog **AI observability tab** will stay empty — that's fine, it renders
> from `$ai_generation` events we're deliberately not sending. We build on the
> warehouse table instead.

## The source table (`public.generation_log`)

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `subscription_id` | uuid (nullable) | **NULL = trial** proxy generation; **set = managed** subscriber |
| `created_at` | timestamptz | the time dimension |
| `tokens_in` | integer | prompt tokens |
| `tokens_out` | integer | completion tokens |
| `est_cost_usd` | numeric(10,6) | estimated cost per call |
| `success` | boolean | |
| `model` | text | e.g. `gpt-5.5`, `gemini-3.5-flash` (provider is derivable: gpt→openai, gemini→google, claude→anthropic) |

Already metadata-only (table comment: "Never transcript, audio, or frames"). No
PII — `subscription_id` is a UUID. BYOK generations are **not** here (on-device,
never hit the server) — correctly out of scope.

## 1. Connect the source (your step — needs DB credentials)

PostHog doesn't have a menu literally called "Data warehouse" — the capability
lives under a few items: **Sources** (connect external tables), the **SQL
editor** (query/build on them), and **Models** (optional saved views). To
connect, go to **Sources** (in the data menu's **Pipeline** group, just below
*Exports*) → **New source → Postgres**, and point it at Supabase:

1. **Create a least-privilege read-only Postgres role** in Supabase scoped to the
   columns we need — ideally `GRANT SELECT` on `public.generation_log` only (and
   `public.subscriptions` if you want tier joins, see §3). Don't reuse the
   service role.
2. Give PostHog the connection details (host, port, database, the read-only
   user/password, schema `public`, table `generation_log`). *I can't enter
   credentials — this part is yours.*
3. **Sync settings:** incremental on `created_at` (or `id`), schedule hourly or
   daily. generation_log is low-volume (one row per managed/trial generation), so
   warehouse sync cost is negligible.

Security notes: read-only role, metadata-only columns, no content/PII leaves
Supabase. Consider excluding the table from any row-level concerns since it's
already non-sensitive.

## 2. The "Managed Generation Costs" dashboard

Built as **SQL (HogQL) insights** over the warehouse table (aggregations like
`sum(est_cost_usd)` and grouping by `subscription_id` are cleanest in SQL).
Sections:

**SPEND**
- **Total spend over time** — `sum(est_cost_usd)` by day/week. Your top-line burn.
- **Spend by model** — `sum(est_cost_usd)` grouped by `model` (bar). The biggest
  cost lever (gpt-5.5 ≈ $0.05–0.37/call vs gemini-3.5-flash ≈ $0.01–0.04).
- **Trial vs managed spend** — split by `subscription_id IS NULL`. How much
  free/trial generation is costing you vs paid.

**UNIT ECONOMICS** (the important part for the managed plan)
- **Avg cost per generation** — overall and by `model`.
- **Cost per managed subscription (top spenders)** — `sum(est_cost_usd)` grouped
  by `subscription_id` (managed only), top N. Flags expensive customers.
- **Monthly cost per active managed sub vs price** — avg monthly spend per active
  managed `subscription_id`, to compare against the $12/mo managed price (your
  gross-margin signal). SQL insight; pairs with §3 for tier.

**VOLUME & QUALITY**
- **Generations over time** — count, split managed vs trial.
- **Tokens over time** — `sum(tokens_in)` + `sum(tokens_out)`.
- **Success rate** — `countIf(success) / count()`.

## 3. Optional: join `subscriptions` for tier-level analysis

Sync `public.subscriptions` too (read-only) so you can join
`generation_log.subscription_id → subscriptions.id` and break cost down by
**tier** (starter/pro). Unlocks "cost & margin by plan tier" — the cleanest view
of managed-plan profitability. Optional; the core cost dashboard works without it.

## 4. How this complements what we already have

- The macOS app dashboard's `generation_succeeded`/`model_changed` show *usage*;
  this shows the *cost* of that usage — same models, now with dollars.
- Cross-reference: cost (warehouse) vs `subscription_activated` (revenue) =
  managed-plan margin.

## Caveats
- **Not real-time** — warehouse syncs on a schedule (hourly/daily), so cost
  tiles lag slightly. Fine for economics; not for live monitoring.
- `est_cost_usd` is an **estimate** (per `cost.ts`), not the provider invoice —
  good for trends and relative comparison, treat absolute totals as approximate.

## Where to build the insights

Once the source is syncing, the table is queryable in the **SQL editor**
(Analytics group) like any other table, e.g. `SELECT model, sum(est_cost_usd)
FROM generation_log GROUP BY model`. Each query is saved as an insight and added
to the dashboard. (No data shows in the **AI observability** tab — that's
expected; it only reads `$ai_generation` events.)

## Build order
1. You connect the Postgres source via **Sources** (§1) + optionally
   `subscriptions` (§3), and confirm it syncs (the table appears in the SQL editor).
2. I build the SQL insights and assemble the **"Zerro — Managed Costs"**
   dashboard (same way I built the app/website ones).
