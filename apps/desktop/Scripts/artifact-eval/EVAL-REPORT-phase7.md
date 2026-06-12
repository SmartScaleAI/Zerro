# Artifact eval — Phase 7 final run (2026-06-12)

The refactor's closing validation: the full 40-fixture artifact eval against
the SHIPPED prompt (read at run time from the `prompt-v2.md` mirror — the same
bytes `generate/prompt.ts` and `PromptGenerationSystemPrompt.swift` are
byte-identity-tested against), all six enabled registry models, flash pooled
×3 as in the Phase 1 lock run. This validates the deployed reality — no
prompt was changed; the numbers should match the lock run, and they do.

Raw outputs: `apps/desktop/eval-results/artifact-phase7/` (per-run scorecards
+ per-case JSON). Parser suite: 41/41 (`--parser-tests`, shared spec, also
ported to `ArtifactParserTests.swift`). Total spend: $4.72.

## Scorecard — Phase 7 vs the Phase 1 lock (Phase 1 in parentheses)

Bars (default model): attach ≥ 90%, validity ≥ 98%, type ≥ 85%.

| model | attach | type | validity | recovery rate |
|---|---|---|---|---|
| **gemini-3.5-flash (DEFAULT, pooled ×3, n=120)** | **99.2%** (99.2%) ✓ | **100%** (100%) ✓ | **100%** (100%) ✓ | 7/91 = 7.7% (4/91 = 4.4%) ⚠ |
| gpt-5.4-mini | 95% (95%) ✓ | 100% (100%) ✓ | 100% (100%) ✓ | 0 (0) |
| gemini-3.1-pro-preview | 100% (100%) ✓ | 100% (100%) ✓ | 100% (100%) ✓ | 0 (0) |
| claude-sonnet-4-6 | 100% (100%) ✓ | 100% (100%) ✓ | 100% (100%) ✓ | 0 (0) |
| claude-opus-4-7 | 100% (100%) ✓ | 100% (100%) ✓ | 100% (100%) ✓ | 0 (0) |
| gpt-5.5 | 100% (100%) ✓ | 100% (100%) ✓ | 100% (100%) ✓ | 0 (0) |

## Drift verdict

**The four pass metrics: zero drift.** Every attach/type/validity number is
identical to the lock run, including the per-case failure pattern — flash's
single pooled miss is `ch-04-this-is-broken-no-ask` over-attaching in 1 of 3
runs (the same hard case, same direction, as Phase 1), and mini's two misses
are its familiar borderline under-attach (`ap-05`) plus the same `ch-04`.

**One metric crossed the 2-point flag line: flash's recovery rate, 4.4% →
7.7% (+3.3pp).** Flagged per the brief. Assessment: this is the watch-metric,
not a pass bar, and the evidence says sampling noise, not regression —

- absolute counts are 7 vs 4 recovered fences out of ~91 artifacts; a
  difference of 3 occurrences at this sample size is well inside binomial
  noise for a ~5% event;
- every recovery was the same mechanical flavor as Phase 1 (six R1 chevron
  miscounts — `">"`/`">>>>"` for `">>>"` — one R2 spillover), all
  type-correct, all valid after recovery; validity held at 100%;
- `doc-03-standing-desk-description` slipped in all three runs — it was a
  known recovery-prone case at lock time too.

Recommended posture: no action now; keep the production `Log.artifacts`
recovery line as the live signal. If real-world recovery trends near ~10%,
re-run a pooled eval before touching the prompt.

## Recovered cases (flash, all runs)

| run | case | rule |
|---|---|---|
| 1 | doc-03-standing-desk-description | R2 (open-fence body spillover) |
| 1 | doc-04-backend-job-posting | R1 (`">"` for `">>>"`) |
| 2 | ap-04-dark-mode-toggle | R1 (`">>>>"`) |
| 2 | doc-03-standing-desk-description | R1 (`">"`) |
| 3 | msg-03-support-ticket-reply | R1 (`">>>>"`) |
| 3 | sn-02-ffmpeg-mov-to-mp4 | R1 (`">>>>"`) |
| 3 | doc-03-standing-desk-description | R1 (`">"`) |
