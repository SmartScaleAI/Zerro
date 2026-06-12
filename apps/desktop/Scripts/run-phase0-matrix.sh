#!/usr/bin/env bash
# =============================================================================
# run-phase0-matrix.sh — drive the Phase 0 multi-model eval gate. HISTORICAL:
# predates the typed-artifact refactor and NO LONGER RUNS (it invokes the
# harness's removed `--mode` flag; there is one unified v2 prompt now). Kept
# as the record of how the Phase 0 gate was driven — current evals use
# `eval-models.mjs --artifact` (see README-eval.md).
# =============================================================================
# Runs the candidate models across the chosen recordings in BOTH v1 modes, plus a
# Gemini-Pro high-thinking supplementary pass. Anthropic models are included
# only when ANTHROPIC_API_KEY is set (otherwise the harness would exit on its
# key-guard); pass MODELS explicitly to override.
#
#   set -a; source ../../supabase/.env.local; set +a
#   Scripts/run-phase0-matrix.sh
#
# Output layout (one combined SCORECARD.md per leaf dir):
#   eval-results/<rec-short>/<mode>/              ← main batch (thinking=low)
#   eval-results/<rec-short>/<mode>-pro-high/     ← gemini pro @ thinking=high
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."   # apps/desktop

RECS=(
  "zerro-work-6C25EA65-1546-410F-8C93-565AF2E30670"   # terminal walk — dense code/text
  "zerro-work-AA43AB71-86E1-4E5A-827C-7FCC71D7E0F3"   # demo booking — small UI text + flow
  "zerro-work-4AE873E5-95C8-429D-82D8-80019AFF0773"   # homepage review — mixed windows
  "zerro-work-BFC81C3C-50A3-4622-B00D-BF2F477E3980"   # getzerro.app review — web copy
  "zerro-work-1F22B514-A5A5-481E-AE01-5B2F62EA6D15"   # short clip — small-text fidelity
)

# Base (non-Pro) models. Pro is added separately so its thinking level is isolated.
BASE_MODELS="openai:gpt-5.4-mini,openai:gpt-5.5,gemini:gemini-3.5-flash"
ANTHRO_MODELS="anthropic:claude-sonnet-4-6,anthropic:claude-opus-4-7"
PRO="gemini:gemini-3.1-pro-preview"

# Include Anthropic only if a key is present.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MAIN_MODELS="${BASE_MODELS},${PRO},${ANTHRO_MODELS}"
  echo ">> ANTHROPIC_API_KEY present — running all six models."
else
  MAIN_MODELS="${BASE_MODELS},${PRO}"
  echo ">> ANTHROPIC_API_KEY absent — running 4 models (Anthropic deferred)."
fi

for rec in "${RECS[@]}"; do
  short="${rec#zerro-work-}"; short="${short%%-*}"
  for mode in instruct explain; do
    echo "================ $short / $mode (main) ================"
    node Scripts/eval-models.mjs "eval-recordings/$rec" \
      --mode "$mode" --models "$MAIN_MODELS" \
      --out "eval-results/$short/$mode"
    echo "================ $short / $mode (pro high) ============"
    node Scripts/eval-models.mjs "eval-recordings/$rec" \
      --mode "$mode" --models "$PRO" --thinking high \
      --out "eval-results/$short/$mode-pro-high"
  done
done
echo ">> matrix complete."
