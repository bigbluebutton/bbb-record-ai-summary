#!/bin/bash
#
# Test harness for the ai-summary recording pipeline.
#
# Runs the full pipeline (transcription → process → publish) using the
# dev-mode paths that the scripts already support, with a local workspace.
#
# On a non-BBB machine, run --setup-only first to install the shim library
# and create the BBB directory tree.
#
# Usage:
#   ./test/run_pipeline.sh <recording.tar.gz> [options]
#   ./test/run_pipeline.sh --setup-only
#   ./test/run_pipeline.sh --teardown
#
# Options:
#   --skip-transcription   Skip the post_archive transcription step
#   --skip-llm             Disable LLM summarization (sets provider=disabled)
#   --clean                Wipe workspace before running
#   --setup-only           Create the BBB directory tree with shim (non-BBB only)
#   --teardown             Remove the shim BBB directory tree
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BBB_CORE="/usr/local/bigbluebutton/core"
BBB_LIB="$BBB_CORE/lib"
BBB_SCRIPTS="$BBB_CORE/scripts"
BBB_PLAYBACK="$BBB_CORE/playback"

WORKSPACE="$PROJECT_ROOT/recording"
LOG_DIR="$PROJECT_ROOT/logs"

# Source scripts (dev-mode paths)
PROCESS_SCRIPT="$PROJECT_ROOT/src/ai-summary/process/ai-summary.rb"
PUBLISH_SCRIPT="$PROJECT_ROOT/src/ai-summary/publish/ai-summary.rb"
TRANSCRIBE_SCRIPT="$PROJECT_ROOT/src/scripts/post_archive/transcribe_audio.rb"

# ---------------------------------------------------------------------------
# Detect whether this is a BBB server
# ---------------------------------------------------------------------------
is_bbb_server() {
  [ -f "$BBB_LIB/recordandplayback.rb" ] && ! [ -L "$BBB_LIB/recordandplayback.rb" ]
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TARBALL=""
SKIP_TRANSCRIPTION=false
SKIP_LLM=false
CLEAN=false
SETUP_ONLY=false
TEARDOWN=false

for arg in "$@"; do
  case "$arg" in
    --skip-transcription) SKIP_TRANSCRIPTION=true ;;
    --skip-llm)           SKIP_LLM=true ;;
    --clean)              CLEAN=true ;;
    --setup-only)         SETUP_ONLY=true ;;
    --teardown)           TEARDOWN=true ;;
    -h|--help)
      head -24 "$0" | tail -22
      exit 0
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
    *)
      if [ -z "$TARBALL" ]; then
        TARBALL="$arg"
      else
        echo "Unexpected argument: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Teardown (non-BBB only)
# ---------------------------------------------------------------------------
if $TEARDOWN; then
  if is_bbb_server; then
    echo "ERROR: This is a BBB server. --teardown would remove production files." >&2
    echo "       Use 'sudo apt install --reinstall bbb-record-core' instead." >&2
    exit 1
  fi
  echo "=== Tearing down shim BBB directory tree ==="
  if [ -d "$BBB_CORE" ]; then
    echo "Removing $BBB_CORE (requires sudo)..."
    sudo rm -rf "$BBB_CORE"
    echo "Done."
  else
    echo "Nothing to remove — $BBB_CORE does not exist."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Setup: create the BBB directory tree with shim (non-BBB machines only)
# ---------------------------------------------------------------------------
setup_bbb_tree() {
  if is_bbb_server; then
    echo "This is a BBB server — the real recordandplayback library is installed."
    echo "No setup needed. The scripts will use the existing BBB environment."
    return 0
  fi

  echo "=== Setting up BBB directory tree with shim ==="
  echo "Creating directory tree at $BBB_CORE (requires sudo)..."

  # Create directories
  sudo mkdir -p "$BBB_LIB/ai-summary"
  sudo mkdir -p "$BBB_LIB/transcription"
  sudo mkdir -p "$BBB_SCRIPTS/process"
  sudo mkdir -p "$BBB_SCRIPTS/publish"
  sudo mkdir -p "$BBB_SCRIPTS/post_archive"
  sudo mkdir -p "$BBB_SCRIPTS/post_publish"
  sudo mkdir -p "$BBB_PLAYBACK"

  # Shim library (the key piece — replaces BBB's recordandplayback)
  sudo ln -sfn "$PROJECT_ROOT/test/lib/recordandplayback.rb" "$BBB_LIB/recordandplayback.rb"
  echo "  [shim]    recordandplayback.rb → test/lib/recordandplayback.rb"

  # LLM client (must be under BBB_CORE so __dir__ passes production check)
  sudo ln -sfn "$PROJECT_ROOT/src/ai-summary/lib/llm_client.rb" "$BBB_LIB/ai-summary/llm_client.rb"
  echo "  [symlink] lib/ai-summary/llm_client.rb"

  # Transcription providers
  for f in openai_whisper.rb albert_whisper.rb transcription_utils.rb; do
    sudo ln -sfn "$PROJECT_ROOT/src/scripts/transcription/$f" "$BBB_LIB/transcription/$f"
    echo "  [symlink] lib/transcription/$f"
  done

  # Transcription config (copy, not symlink — may be modified locally)
  if [ ! -f "$BBB_LIB/transcription/transcription.yml" ]; then
    sudo cp "$PROJECT_ROOT/src/scripts/transcription/transcription.yml" "$BBB_LIB/transcription/transcription.yml"
    sudo chmod 644 "$BBB_LIB/transcription/transcription.yml"
    echo "  [copy]    lib/transcription/transcription.yml"
  else
    echo "  [exists]  lib/transcription/transcription.yml (not overwritten)"
  fi

  # Scripts (symlinked so __dir__ resolves to BBB path → production mode)
  sudo ln -sfn "$PROCESS_SCRIPT"    "$BBB_SCRIPTS/process/ai-summary.rb"
  sudo ln -sfn "$PUBLISH_SCRIPT"    "$BBB_SCRIPTS/publish/ai-summary.rb"
  sudo ln -sfn "$TRANSCRIBE_SCRIPT" "$BBB_SCRIPTS/post_archive/transcribe_audio.rb"
  sudo ln -sfn "$PROJECT_ROOT/src/scripts/post_publish/publish_to_docs.rb" "$BBB_SCRIPTS/post_publish/publish_to_docs.rb"
  echo "  [symlink] scripts/{process,publish,post_archive,post_publish}/*.rb"

  # Config: ai-summary.yml (copy + patch publish_dir and playback_dir for local workspace)
  sudo cp "$PROJECT_ROOT/src/ai-summary/ai-summary.yml" "$BBB_SCRIPTS/ai-summary.yml"
  sudo sed -i "s|^publish_dir:.*|publish_dir: $PROJECT_ROOT/published/ai-summary|" "$BBB_SCRIPTS/ai-summary.yml"
  sudo sed -i "s|^playback_dir:.*|playback_dir: $BBB_PLAYBACK/ai-summary|" "$BBB_SCRIPTS/ai-summary.yml"
  echo "  [copy]    scripts/ai-summary.yml (patched for local workspace)"

  # Config: bigbluebutton.yml (generated, points to local workspace)
  cat <<YAML | sudo tee "$BBB_SCRIPTS/bigbluebutton.yml" > /dev/null
# Generated by test/run_pipeline.sh — points to local workspace
recording_dir: $WORKSPACE
log_dir: $LOG_DIR
published_dir: $WORKSPACE/publish
events_dir: $WORKSPACE/events
captions_dir: $WORKSPACE/captions
playback_host: localhost
playback_protocol: https
YAML
  echo "  [generate] scripts/bigbluebutton.yml"

  # Templates
  sudo ln -sfn "$PROJECT_ROOT/src/ai-summary/templates" "$BBB_PLAYBACK/ai-summary"
  echo "  [symlink] playback/ai-summary → src/ai-summary/templates/"

  echo ""
  echo "BBB directory tree ready at $BBB_CORE"
}

# ---------------------------------------------------------------------------
# Create local workspace directories
# ---------------------------------------------------------------------------
setup_workspace() {
  mkdir -p "$WORKSPACE/raw"
  mkdir -p "$WORKSPACE/process/ai-summary"
  mkdir -p "$WORKSPACE/publish/ai-summary"
  mkdir -p "$WORKSPACE/status/processed"
  mkdir -p "$WORKSPACE/status/published"
  mkdir -p "$LOG_DIR/ai-summary"
}

# ---------------------------------------------------------------------------
# Ensure dev-mode config files exist
# ---------------------------------------------------------------------------
setup_dev_configs() {
  # src/bigbluebutton.yml — read by process and publish scripts in dev mode
  local bbb_yml="$PROJECT_ROOT/src/bigbluebutton.yml"
  if [ ! -f "$bbb_yml" ]; then
    cat > "$bbb_yml" <<YAML
recording_dir: $WORKSPACE
log_dir: $LOG_DIR
published_dir: $WORKSPACE/publish
playback_host: localhost
playback_protocol: https
YAML
    echo "  Created $bbb_yml"
  fi

  # src/config/bigbluebutton.yml — read by transcribe_audio.rb in dev mode
  mkdir -p "$PROJECT_ROOT/src/config"
  local config_bbb_yml="$PROJECT_ROOT/src/config/bigbluebutton.yml"
  if [ ! -f "$config_bbb_yml" ]; then
    cat > "$config_bbb_yml" <<YAML
recording_dir: $WORKSPACE
log_dir: $LOG_DIR
YAML
    echo "  Created $config_bbb_yml"
  fi

  # src/lib/ai-summary/llm_client.rb — process script resolves llm_client.rb
  # relative to __FILE__ (3 levels up → lib/ai-summary/llm_client.rb)
  # In dev mode that resolves to src/lib/ai-summary/ so we symlink it
  mkdir -p "$PROJECT_ROOT/src/lib/ai-summary"
  ln -sfn "$PROJECT_ROOT/src/ai-summary/lib/llm_client.rb" "$PROJECT_ROOT/src/lib/ai-summary/llm_client.rb"

  # src/ai-summary.yml — read by process script in dev mode
  local ai_yml="$PROJECT_ROOT/src/ai-summary.yml"
  if [ ! -f "$ai_yml" ]; then
    # Copy from the tracked config, override paths for local workspace
    cp "$PROJECT_ROOT/src/ai-summary/ai-summary.yml" "$ai_yml"
    sed -i "s|^playback_dir:.*|playback_dir: $PROJECT_ROOT/src/ai-summary/templates|" "$ai_yml"
    sed -i "s|^publish_dir:.*|publish_dir: $PROJECT_ROOT/published/ai-summary|" "$ai_yml"
    echo "  Created $ai_yml (patched for local workspace)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Handle --setup-only
if $SETUP_ONLY; then
  setup_bbb_tree
  echo ""
  echo "Setup complete. Run again with a tarball to process a recording."
  exit 0
fi

# Validate tarball argument
if [ -z "$TARBALL" ]; then
  echo "Usage: $0 <recording.tar.gz> [--skip-transcription] [--skip-llm] [--clean]" >&2
  echo "       $0 --setup-only" >&2
  echo "       $0 --teardown" >&2
  exit 1
fi

if [ ! -f "$TARBALL" ]; then
  # Try in test-recordings/
  if [ -f "$PROJECT_ROOT/test-recordings/$TARBALL" ]; then
    TARBALL="$PROJECT_ROOT/test-recordings/$TARBALL"
  else
    echo "ERROR: File not found: $TARBALL" >&2
    exit 1
  fi
fi

# On a non-BBB machine, ensure the shim tree is set up
if ! is_bbb_server; then
  if [ ! -f "$BBB_LIB/recordandplayback.rb" ]; then
    echo "No BBB library found. Running first-time setup..."
    echo ""
    setup_bbb_tree
    echo ""
  fi
fi

# Determine which scripts to run and how to invoke ruby
if is_bbb_server; then
  # BBB server: run via dev-mode paths (scripts detect dev via __dir__)
  # Must use bundle exec from BBB core dir since the real library needs gems like redis
  RUN_PROCESS="$PROCESS_SCRIPT"
  RUN_PUBLISH="$PUBLISH_SCRIPT"
  RUN_TRANSCRIBE="$TRANSCRIBE_SCRIPT"
  RUBY_CMD="cd $BBB_CORE && bundle exec ruby"
  echo "Detected BBB server — using dev-mode script paths (bundle exec)"
else
  # Non-BBB: run via the BBB tree (scripts see production __dir__, use shim)
  RUN_PROCESS="$BBB_SCRIPTS/process/ai-summary.rb"
  RUN_PUBLISH="$BBB_SCRIPTS/publish/ai-summary.rb"
  RUN_TRANSCRIBE="$BBB_SCRIPTS/post_archive/transcribe_audio.rb"
  RUBY_CMD="ruby"
fi

# Extract meeting ID from tarball name (strip path and .tar.gz)
TARBALL_BASENAME="$(basename "$TARBALL")"
MEETING_ID="${TARBALL_BASENAME%.tar.gz}"

echo ""
echo "=== ai-summary test pipeline ==="
echo "Recording:  $MEETING_ID"
echo "Tarball:    $TARBALL"
echo "Workspace:  $WORKSPACE"
echo "Logs:       $LOG_DIR/ai-summary/"
echo ""

# Clean workspace if requested
if $CLEAN; then
  echo "--- Cleaning workspace ---"
  rm -rf "$WORKSPACE/raw/$MEETING_ID"
  rm -rf "$WORKSPACE/process/ai-summary/$MEETING_ID"
  rm -rf "$WORKSPACE/publish/ai-summary/$MEETING_ID"
  rm -f "$WORKSPACE/status/processed/${MEETING_ID}-ai-summary.done"
  rm -f "$WORKSPACE/status/published/${MEETING_ID}-ai-summary.done"
  rm -f "$WORKSPACE/status/published/${MEETING_ID}-ai-summary.fail"
  echo ""
fi

setup_workspace

# On BBB server, ensure dev config files exist
if is_bbb_server; then
  setup_dev_configs
fi

# ---------------------------------------------------------------------------
# Unpack tarball
# ---------------------------------------------------------------------------
if [ -d "$WORKSPACE/raw/$MEETING_ID" ]; then
  echo "--- Raw recording already unpacked, skipping ---"
else
  echo "--- Unpacking tarball ---"
  tar xzf "$TARBALL" -C "$WORKSPACE/raw/"
  echo "Unpacked to $WORKSPACE/raw/$MEETING_ID"
fi
echo ""

# ---------------------------------------------------------------------------
# Stage 1: Transcription (post_archive)
# ---------------------------------------------------------------------------
TRANSCRIPTION_FILE="$WORKSPACE/raw/$MEETING_ID/transcription/transcription.json"

if $SKIP_TRANSCRIPTION; then
  echo "--- Skipping transcription (--skip-transcription) ---"
  if [ ! -f "$TRANSCRIPTION_FILE" ]; then
    echo "WARNING: No transcription.json found in recording. Process stage will fail."
  fi
elif [ -f "$TRANSCRIPTION_FILE" ]; then
  echo "--- Transcription already exists, skipping ---"
  echo "    (delete $TRANSCRIPTION_FILE to force re-transcription)"
else
  echo "--- Running transcription (post_archive) ---"
  eval $RUBY_CMD "$RUN_TRANSCRIBE" -m "$MEETING_ID"
fi
echo ""

# ---------------------------------------------------------------------------
# Clear previous process/publish output so scripts don't skip
# ---------------------------------------------------------------------------
rm -rf "$WORKSPACE/process/ai-summary/$MEETING_ID"
rm -f "$WORKSPACE/status/processed/${MEETING_ID}-ai-summary.done"
rm -rf "$WORKSPACE/publish/ai-summary/$MEETING_ID"
rm -f "$WORKSPACE/status/published/${MEETING_ID}-ai-summary.done"
rm -f "$WORKSPACE/status/published/${MEETING_ID}-ai-summary.fail"

# ---------------------------------------------------------------------------
# Stage 2: Process
# ---------------------------------------------------------------------------
echo "--- Running process stage ---"

if $SKIP_LLM; then
  # Create a temporary override to disable LLM
  OVERRIDE_DIR="/etc/bigbluebutton"
  OVERRIDE_FILE="$OVERRIDE_DIR/ai-summary.yml"
  CREATED_OVERRIDE=false

  if [ ! -f "$OVERRIDE_FILE" ]; then
    sudo mkdir -p "$OVERRIDE_DIR"
    printf "llm:\n  provider: disabled\n" | sudo tee "$OVERRIDE_FILE" > /dev/null
    CREATED_OVERRIDE=true
    echo "  (LLM disabled via temporary override)"
  else
    if ! grep -q "provider:" "$OVERRIDE_FILE" 2>/dev/null; then
      echo "WARNING: --skip-llm requested but $OVERRIDE_FILE exists without llm.provider."
      echo "         Add 'llm: { provider: disabled }' manually or remove the file."
    fi
  fi
fi

eval $RUBY_CMD "$RUN_PROCESS" -m "$MEETING_ID"
echo ""

# ---------------------------------------------------------------------------
# Stage 3: Publish
# ---------------------------------------------------------------------------
echo "--- Running publish stage ---"
eval $RUBY_CMD "$RUN_PUBLISH" -m "${MEETING_ID}-ai-summary"
echo ""

# Clean up temporary override if we created it
if $SKIP_LLM && [ "${CREATED_OVERRIDE:-false}" = "true" ]; then
  sudo rm -f "$OVERRIDE_FILE"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
PUBLISH_DIR="$PROJECT_ROOT/published/ai-summary/$MEETING_ID"

echo "=== Pipeline complete ==="
echo ""

if [ -d "$PUBLISH_DIR" ]; then
  echo "Output files in $PUBLISH_DIR:"
  ls -lh "$PUBLISH_DIR/"
else
  echo "WARNING: No output directory found. Check logs at:"
  echo "  $LOG_DIR/ai-summary/process-${MEETING_ID}.log"
  echo "  $LOG_DIR/ai-summary/publish-${MEETING_ID}.log"
fi

echo ""
echo "Logs:"
for stage in process publish; do
  logfile="$LOG_DIR/ai-summary/${stage}-${MEETING_ID}.log"
  if [ -f "$logfile" ]; then
    echo "  $logfile"
  fi
done
