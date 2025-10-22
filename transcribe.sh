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
    echo "  $0 recording.opus transcript.json --json"
    echo "  $0 recording.opus transcript.json --json-full"
    echo ""
    echo "Supported formats: wav, mp3, opus, ogg, m4a, flac, webm"
    echo "Note: Non-WAV files will be converted to WAV automatically using ffmpeg"
    echo "Options:"
    echo "  --json       Output JSON format with timestamps"
    echo "  --json-full  Output JSON format with word-level timestamps"
    exit 1
fi

AUDIO_FILE="$1"
OUTPUT_FILE="${2:-}"
JSON_MODE=false
JSON_FULL_MODE=false

# Check for --json or --json-full flag in arguments
if [ "$3" = "--json-full" ] || [ "$2" = "--json-full" ]; then
    JSON_MODE=true
    JSON_FULL_MODE=true
    # If flag is second arg, clear output file
    if [ "$2" = "--json-full" ]; then
        OUTPUT_FILE=""
    fi
elif [ "$3" = "--json" ] || [ "$2" = "--json" ]; then
    JSON_MODE=true
    # If --json is second arg, clear output file
    if [ "$2" = "--json" ]; then
        OUTPUT_FILE=""
    fi
fi

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
    if [ "$JSON_MODE" = true ]; then
        # JSON mode with timestamps for diarization
        OUTPUT_BASE="${OUTPUT_FILE%.json}"

        # Use full JSON format if requested (includes word-level timestamps)
        if [ "$JSON_FULL_MODE" = true ]; then
            "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -ojf -of "$OUTPUT_BASE" 2>/dev/null
        else
            "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -oj -of "$OUTPUT_BASE" 2>/dev/null
        fi

        # whisper.cpp adds .json extension automatically
        if [ ! -f "${OUTPUT_BASE}.json" ]; then
            echo "Error: Transcription failed"
            [ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
            exit 1
        fi

        # Move to desired output name if different
        if [ "${OUTPUT_BASE}.json" != "$OUTPUT_FILE" ]; then
            mv "${OUTPUT_BASE}.json" "$OUTPUT_FILE"
        fi
    else
        # Plain text mode without timestamps
        OUTPUT_BASE="${OUTPUT_FILE%.txt}"
        "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -otxt -of "$OUTPUT_BASE" --no-timestamps 2>/dev/null

        # whisper.cpp adds .txt extension automatically
        if [ ! -f "${OUTPUT_BASE}.txt" ]; then
            echo "Error: Transcription failed"
            [ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
            exit 1
        fi

        # Move to desired output name if different
        if [ "${OUTPUT_BASE}.txt" != "$OUTPUT_FILE" ]; then
            mv "${OUTPUT_BASE}.txt" "$OUTPUT_FILE"
        fi
    fi

    echo "✓ Transcription complete: $OUTPUT_FILE"
else
    # Output to stdout
    if [ "$JSON_MODE" = true ]; then
        if [ "$JSON_FULL_MODE" = true ]; then
            "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -ojf 2>/dev/null
        else
            "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -oj 2>/dev/null
        fi
    else
        "$WHISPER_BIN" -m "$MODEL" -f "$AUDIO_TO_PROCESS" -l en -otxt --no-timestamps 2>/dev/null
    fi
fi

# Cleanup temp file
[ -n "$TEMP_WAV" ] && rm -f "$TEMP_WAV"
