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
#   --force-retranscribe   Clean + delete transcription.json to force full reprocessing
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
FORCE_RETRANSCRIBE=false
SETUP_ONLY=false
TEARDOWN=false

for arg in "$@"; do
  case "$arg" in
    --skip-transcription) SKIP_TRANSCRIPTION=true ;;
    --skip-llm)           SKIP_LLM=true ;;
    --clean)              CLEAN=true ;;
    --force-retranscribe) CLEAN=true; FORCE_RETRANSCRIBE=true ;;
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

# Delete pre-existing transcription.json to force re-transcription
if $FORCE_RETRANSCRIBE; then
  rm -f "$WORKSPACE/raw/$MEETING_ID/transcription/transcription.json"
  echo "  (--force-retranscribe: deleted existing transcription.json)"
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
# Web preview: copy processed output to web-accessible assets dir
# ---------------------------------------------------------------------------
ASSETS_DIR="/var/www/bigbluebutton-default/assets"
PROCESS_DIR="$WORKSPACE/process/ai-summary/$MEETING_ID"

if [ -d "$ASSETS_DIR" ] && [ -d "$PROCESS_DIR" ]; then
  # Get the server's external hostname
  PREVIEW_HOST=$(hostname -f)

  # Verify HTTPS is reachable
  if curl -sk --connect-timeout 3 "https://$PREVIEW_HOST/" >/dev/null 2>&1; then
    echo "--- Publishing web preview ---"
    PREVIEW_OUT="$ASSETS_DIR/$MEETING_ID"
    sudo rm -rf "$PREVIEW_OUT"
    sudo cp -r "$PROCESS_DIR" "$PREVIEW_OUT"
    sudo chmod -R a+r "$PREVIEW_OUT"

    # Generate index.html with file listing and inline text viewer
    sudo bash -c "cat > '$PREVIEW_OUT/index.html'" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Summary Preview</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; color: #333; }
  h1 { font-size: 1.4rem; border-bottom: 1px solid #ddd; padding-bottom: 0.5rem; }
  .meeting-id { font-size: 0.8rem; color: #888; word-break: break-all; }
  .files { list-style: none; padding: 0; }
  .files li { padding: 0.5rem 0; border-bottom: 1px solid #f0f0f0; display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
  .file-links { display: flex; gap: 0.75rem; align-items: center; }
  .files a { text-decoration: none; color: #0066cc; font-weight: 500; }
  .files a:hover { text-decoration: underline; }
  .view-link { font-size: 0.85rem; font-weight: 400 !important; color: #666 !important; cursor: pointer; }
  .view-link:hover { color: #0066cc !important; }
  .size { color: #888; font-size: 0.85rem; white-space: nowrap; }
  .primary { background: #f0f7ff; padding: 0.75rem; border-radius: 6px; margin-bottom: 1rem; }
  .primary a { font-size: 1.1rem; }
  #viewer { display: none; margin-top: 1rem; }
  #viewer-header { display: flex; justify-content: space-between; align-items: center; background: #f5f5f5; padding: 0.5rem 1rem; border-radius: 6px 6px 0 0; border: 1px solid #ddd; border-bottom: none; }
  #viewer-header span { font-weight: 600; font-size: 0.95rem; }
  #viewer-close { background: none; border: 1px solid #ccc; border-radius: 4px; padding: 0.25rem 0.75rem; cursor: pointer; font-size: 0.85rem; }
  #viewer-close:hover { background: #eee; }
  #viewer-content { background: #fafafa; border: 1px solid #ddd; border-radius: 0 0 6px 6px; padding: 1rem; overflow-x: auto; max-height: 70vh; overflow-y: auto; white-space: pre-wrap; word-wrap: break-word; font-family: monospace; font-size: 0.85rem; line-height: 1.5; }
</style>
</head>
<body>
<div id="file-list"></div>
<div id="viewer">
  <div id="viewer-header">
    <span id="viewer-title"></span>
    <button id="viewer-close" onclick="closeViewer()">Close</button>
  </div>
  <pre id="viewer-content"></pre>
</div>
<script>
const TEXT_EXTENSIONS = ['.json', '.vtt', '.txt', '.xml', '.md'];
function isTextFile(name) {
  return TEXT_EXTENSIONS.some(ext => name.endsWith(ext));
}
function viewFile(name) {
  fetch(name).then(r => r.text()).then(text => {
    document.getElementById('viewer-title').textContent = name;
    document.getElementById('viewer-content').textContent = text;
    document.getElementById('viewer').style.display = 'block';
    document.getElementById('viewer').scrollIntoView({ behavior: 'smooth' });
  });
}
function closeViewer() {
  document.getElementById('viewer').style.display = 'none';
}
</script>
</body>
</html>
HTMLEOF

    # Build the file list dynamically
    sudo bash -c "
      CONTENT='<h1>AI Summary Preview</h1>'
      CONTENT=\"\${CONTENT}<p class=\\\"meeting-id\\\">$MEETING_ID</p>\"

      if [ -f '$PREVIEW_OUT/ai-summary.html' ]; then
        CONTENT=\"\${CONTENT}<div class=\\\"primary\\\"><a href=\\\"ai-summary.html\\\">ai-summary.html</a> — HTML report (open this first)</div>\"
      fi

      CONTENT=\"\${CONTENT}<ul class=\\\"files\\\">\"
      for f in '$PREVIEW_OUT'/*; do
        fname=\$(basename \"\$f\")
        [ \"\$fname\" = \"index.html\" ] && continue
        fsize=\$(du -h \"\$f\" | cut -f1)
        case \"\$fname\" in
          *.json|*.vtt|*.txt|*.xml|*.md)
            CONTENT=\"\${CONTENT}<li><span class=\\\"file-links\\\"><a href=\\\"\$fname\\\" download>\$fname</a><a class=\\\"view-link\\\" onclick=\\\"viewFile('\$fname')\\\">[view]</a></span><span class=\\\"size\\\">\$fsize</span></li>\"
            ;;
          *)
            CONTENT=\"\${CONTENT}<li><span class=\\\"file-links\\\"><a href=\\\"\$fname\\\">\$fname</a></span><span class=\\\"size\\\">\$fsize</span></li>\"
            ;;
        esac
      done
      CONTENT=\"\${CONTENT}</ul>\"

      # Insert content before the viewer div
      sed -i 's|<div id=\"file-list\"></div>|<div id=\"file-list\">'\"\$CONTENT\"'</div>|' '$PREVIEW_OUT/index.html'
    "

    PREVIEW_URL="https://$PREVIEW_HOST/$MEETING_ID/index.html"
    echo "  Preview: $PREVIEW_URL"
    echo ""
  fi
fi

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

# Print preview URL again at the end for easy access
if [ -n "${PREVIEW_URL:-}" ]; then
  echo ""
  echo "Web preview: $PREVIEW_URL"
fi

echo ""
echo "Logs:"
for stage in process publish; do
  logfile="$LOG_DIR/ai-summary/${stage}-${MEETING_ID}.log"
  if [ -f "$logfile" ]; then
    echo "  $logfile"
  fi
done
