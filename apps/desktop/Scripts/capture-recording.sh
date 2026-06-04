#!/bin/bash
# =============================================================================
# capture-recording.sh — snapshot a Zerro working directory for eval-models.mjs
# =============================================================================
# The app writes each recording's audio + frames + manifest.json to a temp
# working directory (zerro-work-<UUID> under $TMPDIR) and DELETES it after a
# successful generation. This script watches for those directories and copies
# each one to ./eval-recordings/ the moment the manifest lands, so you get a
# durable copy to run the eval harness against.
#
# USAGE:
#   ./Scripts/capture-recording.sh        # start watching, then record in Zerro
#   Ctrl-C when done. Captured dirs land in ./eval-recordings/<name>/
#
# Then:
#   node Scripts/eval-models.mjs eval-recordings/<name> --mode instruct \
#     --models gemini:gemini-3.5-flash,openai:gpt-4o
# =============================================================================
set -euo pipefail

DEST="${1:-eval-recordings}"
mkdir -p "$DEST"
TMP="${TMPDIR:-/tmp}"

echo "watching $TMP for zerro-work-* directories… (Ctrl-C to stop)"
echo "record in Zerro now; captures land in $DEST/"

seen=""
while true; do
  for dir in "$TMP"zerro-work-*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    case "$seen" in *"$name"*) continue ;; esac
    # Wait for the manifest — it's written LAST, so its presence means the
    # audio + every frame are already on disk.
    if [ -f "$dir/manifest.json" ]; then
      cp -R "$dir" "$DEST/$name"
      seen="$seen $name"
      frames=$(ls "$DEST/$name" | grep -c '\.jpg$' || true)
      echo "captured: $DEST/$name ($frames frames)"
    fi
  done
  sleep 0.5
done
