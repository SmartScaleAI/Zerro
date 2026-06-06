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
# It ALSO copies the raw source recording (zerro-<UUID>.mov) next to the
# working dir as `source.mov`, so a later phase can re-extract frames from the
# real recording (see Scripts/zerro-extract.sh) when sampling/resolution
# changes. The two are NOT linked by name (their UUIDs differ), so we pair a
# captured working dir with the newest as-yet-unclaimed `zerro-*.mov`.
#
#   ┌─────────────────────────── REQUIREMENT ───────────────────────────┐
#   │ The source `.mov` only survives long enough to copy if the app was │
#   │ launched with eval retention ON. In a DEBUG build, set the Xcode   │
#   │ "Zerro" scheme launch arg:   -RetainEvalArtifacts YES              │
#   │ (Edit Scheme ▸ Run ▸ Arguments). Without it the app deletes the    │
#   │ `.mov` right after extraction and only the working dir is captured │
#   │ (you'll see "source.mov: not found" below — the working dir is     │
#   │ still usable for model A/B, just not for re-extraction).           │
#   └────────────────────────────────────────────────────────────────────┘
#
# USAGE:
#   ./Scripts/capture-recording.sh        # start watching, then record in Zerro
#   Ctrl-C when done. Captured dirs land in ./eval-recordings/<name>/
#                                          (working dir contents + source.mov)
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
echo "(for source.mov capture, run the app with -RetainEvalArtifacts YES)"

seen=""        # working dirs already captured
claimed=""     # source .movs already paired to a capture

# Newest zerro-<UUID>.mov in $TMP that hasn't been paired to a capture yet.
# Excludes working dirs (zerro-work-*) — those are directories, but the glob
# would otherwise also list a stray `zerro-work-*.mov` if one ever existed.
# Prints nothing if no unclaimed .mov is present.
newest_unclaimed_mov() {
  # -t sorts by mtime (newest first); the current session's recording was just
  # written, so it sorts ahead of any retained .movs from prior sessions.
  for mov in $(ls -t "$TMP"zerro-*.mov 2>/dev/null); do
    case "$mov" in *zerro-work-*) continue ;; esac
    case "$claimed" in *"$mov"*) continue ;; esac
    echo "$mov"
    return 0
  done
  return 0
}

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

      # Pair the raw source recording, if one survived (retention ON).
      mov=$(newest_unclaimed_mov)
      if [ -n "$mov" ]; then
        cp "$mov" "$DEST/$name/source.mov"
        claimed="$claimed $mov"
        echo "captured: $DEST/$name ($frames frames + source.mov)"
      else
        echo "captured: $DEST/$name ($frames frames; source.mov: not found — set -RetainEvalArtifacts YES)"
      fi
    fi
  done
  sleep 0.5
done
