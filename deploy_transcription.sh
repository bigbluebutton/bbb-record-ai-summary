#!/bin/bash
#
# deploy_transcription.sh — Deploy a transcription back-end script to BBB.
#
# Usage:
#   ./deploy_transcription.sh <provider>  [--dry-run]
#
# Examples:
#   ./deploy_transcription.sh openai
#   ./deploy_transcription.sh albert
#   ./deploy_transcription.sh openai --dry-run
#
# The script copies src/scripts/transcription/<provider>.rb to
#   /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
# creating the directory if needed, and makes the file executable.
#
# Only one transcription back-end is active at a time — each deploy replaces
# the previous transcribe.rb.
#

set -euo pipefail

BBB_CORE="/usr/local/bigbluebutton/core"
TRANSCRIPTION_LIB_DIR="$BBB_CORE/lib/transcription"
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TRANSCRIPTION_SRC="$PROJECT_ROOT/src/scripts/transcription"
DRY_RUN=false
PROVIDER=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --*)       echo "Unknown flag: $arg"; exit 1 ;;
    *)
      if [ -n "$PROVIDER" ]; then
        echo "ERROR: unexpected argument '$arg' (provider already set to '$PROVIDER')"
        exit 1
      fi
      PROVIDER="$arg"
      ;;
  esac
done

if [ -z "$PROVIDER" ]; then
  echo "Usage: $0 <provider> [--dry-run]"
  echo ""
  echo "Available providers:"
  for f in "$TRANSCRIPTION_SRC"/*.rb; do
    [ -f "$f" ] && echo "  $(basename "$f" .rb)"
  done
  exit 1
fi

SRC_FILE="$TRANSCRIPTION_SRC/${PROVIDER}.rb"
DEST_FILE="$TRANSCRIPTION_LIB_DIR/transcribe.rb"

if [ ! -f "$SRC_FILE" ]; then
  echo "ERROR: source file not found: $SRC_FILE"
  echo ""
  echo "Available providers:"
  for f in "$TRANSCRIPTION_SRC"/*.rb; do
    [ -f "$f" ] && echo "  $(basename "$f" .rb)"
  done
  exit 1
fi

# ---------------------------------------------------------------------------
# Require root
# ---------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Root privileges required. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
echo "=== deploy_transcription ==="
echo "Provider : $PROVIDER"
echo "Source   : $SRC_FILE"
echo "Dest     : $DEST_FILE"
$DRY_RUN && echo "(dry run — no files will be written)"
echo ""

if $DRY_RUN; then
  echo "[dry-run] mkdir -p $TRANSCRIPTION_LIB_DIR"
  echo "[dry-run] cp $SRC_FILE $DEST_FILE"
  [ -f "$TRANSCRIPTION_SRC/transcription.yml" ] && echo "[dry-run] cp $TRANSCRIPTION_SRC/transcription.yml $TRANSCRIPTION_LIB_DIR"
  echo "[dry-run] chmod +x $DEST_FILE"
else
  mkdir -p "$TRANSCRIPTION_LIB_DIR"
  cp "$SRC_FILE" "$DEST_FILE"
  if [ -f "$TRANSCRIPTION_SRC/transcription.yml" ]; then
    cp "$TRANSCRIPTION_SRC/transcription.yml" "$TRANSCRIPTION_LIB_DIR"
  fi
  chmod +x "$DEST_FILE"
  echo "Deployed: $DEST_FILE"
fi

echo ""
echo "Done. transcribe_audio.rb will now use '$PROVIDER' as its transcription back-end."
