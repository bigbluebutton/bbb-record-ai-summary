#!/bin/bash

set -euo pipefail

BIGBLUEBUTTON_USER=bigbluebutton

BBB_CORE="/usr/local/bigbluebutton/core"
BBB_SCRIPTS="$BBB_CORE/scripts"
BBB_LIB="$BBB_CORE/lib"
NGINX_DIR="/usr/share/bigbluebutton/nginx"
WHISPER_INSTALL_DIR="/usr/local/bin/whisper.cpp"
WHISPER_MODEL="base"
INSTALL_WHISPER=false
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
POST_ARCHIVE_SRC="$PROJECT_ROOT/src/scripts/post_archive"
POST_PUBLISH_SRC="$PROJECT_ROOT/src/scripts/post_publish"
FORMAT_SRC="$PROJECT_ROOT/src/ai-summary"
DRY_RUN=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --install-whisper) INSTALL_WHISPER=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "=== ai-summary + post_archive deploy ==="
echo "BBB scripts     : $BBB_SCRIPTS"
echo "Nginx dir       : $NGINX_DIR"
$INSTALL_WHISPER && echo "Whisper dir     : $WHISPER_INSTALL_DIR"
$DRY_RUN && echo "(dry run — no files will be written)"
echo ""

# ---------------------------------------------------------------------------
# Require root
# ---------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Root privileges required. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Optionally install whisper.cpp (pass --install-whisper to enable)
# ---------------------------------------------------------------------------
if $INSTALL_WHISPER; then
  WHISPER_BIN=""
  if [ -f "$WHISPER_INSTALL_DIR/build/bin/whisper-cli" ]; then
    WHISPER_BIN="$WHISPER_INSTALL_DIR/build/bin/whisper-cli"
  elif [ -f "$WHISPER_INSTALL_DIR/main" ]; then
    WHISPER_BIN="$WHISPER_INSTALL_DIR/main"
  fi

  if [ -n "$WHISPER_BIN" ]; then
    echo "[whisper.cpp] Already installed: $WHISPER_BIN"
  else
    echo "[whisper.cpp] Not found at $WHISPER_INSTALL_DIR — installing..."

    for pkg in build-essential git cmake ffmpeg; do
      if ! dpkg -l "$pkg" &>/dev/null; then
        echo "  Installing system package: $pkg"
        apt-get install -y -qq "$pkg"
      fi
    done

    if [ -d "$WHISPER_INSTALL_DIR" ]; then
      echo "  Directory exists, pulling latest changes..."
      git -C "$WHISPER_INSTALL_DIR" pull --quiet origin master || true
    else
      echo "  Cloning whisper.cpp..."
      git clone --quiet https://github.com/ggerganov/whisper.cpp.git "$WHISPER_INSTALL_DIR"
    fi

    echo "  Building whisper.cpp..."
    make -C "$WHISPER_INSTALL_DIR" -j"$(nproc)" 2>&1 | tail -5

    if [ -f "$WHISPER_INSTALL_DIR/build/bin/whisper-cli" ]; then
      WHISPER_BIN="$WHISPER_INSTALL_DIR/build/bin/whisper-cli"
      echo "  Build succeeded: $WHISPER_BIN"
    elif [ -f "$WHISPER_INSTALL_DIR/main" ]; then
      WHISPER_BIN="$WHISPER_INSTALL_DIR/main"
      echo "  Build succeeded (legacy): $WHISPER_BIN"
    else
      echo "  ERROR: whisper.cpp build failed."
      exit 1
    fi
  fi

  MODEL_FILE="$WHISPER_INSTALL_DIR/models/ggml-${WHISPER_MODEL}.bin"
  if [ -f "$MODEL_FILE" ]; then
    echo "[whisper.cpp] Model already present: $MODEL_FILE"
  else
    echo "[whisper.cpp] Downloading model '$WHISPER_MODEL'..."
    bash "$WHISPER_INSTALL_DIR/models/download-ggml-model.sh" "$WHISPER_MODEL" 2>&1 \
      || { echo "  ERROR: Model download failed."; exit 1; }
    echo "  Model ready: $MODEL_FILE"
  fi
  echo ""
fi

# ---------------------------------------------------------------------------
# Ensure pandoc + xelatex are installed (for Markdown → PDF conversion)
# ---------------------------------------------------------------------------
echo "--- Checking pandoc + xelatex ---"
PANDOC_PKGS=()
for pkg in pandoc texlive-xetex texlive-fonts-recommended texlive-plain-generic; do
  if ! dpkg -l "$pkg" &>/dev/null; then
    PANDOC_PKGS+=("$pkg")
  fi
done

if [ ${#PANDOC_PKGS[@]} -eq 0 ]; then
  echo "[pandoc] Already installed"
else
  echo "[pandoc] Installing: ${PANDOC_PKGS[*]}"
  if ! $DRY_RUN; then
    apt-get install -y -qq "${PANDOC_PKGS[@]}"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# Deploy post_archive scripts
# ---------------------------------------------------------------------------
echo "--- Deploying post_archive scripts ---"
mkdir -p "$BBB_SCRIPTS/post_archive"

cp -r "$POST_ARCHIVE_SRC/." "$BBB_SCRIPTS/post_archive/"

# ---------------------------------------------------------------------------
# Deploy transcription backends
# ---------------------------------------------------------------------------
echo "--- Deploying transcription backends ---"
TRANSCRIPTION_SRC="$PROJECT_ROOT/src/scripts/transcription"
TRANSCRIPTION_LIB_DIR="$BBB_LIB/transcription"

mkdir -p "$TRANSCRIPTION_LIB_DIR"
cp "$TRANSCRIPTION_SRC"/*.rb      "$TRANSCRIPTION_LIB_DIR"/
cp "$TRANSCRIPTION_SRC/transcription.yml"      "$TRANSCRIPTION_LIB_DIR/transcription.yml"
echo ""

# ---------------------------------------------------------------------------
# Install node-vad (optional — used by albert_whisper for VAD)
# ---------------------------------------------------------------------------
echo "--- Checking node-vad ---"
if command -v npm &>/dev/null; then
  if npm list -g node-vad --depth=0 &>/dev/null 2>&1; then
    echo "[node-vad] Already installed"
  else
    echo "[node-vad] Installing globally..."
    if ! $DRY_RUN; then
      npm install -g node-vad --silent
      echo "[node-vad] Installed"
    else
      echo "[dry-run] npm install -g node-vad"
    fi
  fi
else
  echo "[node-vad] WARNING: npm not found — VAD will be disabled at runtime."
  echo "           Install Node.js then run: npm install -g node-vad"
fi
echo ""

# ---------------------------------------------------------------------------
# Deploy post_publish scripts
# ---------------------------------------------------------------------------
echo "--- Deploying post_publish scripts ---"
mkdir -p "$BBB_SCRIPTS/post_publish"

cp -r "$POST_PUBLISH_SRC/." "$BBB_SCRIPTS/post_publish/"

# ---------------------------------------------------------------------------
# Deploy ai-summary format
# ---------------------------------------------------------------------------
echo "--- Deploying ai-summary format ---"

# Copy the process, publish, lib and template files over to correct places

mkdir -p "$BBB_SCRIPTS/ai-summary"

cp -r "$FORMAT_SRC/process/ai-summary.rb" "$BBB_SCRIPTS/process"
cp -r "$FORMAT_SRC/publish/ai-summary.rb" "$BBB_SCRIPTS/publish"

# Copy lib files to correct place
# /usr/local/bigbluebutton/core/lib/ai-summary
mkdir -p "$BBB_LIB/ai-summary"

cp "$FORMAT_SRC/lib/llm_client.rb" "$BBB_LIB/ai-summary"

# Copy template files to correct place
# /usr/local/bigbluebutton/core/playback/ai-summary
# Includes: ai-summary.md.erb, ai-summary.html.erb, ai-summary.json.erb
mkdir -p "$BBB_CORE/playback/ai-summary"

cp -r "$FORMAT_SRC/templates/." "$BBB_CORE/playback/ai-summary"

# Copy unified config to BBB scripts root.
# ai-summary.yml contains llm and docs sections in addition to format settings.
cp "$FORMAT_SRC/ai-summary.yml" "$BBB_SCRIPTS/ai-summary.yml"

# Install nginx location block
mkdir -p "$NGINX_DIR"
cp "$PROJECT_ROOT/ai-summary-playback.nginx" "$NGINX_DIR/ai-summary.nginx"

# Reload nginx to pick up the new location block
if nginx -t 2>/dev/null; then
  nginx -s reload
  echo "  nginx reloaded"
else
  echo "  WARNING: nginx config test failed — reload skipped. Check $NGINX_DIR/ai-summary.nginx"
fi
echo ""

mkdir -p /var/bigbluebutton/published/ai-summary
chown -R $BIGBLUEBUTTON_USER:$BIGBLUEBUTTON_USER /var/bigbluebutton/published/ai-summary

mkdir -p /var/bigbluebutton/recording/publish/ai-summary
chown -R $BIGBLUEBUTTON_USER:$BIGBLUEBUTTON_USER /var/bigbluebutton/recording/publish/ai-summary

echo ""
echo "To apply your own credentials, copy your local ai-summary.yml to the override location:"
echo "  cp $FORMAT_SRC/ai-summary-override.yml /etc/bigbluebutton/ai-summary.yml"
