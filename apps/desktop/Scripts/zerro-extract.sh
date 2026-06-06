#!/bin/bash
# =============================================================================
# zerro-extract.sh — re-extract a working dir from a .mov via the REAL pipeline
# =============================================================================
# Runs ProcessingPipeline.process(sourceURL:) on a recording and writes its
# working directory (frames + audio + manifest.json) to --out. This is the eval
# loop's re-extraction step: when a future phase changes frame sampling /
# resolution / OCR, run this on a captured `source.mov` (see
# Scripts/capture-recording.sh) and diff the result against the originally
# captured working dir — same recording, new config, production code path.
#
# It drives the EvalExtractionRunnerTests/testExtract XCTest (which calls the
# real pipeline) by setting two env vars and running only that test. No
# extraction logic is duplicated here.
#
# USAGE:
#   Scripts/zerro-extract.sh <input.mov> --out <dir>
#
# Example (sanity-check re-extraction == app behavior):
#   Scripts/zerro-extract.sh eval-recordings/my-clip/source.mov --out /tmp/reextract
#   # then compare /tmp/reextract/manifest.json against
#   #              eval-recordings/my-clip/manifest.json (frame count + timestamps)
#
# Requires Xcode command-line tools. Builds the Debug app + test bundle on the
# first run (cached thereafter).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

INPUT="${1:-}"
if [ -z "$INPUT" ] || [ "$INPUT" = "--out" ]; then
  echo "usage: Scripts/zerro-extract.sh <input.mov> --out <dir>" >&2
  exit 1
fi
shift

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$OUT" ]; then
  echo "error: --out <dir> is required" >&2
  exit 1
fi
if [ ! -f "$INPUT" ]; then
  echo "error: input .mov not found: $INPUT" >&2
  exit 1
fi

# Resolve to absolute paths — the test process runs from a different cwd.
INPUT_ABS="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

echo "re-extracting via ProcessingPipeline…"
echo "  in:  $INPUT_ABS"
echo "  out: $OUT_ABS"

# Inject the in/out paths into the hosted test process. xcodebuild does NOT
# pass arbitrary parent env vars through to the test runner, but it DOES forward
# any var prefixed `TEST_RUNNER_`, stripping the prefix — so the test reads them
# as ZERRO_EXTRACT_IN / ZERRO_EXTRACT_OUT via ProcessInfo.processInfo.environment.
# `-quiet` keeps build noise down; the runner's own banner still prints.
TEST_RUNNER_ZERRO_EXTRACT_IN="$INPUT_ABS" \
TEST_RUNNER_ZERRO_EXTRACT_OUT="$OUT_ABS" \
xcodebuild test \
  -project "$PROJECT_DIR/Zerro.xcodeproj" \
  -scheme Zerro \
  -configuration Debug \
  -only-testing:ZerroTests/EvalExtractionRunnerTests/testExtract \
  -quiet

echo "done → $OUT_ABS"
ls -1 "$OUT_ABS" | sed 's/^/  /'
