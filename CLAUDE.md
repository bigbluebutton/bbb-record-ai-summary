# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a local development environment for testing BigBlueButton (BBB) recording and playback scripts. It extends the standard BBB "notes" playback format with AI-powered features: audio transcription via whisper.cpp, LLM-generated meeting summaries, and action item extraction. The test harness simulates the BBB recording pipeline without requiring a full BBB server installation.

The playback format is named **`ai-summary`**. Source code lives in `src/ai-summary/`.

## Essential Commands

### Testing Workflow
```bash
# Test a recording (runs process + publish scripts)
./apply.sh <meeting_id>

# Clean generated files before retesting
./clean.sh <meeting_id>

# Preview what clean.sh would delete
./clean.sh --dry-run <meeting_id>

# Compare local output with server output
./compare.sh <meeting_id>
```

### Setup
```bash
# Install dependencies (whisper.cpp, pandoc, texlive, Ruby gems)
./install.sh

# Deploy post_archive scripts to production BBB server (requires root)
./deploy.sh [--dry-run]

# Transcribe an audio file directly (--json outputs segments; --json-full includes word-level timestamps)
./transcribe.sh audio.opus [output.txt] [--json|--json-full]
```

### Viewing Logs
```bash
tail -f logs/ai-summary/process-<meeting_id>.log
tail -f logs/ai-summary/publish-<meeting_id>.log
tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log  # production
```

## Architecture

### BigBlueButton Recording Pipeline

BBB processes recordings through a 6-stage pipeline:
```
Capture → Archive → Sanity → Process → Publish → Playback
```

This project adds a **post_archive** hook (runs after Archive) plus the **Process** and **Publish** stages for the `ai-summary` playback format.

### Post-Archive Stage (`src/scripts/post_archive/transcribe_audio.rb`)
**Trigger:** Runs after BBB archives a recording (registered as a BBB post_archive hook)
**Output:** `recording/raw/<meeting_id>/transcription/transcription.json`

Transcribes all audio tracks found in `recording/raw/<meeting_id>/audio/`. Output format:
```json
{ "meeting_id": "...", "generated_at": "...", "tracks": [
  { "file": "audio_basename", "segments": [{ "offsets": {"from": <ms>, "to": <ms>}, "text": "..." }] }
]}
```

Transcription back-end selection (in order of preference):
1. **Custom script** — `transcribe.sh` placed in the same directory as `transcribe_audio.rb`. Called as: `transcribe.sh <audio_file> <output_json_file>`
2. **whisper.cpp** (built-in fallback) — searched across several known paths; uses the smallest ggml model found. Audio is auto-converted to 16 kHz mono WAV via ffmpeg before passing to whisper.

If `transcription.json` already exists, the script exits early (delete it to re-run).

**Deploy post_archive scripts:**
```bash
./deploy.sh        # copies src/scripts/post_archive/ → /usr/local/bigbluebutton/core/scripts/post_archive/
                   # also installs whisper.cpp to /usr/local/bin/whisper.cpp and downloads base.en model
```

### Process Stage (`src/ai-summary/process/ai-summary.rb`)
**Input:** `recording/raw/<meeting_id>/`
**Output:** `recording/process/ai-summary/<meeting_id>/`

Key operations:
1. Loads config from BBB scripts dir (production) or `src/bigbluebutton.yml` + `src/ai-summary/ai-summary.yml` (dev)
2. Copies original notes file (PDF) to process directory
3. Runs all extractors (defined inline in this file) against raw recording data
4. Renders `ai-summary.md` and `ai-summary.html` from ERB templates
5. Builds `metadata.xml` with state="processed"
6. Creates `.done` status file in `recording/status/processed/`

**Output files:** `ai-summary.pdf`, `ai-summary.md`, `ai-summary.html`, `transcript.txt`, `transcript_diarized.vtt`, `summary.txt`, `action_items.json`, `metadata.xml`

### Publish Stage (`src/ai-summary/publish/ai-summary.rb`)
**Input:** `recording/process/ai-summary/<meeting_id>/`
**Output:** `recording/publish/ai-summary/<meeting_id>/`

Key operations:
1. Converts `ai-summary.md` to PDF via pandoc (falls back to original PDF on failure)
2. Generates updated `metadata.xml` with state="published", playback link, duration
3. Copies to final publish location, then cleans up process and publish dirs
4. Creates `.done` or `.fail` status file in `recording/status/published/`

### Directory Structure
```
bbb-playback-ai/
├── src/
│   ├── ai-summary/                     # ai-summary playback format
│   │   ├── process/ai-summary.rb       # Process stage script (contains all extractors inline)
│   │   ├── publish/ai-summary.rb       # Publish stage script
│   │   ├── lib/
│   │   │   ├── helpers/
│   │   │   │   ├── webvtt_parser.rb    # WebVTT parse/convert (VTT↔SRT)
│   │   │   │   └── markdown_converter.rb
│   │   │   └── llm_client.rb           # Multi-provider LLM abstraction
│   │   ├── templates/
│   │   │   ├── notes.md.erb
│   │   │   └── notes.html.erb
│   │   ├── ai-summary.yml              # Format config (publish_dir, playback_dir, format, whisper_threads)
│   │   ├── llm.yml                     # LLM config (gitignored in production)
│   │   ├── llm.yml.example             # LLM configuration template
│   │   └── ai-summary-playback.nginx   # Nginx location block for playback
│   └── scripts/
│       └── post_archive/
│           └── transcribe_audio.rb     # Post-archive audio transcription hook
├── recording/
│   ├── raw/                            # Input: raw recordings from BBB server
│   ├── process/ai-summary/             # Output: processed files
│   ├── publish/ai-summary/             # Output: published files
│   └── status/                         # Status markers (.done/.fail files)
├── logs/ai-summary/                    # Processing logs
├── whisper.cpp/                        # Audio transcription engine (git submodule, for local dev)
├── apply.sh                            # Main test harness
├── clean.sh                            # Cleanup script
├── compare.sh                          # Validation tool
├── install.sh                          # Dependency installer (local dev)
├── deploy.sh                           # Deploy post_archive scripts to production BBB
└── transcribe.sh                       # whisper.cpp wrapper for local use
```

## Extractor System

All extractors are defined **inline in `src/ai-summary/process/ai-summary.rb`** under the `Extractors` module. There are no separate extractor files — they are not auto-loaded from a separate directory.

Extractors: `Extractors::NotesExtractor`, `Extractors::AttendeesExtractor`, `Extractors::PollsExtractor`, `Extractors::TranscriptExtractor`, `Extractors::SummaryExtractor`, `Extractors::ActionItemsExtractor`.

### TranscriptExtractor
Reads from the pre-computed `transcription.json` file produced by `post_archive/transcribe_audio.rb`. It does **not** invoke whisper directly.

Key behavior:
- Maps audio file basenames to speakers using `AudioTrackPublishedEvent` in `events.xml`
- Uses `BigBlueButton::Events.first_event_timestamp(events_doc)` as recording start time
- Merges segments into WebVTT cues with speaker labels, splitting on speaker change or when cue exceeds `MAX_CUE_CHARS = 200` or `MAX_CUE_DURATION_MS = 15_000`
- Falls back to "Unknown Speaker" if no speaker mapping is found

### SummaryExtractor / ActionItemsExtractor
Both use `LLMClient` for AI features. They degrade gracefully (return nil/empty) when LLM is disabled. `ActionItemsExtractor` returns structured data: `[{owner:, label:, status:}]` where status is `:ok`, `:warn`, or `:pending`.

## LLM Client Architecture

`src/ai-summary/lib/llm_client.rb` uses a factory pattern:
```
LLMClient::Base (abstract)
├── ClaudeClient   — Anthropic API (default model: claude-3-5-sonnet-20241022)
├── OpenAIClient   — OpenAI API (default model: gpt-4o-mini)
└── DisabledClient — no-op, returns nil (used when provider: 'disabled')
```

Create via `LLMClient::Base.create(logger)`. In production, the client reads config from `/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml`. **LLM summarization is production-only** — the client raises an error when run from outside the BBB scripts directory.

**Environment variables** (take priority over config file):
- `ANTHROPIC_API_KEY` — for Claude provider
- `OPENAI_API_KEY` — for OpenAI provider

## Configuration

### Config Files
- `src/ai-summary/ai-summary.yml` — sets `publish_dir`, `playback_dir`, `format` (pdf), `whisper_threads` (default: 4)
- `src/ai-summary/llm.yml` — LLM provider, API keys, model settings, custom `system_prompt` (copy from `llm.yml.example`)
- Production: `bigbluebutton.yml` in BBB scripts dir sets `recording_dir`, `log_dir`, `playback_host`

### Dev vs Production Config Loading
Scripts detect their environment by comparing `__dir__` to `/usr/local/bigbluebutton/core/scripts`:
- **post_archive script** (dev): reads `../../config/bigbluebutton.yml` relative to itself
- **process script** (dev): reads `src/bigbluebutton.yml` and `src/notes.yml` from project root
- **publish script** (dev): reads format config from `src/ai-summary/ai-summary.yml`; always reads bbb props from system path

## Key Implementation Details

### Meeting ID Format
- Process script receives: `<meeting_id>` (e.g., `1b30d714...-1760738236204`)
- Publish script receives: `<meeting_id>-ai-summary` (format suffix appended by BBB)
- Publish script strips suffix with: `meeting_id_with_format.delete_suffix("-ai-summary")` (not a simple last-hyphen split, because the format name itself contains a hyphen)

### Template Rendering
Process stage renders both markdown and HTML via ERB templates. Template path is resolved from `playback_dir` in the format config (not from `src/ai-summary/templates/` directly).

**notes.md.erb** variables: `@notes_content`, `@attendees`, `@polls`, `@transcript`, `@transcript_diarized`, `@summary`, `@word_count`

**notes.html.erb** variables: `@title`, `@subtitle`, `@attendees`, `@attendee_count`, `@word_count`, `@transcript` (WebVTT string), `@shared_notes` (HTML), `@summary`, `@key_points`, `@action_items` (array with owner/label/status), `@footer`

The HTML template uses CSS variables for dark/light theming (`prefers-color-scheme`), color-coded action item status pills, and print-optimized styling.

### BBB Library Utilities
Scripts use the system BBB library (`/usr/local/bigbluebutton/core/lib/recordandplayback`):
- `BigBlueButton.logger` — logging
- `BigBlueButton::Events.get_recording_length(doc)` — recording duration
- `BigBlueButton::Events.get_meeting_metadata(path)` — meeting metadata
- `BigBlueButton::Events.get_num_participants(doc)` — participant count
- `BigBlueButton::Events.first_event_timestamp(doc)` — recording start timestamp (ms)
- `BigBlueButton.add_raw_size_to_metadata(dir, raw_dir)` — raw file sizes
- `BigBlueButton.add_playback_size_to_metadata(dir)` — playback file sizes

### Status Files
- `.done` files in `recording/status/processed/` named `<meeting_id>-ai-summary.done`
- `.done`/`.fail` files in `recording/status/published/` named `<meeting_id>-ai-summary.done/.fail`

### Dependencies
- **System:** whisper.cpp, pandoc + texlive-latex, ffmpeg, xmllint
- **Ruby Gems:** `anthropic`, `openai`, `optimist`, `builder`, `nokogiri`

## Development Workflow

1. **Copy raw recording data** (if needed):
   ```bash
   sudo cp -r /var/bigbluebutton/recording/raw/<meeting_id> ./recording/raw/
   ```

2. **Edit scripts** in `src/ai-summary/process/`, `src/ai-summary/publish/`, `src/ai-summary/lib/`, or `src/ai-summary/templates/`

3. **Clean previous run**: `./clean.sh <meeting_id>`

4. **Test changes**: `./apply.sh <meeting_id>`

5. **Review logs**: Check `logs/ai-summary/` for errors

6. **Deploy to production** (when ready):
   ```bash
   sudo ./deploy.sh   # deploys post_archive scripts
   # Then manually copy process/publish scripts to BBB:
   sudo cp src/ai-summary/process/ai-summary.rb /usr/local/bigbluebutton/core/scripts/process/
   sudo cp src/ai-summary/publish/ai-summary.rb /usr/local/bigbluebutton/core/scripts/publish/
   ```
