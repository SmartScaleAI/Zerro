-- =============================================================================
-- Zerro Dev Mode — retire the OpenAI side of the agent_models manifest
-- =============================================================================
-- One-time cleanup: the OpenAI manifest is retired. Codex (the OpenAI Dev Mode
-- agent) sources its model list from its OWN per-account tool
-- (~/.codex/models_cache.json) client-side, because a ChatGPT-account Codex uses
-- its own slugs (e.g. `gpt-5.5`) and REJECTS the OpenAI API codex ids the
-- manifest carried. So the manifest's openai rows are unused — delete them. The
-- `refresh-agent-models` function now fetches Anthropic only (redeployed), so no
-- new openai rows are ever written.
--
-- The `provider in ('anthropic','openai')` CHECK is left permissive (not
-- tightened) so re-enabling an OpenAI provider later is a code change, not
-- another migration. IDEMPOTENT: a re-run deletes zero rows.
-- =============================================================================

delete from public.agent_models where provider = 'openai';
