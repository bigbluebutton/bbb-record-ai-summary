# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a local development environment for testing BigBlueButton (BBB) recording and playback scripts. It extends the standard BBB "notes" playback format with AI-powered features: audio transcription via whisper.cpp, LLM-generated meeting summaries, and action item extraction. The test harness simulates the BBB recording pipeline without requiring a full BBB server installation.

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

# Transcribe an audio file directly
./transcribe.sh audio.opus [output.txt] [--json|--json-full]

# Test LLM API configuration
ruby test_llm.rb
```

### Listing Available Recordings
```bash
ls recording/raw/
```

### Viewing Logs
```bash
tail -f logs/notes/process-<meeting_id>.log
tail -f logs/notes/publish-<meeting_id>.log
```

## Architecture

### BigBlueButton Recording Pipeline

BBB processes recordings through a 6-stage pipeline:
```
Capture → Archive → Sanity → Process → Publish → Playback
```

This test harness focuses on the **Process** and **Publish** stages for the "notes" playback format.

### Process Stage (notes/process/notes.rb)
**Input:** `recording/raw/<meeting_id>/` (raw recording data from BBB)
**Output:** `recording/process/notes/<meeting_id>/`

Key operations:
1. Loads configuration from `config/bigbluebutton.yml` and `config/notes.yml`
2. Copies original notes file (PDF) to process directory
3. Runs all extractors against raw recording data:
   - **NotesExtractor** — shared notes text and word count from `notes.html`
   - **AttendeesExtractor** — unique participant names from `events.xml`
   - **TranscriptExtractor** — per-speaker audio transcription via whisper.cpp
   - **PollsExtractor** — poll questions and results from `events.xml`
   - **SummaryExtractor** — LLM-generated meeting summary (optional)
   - **ActionItemsExtractor** — LLM-extracted action items (optional)
4. Parses WebVTT transcript into structured cues
5. Renders `notes.md` from ERB template with all extracted data
6. Renders `notes.html` (responsive HTML5 with dark/light mode, interactive transcript)
7. Builds `metadata.xml` with state="processed", timing, participants, word count
8. Creates `.done` status file in `recording/status/processed/`

**Output files:**
- `notes.pdf` (original copy)
- `notes.md` (rendered from template)
- `notes.html` (responsive HTML5 report)
- `transcript.txt` (plain text with speaker labels)
- `transcript_diarized.vtt` (WebVTT with speaker labels and timestamps)
- `summary.txt` (LLM summary, if enabled)
- `action_items.json` (LLM action items, if enabled)
- `metadata.xml`
- Per-speaker JSON transcripts from whisper

### Publish Stage (notes/publish/notes.rb)
**Input:** `recording/process/notes/<meeting_id>/`
**Output:** `recording/publish/notes/<meeting_id>/`

Key operations:
1. Parses meeting ID format (`<meeting_id>-notes`) to extract meeting_id
2. Converts `notes.md` to PDF using pandoc (falls back to original PDF on failure)
3. Generates `notes.srt` from diarized WebVTT transcript
4. Copies and updates `metadata.xml` with state="published", playback link, duration
5. Adds file size metadata (raw_size, playback_size)
6. Creates `.done` or `.fail` status file in `recording/status/published/`

**Output files:**
- `notes.pdf` (generated from markdown via pandoc)
- `notes.md` (copy from process)
- `notes.srt` (SRT subtitles from WebVTT)
- `metadata.xml` (state=published with playback info)

### Directory Structure
```
bbb-playback-ai/
├── notes/                          # Notes playback format source code
│   ├── process/notes.rb            # Process stage script
│   ├── publish/notes.rb            # Publish stage script
│   ├── lib/
│   │   ├── extractors.rb           # Auto-loader for all extractors
│   │   ├── extractors/
│   │   │   ├── notes_extractor.rb      # Shared notes text + word count
│   │   │   ├── attendees_extractor.rb  # Participant names from events
│   │   │   ├── transcript_extractor.rb # Audio transcription (whisper.cpp)
│   │   │   ├── polls_extractor.rb      # Poll results from events
│   │   │   ├── summary_extractor.rb    # LLM meeting summary
│   │   │   └── action_items_extractor.rb # LLM action item extraction
│   │   ├── helpers/
│   │   │   ├── webvtt_parser.rb        # WebVTT parse/convert (VTT↔SRT)
│   │   │   └── markdown_converter.rb   # Basic markdown→HTML converter
│   │   └── llm_client.rb              # Multi-provider LLM abstraction
│   └── templates/
│       ├── notes.md.erb            # Markdown output template
│       └── notes.html.erb          # HTML5 output template
├── config/
│   ├── bigbluebutton.yml           # BBB paths (overridden for local dev)
│   ├── notes.yml                   # Notes format config (publish_dir, format)
│   └── llm.yml.example             # LLM configuration template
├── recording/
│   ├── raw/                        # Input: raw recordings from BBB server
│   ├── process/notes/              # Output: processed files
│   ├── publish/notes/              # Output: published files
│   └── status/                     # Status markers (.done/.fail files)
├── logs/notes/                     # Processing logs
├── whisper.cpp/                    # Audio transcription engine (git submodule)
├── apply.sh                        # Main test harness
├── clean.sh                        # Cleanup script
├── compare.sh                      # Validation tool
├── install.sh                      # Dependency installer
├── transcribe.sh                   # Whisper.cpp wrapper
└── test_llm.rb                     # LLM configuration tester
```

## Extractor System

All extractors live in `notes/lib/extractors/` and are auto-loaded by `notes/lib/extractors.rb`. They share the `NotesExtractors` module namespace.

### TranscriptExtractor (transcript_extractor.rb)
The most complex extractor (~768 lines). Handles per-speaker audio transcription:
- Maps audio files to speakers using `events.xml` track mappings
- Transcribes each speaker's audio track via whisper.cpp with JSON output
- Resolves overlapping speech segments with word-level splitting
- Filters low-confidence segments (`MIN_SEGMENT_CONFIDENCE = 0.4`) and noise
- Merges into WebVTT format with speaker labels and sentence-level cue splitting
- Falls back to single-file transcription if per-speaker fails
- Key constants: `MAX_CUE_CHARS = 200`, `MAX_CUE_DURATION_MS = 15_000`, `MIN_TRACK_WORDS = 3`

### SummaryExtractor / ActionItemsExtractor
Both use `LLMClient` for AI features. They degrade gracefully (return nil/empty) when LLM is disabled. ActionItemsExtractor returns structured JSON: `[{owner, label, status}]` where status is "ok", "warn", or "pending".

## Configuration

### LLM Setup (optional)
```bash
cp config/llm.yml.example config/llm.yml
# Edit config/llm.yml to set provider: 'claude' or 'openai'
# Set API key via environment variable or in config file
```

**Environment variables** (take priority over config file):
- `ANTHROPIC_API_KEY` — for Claude provider
- `OPENAI_API_KEY` — for OpenAI provider

### Config Files
- `config/bigbluebutton.yml` — sets `recording_dir`, `log_dir`, `playback_host` for local dev
- `config/notes.yml` — sets `publish_dir` and `format` (pdf)
- `config/llm.yml` — LLM provider, API keys, model settings, system prompt

## Dependencies

### System
- **whisper.cpp** — audio transcription (installed via `./install.sh`)
- **pandoc** + **texlive-latex** — markdown to PDF conversion
- **ffmpeg** — audio format conversion (used by transcribe.sh)
- **xmllint** — XML validation (used by compare.sh)

### Ruby Gems
- `anthropic` (anthropic-sdk-ruby) — Claude API client
- `openai` (ruby-openai) — OpenAI API client
- `optimist` — command-line option parsing
- `builder` — XML generation
- `nokogiri` — XML/HTML parsing (BBB system dependency)
- Standard library: yaml, json, erb, fileutils, logger

## Development Workflow

1. **Copy raw recording data** (if needed):
   ```bash
   sudo cp -r /var/bigbluebutton/recording/raw/<meeting_id> ./recording/raw/
   ```

2. **Edit scripts** in `notes/process/`, `notes/publish/`, `notes/lib/`, or `notes/templates/`

3. **Clean previous run**: `./clean.sh <meeting_id>`

4. **Test changes**: `./apply.sh <meeting_id>`

5. **Review logs**: Check `logs/notes/` for errors

6. **Compare with server**: `./compare.sh <meeting_id>` to validate

7. **Deploy to production** (when ready):
   ```bash
   sudo cp notes/process/notes.rb /usr/local/bigbluebutton/core/scripts/process/
   sudo cp notes/publish/notes.rb /usr/local/bigbluebutton/core/scripts/publish/
   ```

## Key Implementation Details

### Script Structure Pattern
All BBB process/publish scripts follow this pattern:
```ruby
require '/usr/local/bigbluebutton/core/lib/recordandplayback'
require 'optimist'
require 'yaml'

opts = Optimist::options do
  opt :meeting_id, "Meeting id", type: String
end

props = YAML::load(File.open('path/to/config.yml'))
logger = Logger.new("#{log_dir}/notes/process-#{meeting_id}.log", 'daily')
BigBlueButton.logger = logger

unless FileTest.directory?(target_dir)
  # Do processing work
end

rescue Exception => e
  BigBlueButton.logger.error(e.message)
  exit 1
end
```

### BBB Library Utilities
Scripts use the system BBB library (`/usr/local/bigbluebutton/core/lib/recordandplayback`):
- `BigBlueButton.logger` — logging
- `BigBlueButton::Events.get_recording_length(doc)` — recording duration
- `BigBlueButton::Events.get_meeting_metadata(path)` — meeting metadata
- `BigBlueButton::Events.get_num_participants(doc)` — participant count
- `BigBlueButton.add_raw_size_to_metadata(dir, raw_dir)` — raw file sizes
- `BigBlueButton.add_playback_size_to_metadata(dir)` — playback file sizes

### Meeting ID Format
- Process script receives: `<meeting_id>` (e.g., `1b30d714...-1760738236204`)
- Publish script receives: `<meeting_id>-notes` (format suffix appended)
- Publish script parses with regex: `/(.*)-(.*)/.match(id)` to split meeting_id and format

### Status Files
- `.done` files in `recording/status/processed/` signal process completion
- `.done` files in `recording/status/published/` signal publish completion
- `.fail` files in `recording/status/published/` signal publish errors

### Template Rendering
Process stage renders both markdown and HTML via ERB templates:
- `notes/templates/notes.md.erb` — markdown with notes, attendees, polls, transcript, summary
- `notes/templates/notes.html.erb` — responsive HTML5 with dark/light mode, collapsible transcript, action item status pills, print optimization
- Templates receive data via instance variables set in `render_markdown_template()` / `render_html_template()`
