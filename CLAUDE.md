# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

This repository implements the **`ai-summary`** recording playback format for BigBlueButton (BBB). It plugs into the standard BBB recording pipeline and adds AI-powered features: audio transcription via whisper.cpp, speaker-labeled WebVTT output, LLM-generated meeting summaries, and action item extraction.

Source code lives in `src/`. The only shell script at the project root is `deploy.sh`, which copies everything to a production BBB server.

## Directory Structure

```
bbb-playback-ai/
├── src/
│   ├── ai-summary/                     # The ai-summary playback format
│   │   ├── process/ai-summary.rb       # BBB process stage (all extractors inline)
│   │   ├── publish/ai-summary.rb       # BBB publish stage
│   │   ├── lib/llm_client.rb           # Multi-provider LLM abstraction
│   │   ├── templates/
│   │   │   ├── ai-summary.md.erb       # Markdown output template
│   │   │   └── ai-summary.html.erb     # HTML output template
│   │   ├── ai-summary.yml              # Format config (publish_dir, playback_dir, format)
│   │   ├── llm.yml                     # LLM config — gitignored in production
│   │   └── llm.yml.example             # Template for llm.yml
│   └── scripts/
│       └── post_archive/
│           └── transcribe_audio.rb     # Post-archive audio transcription hook
├── ai-summary-playback.nginx           # Nginx location block
├── recording/                          # Test workspace (gitignored)
├── logs/                               # Processing logs (gitignored)
└── deploy.sh                           # Deploys to production BBB (requires root)
```

## BBB Recording Pipeline Integration

BBB processes recordings through: **Archive → Sanity → Process → Publish**

This project adds:
- A **post_archive hook** (after Archive): `transcribe_audio.rb` — transcribes all audio tracks
- A **process stage**: `process/ai-summary.rb` — extracts and renders all meeting data
- A **publish stage**: `publish/ai-summary.rb` — converts to PDF, finalizes metadata, copies to publish dir

## Deployment

```bash
./deploy.sh           # deploy to production BBB (requires root, auto-elevates with sudo)
./deploy.sh --dry-run # preview without writing files
```

After deployment, wire `ai-summary` into the pipeline in `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`:
```yaml
steps:
  captions:
    - "process:presentation"
    - "process:ai-summary"
  "process:ai-summary": "publish:ai-summary"
```

## Process Stage (`src/ai-summary/process/ai-summary.rb`)

**Input:** `recording/raw/<meeting_id>/`
**Output:** `recording/process/ai-summary/<meeting_id>/`

Key operations:
1. Loads config (dev or production path, see Config Loading below)
2. Copies original notes PDF to process dir
3. Runs all extractors (defined inline in this file under the `Extractors` module)
4. Renders `ai-summary.md` and `ai-summary.html` from ERB templates
5. Builds `metadata.xml` with `state="processed"`
6. Creates `.done` status file in `recording/status/processed/`

**Output files:** `ai-summary.pdf`, `ai-summary.md`, `ai-summary.html`, `transcript.txt`, `transcript_diarized.vtt`, `summary.txt`, `action_items.json`, `metadata.xml`

### Extractor System

All extractors are defined **inline in `process/ai-summary.rb`** under the `Extractors` module. There are no separate extractor files.

| Extractor | Description |
|---|---|
| `AttendeesExtractor` | Unique participant names from `ParticipantJoinEvent` in events.xml |
| `NotesExtractor` | Shared notes HTML from `notes/notes.html`; counts words |
| `PollsExtractor` | Poll data from `PollPublishedRecordEvent` in events.xml |
| `TranscriptExtractor` | Reads pre-computed `transcription.json`; generates WebVTT and plain text |
| `SummaryExtractor` | LLM-generated summary from notes + transcript |
| `ActionItemsExtractor` | LLM-extracted action items as `[{owner:, label:, status:}]` |

### TranscriptExtractor

Reads `raw/<meeting_id>/transcription/transcription.json` produced by the post_archive script. It does **not** invoke whisper directly.

- Maps audio file basenames to speakers via `AudioTrackPublishedEvent` in `events.xml`
- Uses `BigBlueButton::Events.first_event_timestamp(events_doc)` as the recording start time
- Merges segments into WebVTT cues, splitting on speaker change or when cue exceeds `MAX_CUE_CHARS = 200` or `MAX_CUE_DURATION_MS = 15_000`
- Falls back to `"Unknown Speaker"` if no speaker mapping found

### Template Variables

**`ai-summary.md.erb`**: `@notes_content`, `@word_count`, `@attendees`, `@polls`, `@transcript_diarized` (array of cue hashes), `@transcript` (plain text), `@summary`

**`ai-summary.html.erb`**: `@title`, `@subtitle`, `@attendees`, `@attendee_count`, `@word_count`, `@transcript` (array of cue hashes), `@transcript_format`, `@transcript_title`, `@transcript_open`, `@timestamps_note`, `@shared_notes` (HTML), `@summary`, `@key_points`, `@action_items`, `@footer`

Template path is resolved from `playback_dir` in `ai-summary.yml` (production: `/usr/local/bigbluebutton/core/playback/ai-summary/`).

## Publish Stage (`src/ai-summary/publish/ai-summary.rb`)

**Input:** `recording/process/ai-summary/<meeting_id>/`
**Output:** `recording/publish/ai-summary/<meeting_id>/` → `$publish_dir/<meeting_id>/`

Key operations:
1. Parses meeting ID: strips `-ai-summary` suffix via `delete_suffix` (not a simple last-hyphen split, because the format name contains a hyphen)
2. Early exit if format is not `ai-summary`
3. Converts `ai-summary.md` to PDF with `pandoc --pdf-engine=pdflatex` (falls back to original PDF)
4. Updates `metadata.xml` with `state="published"`, playback link, duration
5. Copies files to final publish dir (`/var/bigbluebutton/published/ai-summary/<meeting_id>/`)
6. Cleans up process and publish staging dirs
7. Creates `.done` or `.fail` status file in `recording/status/published/`

## Post-Archive Stage (`src/scripts/post_archive/transcribe_audio.rb`)

**Trigger:** Registered as a BBB post_archive hook, runs after Archive stage
**Output:** `recording/raw/<meeting_id>/transcription/transcription.json`

Transcription back-end selection (priority order):
1. **Custom script** — `transcribe.sh` placed alongside this script (called as `transcribe.sh <audio_file> <output_json>`)
2. **whisper.cpp** — fallback, searches multiple known paths; converts audio to 16 kHz WAV via ffmpeg

If `transcription.json` already exists, the script exits early (delete it to re-run).

Output format:
```json
{ "meeting_id": "...", "generated_at": "...", "tracks": [
  { "file": "audio_basename.webm", "segments": [
    { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello." }
  ]}
]}
```

## LLM Client (`src/ai-summary/lib/llm_client.rb`)

Factory pattern: `LLMClient::Base.create(logger)` returns the right client.

| Class | Provider |
|---|---|
| `ClaudeClient` | Anthropic API, default model `claude-3-5-sonnet-20241022` |
| `OpenAIClient` | OpenAI API, default model `gpt-4o-mini` |
| `DisabledClient` | No-op, returns nil |

**LLM summarization is production-only** — the client raises an error when `__dir__` is outside `/usr/local/bigbluebutton/core`. Config is read from `/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml`.

Environment variables take priority over config file values:
- `ANTHROPIC_API_KEY` for Claude
- `OPENAI_API_KEY` for OpenAI

## Config Loading

### Process script (`process/ai-summary.rb`)
- **Production** (`__dir__` starts with `/usr/local/bigbluebutton/core/scripts`): reads `bigbluebutton.yml` and `ai-summary.yml` from that dir
- **Development**: reads `src/bigbluebutton.yml` and `src/ai-summary.yml` from project root

### Publish script (`publish/ai-summary.rb`)
- **Always** reads `bigbluebutton.yml` from `/usr/local/bigbluebutton/core/scripts/` (no dev fallback for BBB props)
- **Development**: reads format config from `src/ai-summary/ai-summary.yml`

### Post-archive script (`transcribe_audio.rb`)
- **Production**: reads from `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`
- **Development**: reads from `src/config/bigbluebutton.yml` (relative to `src/scripts/post_archive/`)

## Key Implementation Details

### Meeting ID Format
- Process script receives: `<meeting_id>` (e.g., `1b30d714...-1760738236204`)
- Publish script receives: `<meeting_id>-ai-summary` — strips suffix with `delete_suffix("-ai-summary")`

### Status Files
- Processed: `recording/status/processed/<meeting_id>-ai-summary.done`
- Published: `recording/status/published/<meeting_id>-ai-summary.done` or `.fail`

### BBB Library Utilities
Scripts use the system library at `/usr/local/bigbluebutton/core/lib/recordandplayback`:
- `BigBlueButton.logger`
- `BigBlueButton::Events.get_recording_length(doc)`
- `BigBlueButton::Events.get_meeting_metadata(path)`
- `BigBlueButton::Events.get_num_participants(doc)`
- `BigBlueButton::Events.first_event_timestamp(doc)`
- `BigBlueButton.add_raw_size_to_metadata(dir, raw_dir)`
- `BigBlueButton.add_playback_size_to_metadata(dir)`

### Dependencies
- **System**: whisper.cpp, ffmpeg, pandoc, texlive-latex
- **Ruby gems**: `optimist`, `builder`, `nokogiri`, `anthropic` (optional), `openai` (optional)

## Logging

```bash
# Post-archive transcription
tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log

# Process stage
tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log

# Publish stage
tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log
```
