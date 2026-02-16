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
    echo "Usage: $0 <audio_file> [output_file] [--json|--json-full]"
    echo ""
    echo "Examples:"
    echo "  $0 recording.opus"
    echo "  $0 recording.opus transcript.txt"
    echo "  $0 recording.opus output.json --json-full"
    echo ""
    echo "Output format flags:"
    echo "  (none)       Plain text output (default)"
    echo "  --json       JSON output with timestamps"
    echo "  --json-full  Full JSON output with token-level timestamps"
    echo ""
    echo "Supported formats: wav, mp3, opus, ogg, m4a, flac"
    echo "Note: Non-WAV files will be converted to WAV automatically using ffmpeg"
    echo ""
    echo "Environment variables:"
    echo "  WHISPER_THREADS  Number of threads for whisper.cpp (default: whisper-cli default)"
    exit 1
fi

AUDIO_FILE="$1"
OUTPUT_FILE="${2:-}"
FORMAT_FLAG="${3:-}"

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
    # Determine output mode and file extension based on format flag
    case "$FORMAT_FLAG" in
        --json-full)
            WHISPER_FMT="-ojf"
            AUTO_EXT=".json"
            OUTPUT_BASE="${OUTPUT_FILE%.json}"
            ;;
        --json)
            WHISPER_FMT="-oj"
            AUTO_EXT=".json"
            OUTPUT_BASE="${OUTPUT_FILE%.json}"
            ;;
        *)
            WHISPER_FMT="-otxt"
            AUTO_EXT=".txt"
            OUTPUT_BASE="${OUTPUT_FILE%.txt}"
            ;;
    esac

    # Build whisper command arguments
    WHISPER_ARGS=(-m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en $WHISPER_FMT -of "$OUTPUT_BASE")
    # Add thread count if specified
    if [ -n "$WHISPER_THREADS" ]; then
        WHISPER_ARGS+=(-t "$WHISPER_THREADS")
    fi
    # Only add --no-timestamps for plain text output
    if [ "$FORMAT_FLAG" != "--json-full" ] && [ "$FORMAT_FLAG" != "--json" ]; then
        WHISPER_ARGS+=(--no-timestamps)
    fi

    "$WHISPER_BIN" "${WHISPER_ARGS[@]}" 2>/dev/null

    # whisper.cpp auto-appends the format extension
    GENERATED_FILE="${OUTPUT_BASE}${AUTO_EXT}"
    if [ ! -f "$GENERATED_FILE" ]; then
        echo "Error: Transcription failed"
        [ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
        exit 1
    fi

    # Move to desired output name if different from what whisper.cpp generated
    if [ "$GENERATED_FILE" != "$OUTPUT_FILE" ]; then
        mv "$GENERATED_FILE" "$OUTPUT_FILE"
    fi

    echo "✓ Transcription complete: $OUTPUT_FILE"
else
    # Output to stdout (always plain text)
    WHISPER_ARGS=(-m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -otxt --no-timestamps)
    if [ -n "$WHISPER_THREADS" ]; then
        WHISPER_ARGS+=(-t "$WHISPER_THREADS")
    fi
    "$WHISPER_BIN" "${WHISPER_ARGS[@]}" 2>/dev/null
fi

# Cleanup temp file
[ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
