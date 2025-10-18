#!/bin/bash
# whisper.cpp Installation Script for Ubuntu 22.04
# This script installs whisper.cpp and downloads the base.en model

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

WHISPER_DIR="$SCRIPT_DIR/whisper.cpp"
MODEL_NAME="base.en"  # Good balance of speed and accuracy for English

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  whisper.cpp Installation for Ubuntu 22.04              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Install dependencies
echo -e "${YELLOW}[1/5]${NC} Installing build dependencies..."
PACKAGES="build-essential git wget cmake pandoc texlive-latex-base texlive-latex-recommended"
MISSING_PACKAGES=""

for pkg in $PACKAGES; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done

if [ -n "$MISSING_PACKAGES" ]; then
    echo "  Installing:$MISSING_PACKAGES"
    sudo apt-get update -qq
    sudo apt-get install -y $MISSING_PACKAGES
    echo -e "  ${GREEN}✓ Dependencies installed${NC}"
else
    echo -e "  ${GREEN}✓ All dependencies already installed${NC}"
fi
echo ""

# Step 2: Clone whisper.cpp
echo -e "${YELLOW}[2/5]${NC} Cloning whisper.cpp repository..."
if [ -d "$WHISPER_DIR" ]; then
    echo -e "  ${YELLOW}Directory already exists, pulling latest changes...${NC}"
    cd "$WHISPER_DIR"
    git pull origin master || echo "  Note: Could not pull latest changes (using existing version)"
    cd "$SCRIPT_DIR"
else
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
    echo -e "  ${GREEN}✓ Repository cloned${NC}"
fi
echo ""

# Step 3: Compile whisper.cpp
echo -e "${YELLOW}[3/5]${NC} Compiling whisper.cpp..."
cd "$WHISPER_DIR"

# Compile with cmake
echo "  Building with cmake..."
make -j$(nproc) 2>&1 | tail -20

# Check for the new binary location (cmake build)
if [ -f "build/bin/whisper-cli" ]; then
    echo -e "  ${GREEN}✓ Compilation successful${NC}"
    echo "    Binary: build/bin/whisper-cli"
# Check for old binary location (legacy build)
elif [ -f "main" ]; then
    echo -e "  ${GREEN}✓ Compilation successful${NC}"
    echo "    Binary: main"
else
    echo -e "  ${RED}✗ Compilation failed${NC}"
    exit 1
fi

cd "$SCRIPT_DIR"
echo ""

# Step 4: Download model
echo -e "${YELLOW}[4/5]${NC} Downloading Whisper model (${MODEL_NAME})..."
MODEL_FILE="$WHISPER_DIR/models/ggml-${MODEL_NAME}.bin"

if [ -f "$MODEL_FILE" ]; then
    echo -e "  ${GREEN}✓ Model already downloaded: ${MODEL_FILE}${NC}"
else
    cd "$WHISPER_DIR"
    # Use the download script provided by whisper.cpp
    bash ./models/download-ggml-model.sh "$MODEL_NAME"
    cd "$SCRIPT_DIR"

    if [ -f "$MODEL_FILE" ]; then
        echo -e "  ${GREEN}✓ Model downloaded successfully${NC}"
        echo "    Model: ${MODEL_FILE}"
        echo "    Size: $(du -h "$MODEL_FILE" | cut -f1)"
    else
        echo -e "  ${RED}✗ Model download failed${NC}"
        exit 1
    fi
fi
echo ""

# Step 5: Create helper script
echo -e "${YELLOW}[5/5]${NC} Creating helper transcription script..."
TRANSCRIBE_SCRIPT="$SCRIPT_DIR/transcribe.sh"

cat > "$TRANSCRIBE_SCRIPT" << 'EOF'
#!/bin/bash
# Helper script to transcribe audio files using whisper.cpp

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WHISPER_DIR="$SCRIPT_DIR/whisper.cpp"

# Check for new cmake build location first, then fall back to legacy
if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
elif [ -f "$WHISPER_DIR/main" ]; then
    WHISPER_BIN="$WHISPER_DIR/main"
else
    WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"  # default assumption
fi

MODEL="$WHISPER_DIR/models/ggml-base.en.bin"

# Check if audio file is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <audio_file> [output_file]"
    echo ""
    echo "Examples:"
    echo "  $0 recording.opus"
    echo "  $0 recording.opus transcript.txt"
    echo ""
    echo "Supported formats: wav, mp3, opus, ogg, m4a, flac"
    echo "Note: Non-WAV files will be converted to WAV automatically using ffmpeg"
    exit 1
fi

AUDIO_FILE="$1"
OUTPUT_FILE="${2:-}"

# Check if audio file exists
if [ ! -f "$AUDIO_FILE" ]; then
    echo "Error: Audio file not found: $AUDIO_FILE"
    exit 1
fi

# Check if whisper is installed
if [ ! -f "$WHISPER_BIN" ]; then
    echo "Error: whisper.cpp not found. Run ./install.sh first"
    exit 1
fi

# Check if model exists
if [ ! -f "$MODEL" ]; then
    echo "Error: Model not found: $MODEL"
    echo "Run ./install.sh to download the model"
    exit 1
fi

# Convert to WAV if needed
TEMP_WAV=""
FILE_EXT="${AUDIO_FILE##*.}"
FILE_EXT_LOWER=$(echo "$FILE_EXT" | tr '[:upper:]' '[:lower:]')

if [ "$FILE_EXT_LOWER" != "wav" ]; then
    echo "Converting $FILE_EXT to WAV format..."
    TEMP_WAV="/tmp/whisper_temp_$(basename "$AUDIO_FILE" .$FILE_EXT).wav"

    # Convert to 16kHz mono WAV (whisper.cpp requirement)
    ffmpeg -i "$AUDIO_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TEMP_WAV" -y 2>/dev/null

    if [ ! -f "$TEMP_WAV" ]; then
        echo "Error: Failed to convert audio file"
        exit 1
    fi

    AUDIO_TO_PROCESS="$TEMP_WAV"
else
    AUDIO_TO_PROCESS="$AUDIO_FILE"
fi

# Run transcription
echo "Transcribing audio with whisper.cpp..."
echo "Audio: $AUDIO_FILE"
echo "Model: base.en"
echo ""

if [ -n "$OUTPUT_FILE" ]; then
    # Output to specified file
    "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -otxt -of "${OUTPUT_FILE%.txt}" --no-timestamps 2>/dev/null

    # whisper.cpp adds .txt extension automatically
    if [ ! -f "${OUTPUT_FILE%.txt}.txt" ]; then
        echo "Error: Transcription failed"
        [ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
        exit 1
    fi

    # Move to desired output name if different
    if [ "${OUTPUT_FILE%.txt}.txt" != "$OUTPUT_FILE" ]; then
        mv "${OUTPUT_FILE%.txt}.txt" "$OUTPUT_FILE"
    fi

    echo "✓ Transcription complete: $OUTPUT_FILE"
else
    # Output to stdout
    "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -otxt --no-timestamps 2>/dev/null
fi

# Cleanup temp file
[ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
EOF

chmod +x "$TRANSCRIBE_SCRIPT"
echo -e "  ${GREEN}✓ Helper script created: transcribe.sh${NC}"
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Installation completed successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Installation details:"
echo "  • whisper.cpp: $WHISPER_DIR"

# Detect which binary was built
if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    echo "  • Executable: $WHISPER_DIR/build/bin/whisper-cli"
    WHISPER_EXAMPLE_BIN="./build/bin/whisper-cli"
elif [ -f "$WHISPER_DIR/main" ]; then
    echo "  • Executable: $WHISPER_DIR/main"
    WHISPER_EXAMPLE_BIN="./main"
else
    echo "  • Executable: Not found"
    WHISPER_EXAMPLE_BIN="./build/bin/whisper-cli"
fi

echo "  • Model: $MODEL_FILE"
echo "  • Model size: $(du -h "$MODEL_FILE" 2>/dev/null | cut -f1 || echo 'unknown')"
echo "  • Helper script: $TRANSCRIBE_SCRIPT"
echo ""
echo "Usage examples:"
echo ""
echo "  1. Direct whisper.cpp usage:"
echo "     cd whisper.cpp"
echo "     $WHISPER_EXAMPLE_BIN -m models/ggml-base.en.bin -f /path/to/audio.wav -l en"
echo ""
echo "  2. Using helper script:"
echo "     ./transcribe.sh recording/raw/<meeting_id>/audio/*.opus"
echo "     ./transcribe.sh audio.opus transcript.txt"
echo ""
echo "  3. Test with sample audio:"
echo "     ./transcribe.sh recording/raw/*/audio/*.opus test_output.txt"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  • Test transcription with: ./transcribe.sh <audio_file>"
echo "  • Integrate into notes/process/notes.rb for automated transcription"
echo ""
