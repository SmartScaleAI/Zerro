-- Local dev seed — agent_models
--
-- Mirrors production's Anthropic manifest so a DEBUG build pointed at the local
-- stack (ZERRO_FUNCTIONS_BASE_URL = http://127.0.0.1:54321/functions/v1) shows
-- the full Claude Code model list instead of the 2-item bundled fallback.
--
-- Local-only: seed.sql runs on `supabase db reset` / `supabase start`, never on
-- `db push` to prod. Only Anthropic (Claude Code) lives here — Codex and Cursor
-- source their model lists client-side from their own CLIs, not this table.
-- Idempotent (ON CONFLICT) so it's safe to re-run against an already-seeded DB.

insert into public.agent_models (provider, model_id, display_name, rank) values
  ('anthropic', 'claude-opus-4-8',            'Claude Opus 4.8',   0),
  ('anthropic', 'claude-opus-4-7',            'Claude Opus 4.7',   1),
  ('anthropic', 'claude-sonnet-4-6',          'Claude Sonnet 4.6', 2),
  ('anthropic', 'claude-opus-4-6',            'Claude Opus 4.6',   3),
  ('anthropic', 'claude-opus-4-5-20251101',   'Claude Opus 4.5',   4),
  ('anthropic', 'claude-haiku-4-5-20251001',  'Claude Haiku 4.5',  5),
  ('anthropic', 'claude-sonnet-4-5-20250929', 'Claude Sonnet 4.5', 6)
on conflict (provider, model_id) do update
  set display_name = excluded.display_name,
      rank         = excluded.rank,
      active       = true;
