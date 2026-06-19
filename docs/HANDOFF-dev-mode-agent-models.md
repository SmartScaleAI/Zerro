# Claude Code handoff — agent model manifest (server-fetched, app-consumed)

Let Dev Mode users pick the **model the coding agent uses** (`--model`), from a list
of **current, pinned models** that stays fresh on its own. A server job fetches the
live model lists from the provider APIs into Supabase; the app reads that manifest and
shows it in the dev-settings Model section. Cursor (no server API for us) is fetched
from its own CLI client-side.

Build the BACKEND first (migration + functions + cron, deno-tested + one real invoke),
**pause for review**, then the APP integration.

## Read first
- `supabase/functions/_shared/db.ts` (service-role client), `_shared/env.ts`
  (`requireEnv`), and any existing function (e.g. `generate/`) for the function shape +
  deno test pattern. The provider secrets `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` already
  exist for `generate` — the refresh job reuses them.
- `supabase/migrations/*` for the migration style.
- App: `Services/DevAgentRegistry.swift`, `Services/Dev/DevAgentDetection.swift`,
  `Services/Dev/DevAgentRunner.swift`, `Services/Managed/ManagedBackend.swift` (base URL
  + how the app calls functions), `Preferences/PreferencesStore.swift`.

## Ground rules
- The model list is **non-sensitive** (public model ids) — the read path needs no auth.
- The refresh job is **idempotent** and safe to run repeatedly. Provider/network errors
  must never wipe the table — on a failed fetch, leave existing rows untouched.
- App: Dev-Mode-gated; offline never hard-breaks model selection (fallback chain below).

---

## BACKEND

### Part 1 — migration: `agent_models`
```
create table public.agent_models (
  id          uuid primary key default gen_random_uuid(),
  provider    text not null check (provider in ('anthropic','openai')),
  model_id    text not null,                 -- exact string passed to --model
  display_name text not null,
  rank        int  not null default 0,       -- 0 = newest = default pick
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (provider, model_id)
);
```
RLS enabled; **no public policies** (service-role only). Reads go through the
`agent-models` function (Part 3), writes through the refresh job (Part 2). (Cursor is
NOT in this table — it's client-side, see App Part 5.)

### Part 2 — `refresh-agent-models` edge function
Fetches the live model lists and upserts them. On a schedule (Part 4) + invocable
manually.
- **Anthropic:** `GET https://api.anthropic.com/v1/models` with headers
  `x-api-key: $ANTHROPIC_API_KEY`, `anthropic-version: 2023-06-01`. Response
  `{ data: [{ id, display_name, created_at }] }`.
- **OpenAI:** `GET https://api.openai.com/v1/models` with `Authorization: Bearer
  $OPENAI_API_KEY`. Response `{ data: [{ id, created }] }` (no display_name → derive,
  e.g. `gpt-5.5` → "GPT-5.5").
- **Filter to coding-relevant chat models** via stable patterns (the ONLY curation
  surface — keep it pattern-based so new versions appear automatically):
  Anthropic include `^claude-(opus|sonnet|haiku)-\d`; OpenAI include `^gpt-5` and
  `^codex` (tune to the real ids you see — verify against a live response during the
  manual invoke). Exclude embeddings/audio/etc.
- **Rank** by `created_at`/`created` descending within each provider (newest = rank 0 =
  default). Use the API `display_name` for Anthropic; derive for OpenAI.
- **Upsert** on `(provider, model_id)` (update display_name/rank/active=true/updated_at);
  then set `active = false` for rows of that provider whose `model_id` wasn't in this
  fetch (a vanished model). **Do all of a provider's writes only if its fetch
  succeeded** — a failed provider fetch leaves its rows as-is (never wipes).
- Service-role client (`db.ts`). Return a summary `{ anthropic: n, openai: m }`.
- Auth: protect manual invocation with a shared `REFRESH_CRON_SECRET` header check (the
  cron passes it); reject otherwise.
- Deno tests: mock the two provider responses → assert filter, rank, upsert, the
  vanished→inactive path, and the fetch-failure-leaves-rows-untouched path.

### Part 3 — `agent-models` read function (public GET)
- `GET` returns active models ordered by `(provider, rank)`, shape:
  `{ providers: { anthropic: [{ model_id, display_name }], openai: [...] } }`.
- No auth; add a short `Cache-Control` (e.g. 1h). Service-role read of `active = true`.
- Deno test: returns grouped, ordered, active-only.

### Part 4 — daily cron
- Migration enabling `pg_cron` + `pg_net` and scheduling a daily job (e.g. `0 6 * * *`)
  that `net.http_post`s the `refresh-agent-models` URL with the `REFRESH_CRON_SECRET`
  header. Document the secret in `.env.example` + the backend README.
- After deploy, run the function once manually and **confirm the real provider responses
  match the filter patterns** (adjust the regexes to the actual current ids). This is the
  review-stop checkpoint.

---

## APP (after backend review)

### Part 5 — model resolution
- **Manifest fetch:** a small service fetches `agent-models` at launch (and caches to
  disk). Map agent → provider: `claude-code → anthropic`, `codex → openai`.
- **Cursor:** fetched client-side from its CLI — extend `DevAgentDetection` to run
  `cursor-agent models` (off-main, cached) for Cursor's list. (Verify the exact subcommand
  + output format against the installed CLI.)
- **Fallback chain (never hard-break):** live manifest → last cached → a small **bundled**
  default list per provider (a couple of current model ids shipped in the app).
- `DevAgentRegistry`: add the model flag (`--model`) to each entry; `DevAgentRunner`
  appends `--model <model_id>` to argv **only when a model is selected** (no flag ⇒ agent
  default — but per the product decision we default to the first/newest in the list, so a
  model is normally always set).
- `PreferencesStore`: remember the selected model **per agent** (`selectedModelByAgent`),
  defaulting to the list's first entry (rank 0) when none is remembered or the remembered
  one is no longer active.

### Part 6 — dev-settings Model section (folds into the compact-toolbar Part 3)
Add a "**Model**" section to the dev-settings menu (between Agent and Project), CleanShot
style: section header "Model", the selected agent's models listed with a checkmark on the
current pick, ordered newest-first, default = first. Selecting one sets
`selectedModelByAgent[agentID]`. The list updates when the agent changes. (No "Default"
or "Custom" rows — pinned list only, per the product decision.)

## Acceptance criteria
- `refresh-agent-models` pulls live Anthropic + OpenAI models, filters to coding models,
  ranks newest-first, upserts, marks vanished ones inactive, and never wipes on a failed
  fetch. Runs daily via cron + manually with the secret.
- `agent-models` returns the grouped active list, no auth, cached.
- The app shows each agent's current pinned models in the dev-settings Model section
  (Claude Code/Codex from the manifest, Cursor from its CLI), defaults to the newest, and
  passes `--model <id>` to the runner; the pick is remembered per agent.
- Offline degrades through cache → bundled fallback; Dev Mode never breaks.
- New provider models appear automatically on the next refresh with no app release.

## Dependencies / notes
- Needs `ANTHROPIC_API_KEY` + `OPENAI_API_KEY` as Supabase secrets (already set for
  `generate`) and a new `REFRESH_CRON_SECRET`.
- Verify the provider filter regexes and the `cursor-agent models` output against live
  responses at the review-stop — don't assume the exact ids/format.
