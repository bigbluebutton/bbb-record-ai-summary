# BigBlueButton AI Playback Development

Local development environment for testing and developing BigBlueButton recording and playback scripts with AI-powered audio transcription.

## Features

- **Audio Transcription**: Uses whisper.cpp to transcribe meeting audio with speaker diarization
- **WebVTT Output**: Generates WebVTT-formatted transcripts with timestamps
- **Smart Segmentation**: Intelligent speaker change detection to create natural conversation segments
- **Multi-speaker Support**: Per-speaker audio track processing with accurate attribution
- **LLM Summarization**: Optional AI-powered meeting summaries using Anthropic Claude

## Quick Start

```bash
# Test a recording
./apply.sh <meeting_id>

# Clean generated files
./clean.sh <meeting_id>

# Compare with server output
./compare.sh <meeting_id>
```

## Documentation

- **[QUICK_REFERENCE.md](QUICK_REFERENCE.md)** - Command cheat sheet
- **[TEST_HARNESS.md](TEST_HARNESS.md)** - Complete usage guide
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - BBB recording system details
- **[SUMMARY.md](SUMMARY.md)** - What was built

## Project Structure

```
├── config/          # Local configuration
├── notes/           # Notes playback scripts
├── recording/       # Test workspace
│   ├── raw/        # Input recordings
│   ├── process/    # Processed output
│   ├── publish/    # Published output
│   └── status/     # Status files
├── logs/           # Processing logs
├── apply.sh        # Run test
├── clean.sh        # Clean output
└── compare.sh      # Validate results
```

## Development Workflow

1. **Edit scripts** in `notes/process/` or `notes/publish/`
2. **Clean previous run**: `./clean.sh <meeting_id>`
3. **Test changes**: `./apply.sh <meeting_id>`
4. **Validate**: `./compare.sh <meeting_id>`
5. **Iterate** as needed

See [TEST_HARNESS.md](TEST_HARNESS.md) for details.

## Transcription Features

### WebVTT Format

Transcripts are generated in WebVTT format (`transcript_diarized.vtt`) with:
- Standard WebVTT header
- Timestamp ranges (HH:MM:SS.mmm --> HH:MM:SS.mmm)
- Speaker attribution (Speaker: text)
- Paragraph-level segmentation

Example:
```
WEBVTT

00:00:00.252 --> 00:00:33.732
Calvin: I'm refactoring how the video reading is working...

00:00:29.423 --> 00:00:53.333
Fred Dixon: All right Calvin, go for it...
```

### Smart Segmentation Logic

The transcription system uses intelligent segmentation to create natural conversation flows:

**How it works:**

1. **Per-Speaker Audio Tracks**: Each participant's audio is transcribed separately with word-level timestamps

2. **Look-Ahead Detection**: When a speaker appears to change, the system looks ahead to count consecutive words:
   - If new speaker has ≥3 consecutive words → confirmed speaker change, output segment
   - If new speaker has <3 words → brief interjection, ignore and continue current segment

3. **Special Token Filtering**: Removes whisper.cpp artifacts:
   - `[_BEG_]`, `[_END_]`, `[_TT_*]` markers
   - `[BLANK_AUDIO]` and fragments (BL, ANK, AUD, IO, etc.)
   - Noise descriptions (keyboard, clicking, etc.)

4. **Timestamp Alignment**: All timestamps are relative to recording start (not meeting start)
   - Accounts for delayed recording start
   - Uses `RecordStatusEvent` with `status=true` as time zero

**Benefits:**
- Natural paragraph-level segments instead of word-by-word fragmentation
- Accurate speaker attribution even with simultaneous speech
- Clean output without technical artifacts
- Compatible with standard video players and caption systems

### Output Files

- `transcript.txt` - Plain text transcription (all speakers combined)
- `transcript_diarized.vtt` - WebVTT format with speaker labels and timestamps
- `notes.md` - Markdown summary with embedded transcript
- `summary.txt` - AI-generated meeting summary (if LLM configured)

## Deployment

### Usage

`deploy.sh` — Deploy ai-summary recording format and post_archive scripts to BigBlueButton
Deployment paths:
  `src/scripts/post_archive/`  → `/usr/local/bigbluebutton/core/scripts/post_archive/`
  `src/ai-summary/process/`           →  /usr/local/bigbluebutton/core/scripts/process/ 
/usr/local/bigbluebutton/core/scripts/publish/
  src/ai-summary/ai-summary.yml           → /usr/local/bigbluebutton/core/scripts/
  src/ai-summary/ai-summary-playback.nginx → /usr/share/bigbluebutton/nginx/
Usage:
  ./deploy.sh [--dry-run]

### After deployment

After the deployment is complete, next step — wire ai-summary into the BBB recording pipeline.
Edit `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml` and update the 'steps' block:

```yml
  steps:
    archive: "sanity"
    sanity: "captions"
    captions:
      - "process:presentation"
      - "process:ai-summary"
    "process:presentation": "publish:presentation"
    "process:ai-summary": "publish:ai-summary"
```

Then restart the recording worker:

```bash
systemctl restart bbb-rap-resque-worker
```

Tip: place a custom transcribe.sh in `/usr/local/bigbluebutton/core/scripts/post_archive/` to override the `whisper.cpp` fallback.

