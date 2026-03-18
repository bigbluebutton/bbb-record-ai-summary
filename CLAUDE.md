# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements the **`ai-summary`** recording playback format for BigBlueButton (BBB). It plugs into the standard BBB recording pipeline and adds AI-powered features: audio transcription via whisper.cpp, speaker-labeled WebVTT output, LLM-generated meeting summaries, and action item extraction.

Source code lives in `src/`. Shell scripts at the project root (`deploy.sh`, `deploy_transcription.sh`) copy everything to a production BBB server.

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
│   │   │   ├── ai-summary.html.erb     # HTML output template
│   │   │   └── ai-summary.json.erb     # JSON output template
│   │   └── ai-summary.yml              # Unified config: format + llm: + docs: sections
│   └── scripts/
│       ├── post_archive/
│       │   └── transcribe_audio.rb     # Post-archive audio transcription hook
│       ├── post_publish/
│       │   └── publish_to_docs.rb      # Post-publish hook: publishes to La Suite Numérique Docs
│       └── transcription/
│           ├── openai_whisper.rb       # OpenAI Whisper API provider
│           ├── albert_whisper.rb       # Albert (French gov) API provider
│           ├── transcription_utils.rb  # Shared: audio chunking from events.xml talking cues
│           ├── transcription.yml           # Default config (safe defaults, tracked in git)
│           └── transcription-override.yml  # Local operator config with real credentials (gitignored)
├── ai-summary-playback.nginx           # Nginx location block
├── recording/                          # Test workspace (gitignored)
├── logs/                               # Processing logs (gitignored)
└── deploy.sh                           # Deploys to production BBB (requires root)
```

## Config Files

There are exactly **two** config files for this project:

### `ai-summary.yml` (unified config — tracked in git)
Located at `src/ai-summary/ai-summary.yml` (dev) or `/usr/local/bigbluebutton/core/scripts/ai-summary.yml` (production). Contains three sections:

- **Root keys** (`publish_dir`, `playback_dir`, `format`, `whisper_threads`, `include_chat_in_discussion`) — format/pipeline settings
- **`llm:`** — LLM summarization (formerly `llm.yml`): provider selection, API keys, per-provider model config, system prompt
- **`docs:`** — La Suite Numérique Docs integration (formerly `docs.yml`): enabled flag, host, Keycloak credentials

The file is tracked in git with safe defaults (`llm.provider: disabled`, `docs.enabled: false`). Credentials are added either directly on the production server or via the `/etc/bigbluebutton/ai-summary.yml` override (see below).

### `transcription.yml` (tracked in git, safe defaults)
Located alongside `transcribe.rb` at `/usr/local/bigbluebutton/core/lib/transcription/transcription.yml` (production) or `src/scripts/transcription/transcription.yml` (dev). Configures the active transcription backend. Add credentials via `transcription-override.yml` (gitignored) or `/etc/bigbluebutton/post-archive-transcription.yml` on the server.

## Override Files (`/etc/bigbluebutton/`)

Both config files support operator overrides placed in `/etc/bigbluebutton/`. The override is **deep-merged** so only keys present in the override are changed — nested sections not mentioned in the override are fully preserved.

| Override file | Applies to |
|---|---|
| `/etc/bigbluebutton/ai-summary.yml` | `ai-summary.yml` (all sections: root, `llm:`, `docs:`) |
| `/etc/bigbluebutton/post-archive-transcription.yml` | `transcription.yml` |

Example: to enable Claude without touching any other setting:
```yaml
# /etc/bigbluebutton/ai-summary.yml
llm:
  provider: claude
  anthropic_api_key: "sk-ant-..."
```

## BBB Recording Pipeline Integration

BBB processes recordings through: **Archive → Sanity → Process → Publish**

This project adds:
- A **post_archive hook** (after Archive): `transcribe_audio.rb` — transcribes all audio tracks
- A **process stage**: `process/ai-summary.rb` — extracts and renders all meeting data
- A **publish stage**: `publish/ai-summary.rb` — converts to PDF, finalizes metadata, copies to publish dir
- A **post_publish hook** (optional): `publish_to_docs.rb` — publishes the AI summary to La Suite Numérique Docs

## Local Development

The process and publish scripts require the BBB core library at `/usr/local/bigbluebutton/core/lib/recordandplayback` (unconditional `require` at the top of each script). Development therefore assumes a BBB server or that library is installed locally.

### Config files that must be created for dev (not in repo)

**`src/bigbluebutton.yml`** — read by the process script in dev mode:
```yaml
recording_dir: /path/to/repo/recording
log_dir: /path/to/repo/logs
```

**`src/config/bigbluebutton.yml`** — read by the post-archive transcription script in dev mode:
```yaml
recording_dir: /path/to/repo/recording
log_dir: /path/to/repo/logs
```

**`src/ai-summary.yml`** — read by the process script in dev mode (note: different from `src/ai-summary/ai-summary.yml`). Create as a symlink or copy of `src/ai-summary/ai-summary.yml` and adjust `playback_dir` to point to `src/ai-summary/templates/` so the ERB templates resolve locally.

### Running scripts locally

```bash
# Run process stage (default meeting_id is a placeholder; use -m to override)
ruby src/ai-summary/process/ai-summary.rb -m <meeting_id>

# Run publish stage
ruby src/ai-summary/publish/ai-summary.rb -m <meeting_id>-ai-summary

# Run post-archive transcription
ruby src/scripts/post_archive/transcribe_audio.rb -m <meeting_id>

# Run a transcription provider directly
ruby src/scripts/transcription/openai_whisper.rb <audio.webm> <out.json> <events.xml>
```

The test recording workspace is `recording/raw/<meeting_id>/` (gitignored). Delete `recording/raw/<meeting_id>/transcription/transcription.json` to force re-transcription.

## Building the Debian Package

```bash
./build.sh                  # runs dpkg-buildpackage -us -uc -b; outputs ../bbb-record-ai-summary_*.deb
./dch_version.sh            # prints DCH_VERSION=<debian-compatible version> derived from git tags
```

`dch_version.sh` converts semver git tags (e.g. `v1.2.0-rc.1`) to Debian version strings (e.g. `1.2.0~rc1`). It handles `alpha`, `beta`, and `rc` pre-release qualifiers and appends `.postN+gHASH` for untagged commits.

The `debian/` directory uses standard debhelper. `debian/rules` installs all source files to the correct production paths. `debian/postinst`:
- Creates `/var/bigbluebutton/published/ai-summary/`, log dir, and staging publish dir
- Copies `transcription.yml` to its final location if it doesn't already exist
- Both `openai_whisper.rb` and `albert_whisper.rb` are installed; the active one is selected via `transcriber_path` in `/etc/bigbluebutton/post-archive-transcription.yml`

## Deployment

```bash
./deploy.sh                              # deploy to production BBB (requires root, auto-elevates with sudo)
./deploy.sh --dry-run                    # preview without writing files
./deploy_transcription.sh openai_whisper # deploy OpenAI Whisper transcription provider
./deploy_transcription.sh albert_whisper # deploy Albert Whisper transcription provider
./deploy_overrides.sh                    # deploy local override files to /etc/bigbluebutton/
```

`deploy_overrides.sh` copies `src/ai-summary/ai-summary-override.yml` → `/etc/bigbluebutton/ai-summary.yml` and `src/scripts/transcription/transcription-override.yml` → `/etc/bigbluebutton/post-archive-transcription.yml` (only if each source file exists). Use this to push local credential overrides to a dev/prod server without touching the tracked config files.

After deployment, wire `ai-summary` into the pipeline:
```bash
BBB_YML=/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml
sudo yq e -i '.steps.captions += ["process:ai-summary"]' "$BBB_YML"
sudo yq e -i '.steps["process:ai-summary"] = "publish:ai-summary"' "$BBB_YML"
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
| `ChatExtractor` | Chat messages from `GroupChatMessageBroadcastEvent`/`PublicChatEvent` in events.xml |

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
3. Converts `ai-summary.md` to PDF with `pandoc --pdf-engine=xelatex` (falls back to original PDF)
4. Updates `metadata.xml` with `state="published"`, playback link, duration
5. Copies files to final publish dir (`/var/bigbluebutton/published/ai-summary/<meeting_id>/`)
6. Cleans up process and publish staging dirs
7. Creates `.done` or `.fail` status file in `recording/status/published/`

## Post-Archive Stage (`src/scripts/post_archive/transcribe_audio.rb`)

**Trigger:** Registered as a BBB post_archive hook, runs after Archive stage
**Output:** `recording/raw/<meeting_id>/transcription/transcription.json`

Transcription back-end selection (priority order):
1. **Provider Ruby script** — `transcribe.rb` in the transcription lib dir (production: `/usr/local/bigbluebutton/core/lib/transcription/`, dev: `src/scripts/transcription/`). Deploy via `deploy_transcription.sh` or debconf selection. Both `openai_whisper.rb` and `albert_whisper.rb` are installed; the chosen one is symlinked as `transcribe.rb`.
2. **whisper.cpp** — built-in fallback, searches multiple known paths; converts audio to 16 kHz WAV via ffmpeg

`transcription.yml` (alongside `transcribe.rb`) configures the active backend. API keys can be set via `ALBERT_API_KEY`/`OPENAI_API_KEY` env vars (take priority) or in the YAML.

If `transcription.json` already exists, the script exits early (delete it to re-run).

### Transcription Provider Interface

Both `openai_whisper.rb` and `albert_whisper.rb` are called as:
```
transcribe.rb <audio_file> <output_json_file> <events_xml_file>
```

Both share `transcription_utils.rb` (same directory) for chunk preparation:
- Converts audio to 16 kHz mono WAV via ffmpeg
- Extracts `ParticipantTalkingEvent` cues from `events.xml` to find speech intervals
- Falls back to `AudioTrackPublished/Unpublished` floor intervals if no talking events
- Merges cues with gap ≤ `MERGE_GAP_MS = 2000ms`, then cuts one WAV chunk per merged cue
- Returns `{ work_file:, temp_wav:, chunks_dir:, chunks: [{path:, from_ms:, to_ms:}] }`

**Albert provider** (`albert_whisper.rb`): reads language from `meta_recording-transcription-language` in `metadata.xml` (adjacent to events.xml), then from `transcription.yml`, then env. Supports optional Voice Activity Detection (VAD via `node-vad`) to skip silent chunks; short transcriptions (≤ 3 words) trigger a forced VAD re-check to filter hallucinations. Config nested under `albert:` key in `transcription.yml`.

**OpenAI provider** (`openai_whisper.rb`): enforces 25 MB per-chunk limit; filters segments using a quality score derived from `no_speech_prob` and `compression_ratio` (threshold 0.4); uses `verbose_json` response format with segment-level timestamps. Config nested under `openai:` key in `transcription.yml`.

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
| `AlbertClient` | Albert (French government) API |
| `DisabledClient` | No-op, returns nil |

**LLM summarization is production-only** — the client raises an error when `__dir__` is outside `/usr/local/bigbluebutton/core`. Config is read from the `llm:` section of `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`.

Environment variables take priority over config file values:
- `ANTHROPIC_API_KEY` for Claude
- `OPENAI_API_KEY` for OpenAI
- `ALBERT_API_KEY` for Albert

## Config Loading

### Process script (`process/ai-summary.rb`)
- **Production** (`__dir__` starts with `/usr/local/bigbluebutton/core/scripts`): reads `bigbluebutton.yml` and `ai-summary.yml` from that dir
- **Development**: reads `src/bigbluebutton.yml` and `src/ai-summary.yml` from project root

### Publish script (`publish/ai-summary.rb`)
- **Always** reads `bigbluebutton.yml` from `/usr/local/bigbluebutton/core/scripts/` (no dev fallback for BBB props)
- **Development**: reads format config from `src/ai-summary/ai-summary.yml`

### LLM client (`llm_client.rb`)
- Reads the `llm:` section from `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`
- Production-only: raises if `__dir__` is outside `/usr/local/bigbluebutton/core`

### Post-publish script (`publish_to_docs.rb`)
- Reads the `docs:` section from `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`

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
