#!/usr/bin/env bash
# Phase 0.5 — re-run ONLY the explain matrix (post EXPLAIN-prompt fix).
# Same 5 recordings × 6 models + Gemini-Pro high pass. Run from apps/desktop with
# OPENAI/GEMINI/ANTHROPIC keys exported.
set -uo pipefail
cd "$(dirname "$0")/.."   # apps/desktop
RECS=(
  zerro-work-1F22B514-A5A5-481E-AE01-5B2F62EA6D15
  zerro-work-4AE873E5-95C8-429D-82D8-80019AFF0773
  zerro-work-6C25EA65-1546-410F-8C93-565AF2E30670
  zerro-work-AA43AB71-86E1-4E5A-827C-7FCC71D7E0F3
  zerro-work-BFC81C3C-50A3-4622-B00D-BF2F477E3980
)
MODELS=openai:gpt-5.4-mini,openai:gpt-5.5,gemini:gemini-3.5-flash,gemini:gemini-3.1-pro-preview,anthropic:claude-sonnet-4-6,anthropic:claude-opus-4-7
PRO=gemini:gemini-3.1-pro-preview
for rec in "${RECS[@]}"; do
  short="${rec#zerro-work-}"; short="${short%%-*}"
  echo "==== $short explain (6 models) ===="
  node Scripts/eval-models.mjs "eval-recordings/$rec" --mode explain --models "$MODELS" --out "eval-results/$short/explain"
  echo "==== $short explain pro-high ===="
  node Scripts/eval-models.mjs "eval-recordings/$rec" --mode explain --models "$PRO" --thinking high --out "eval-results/$short/explain-pro-high"
done
echo ">> explain rerun complete."
