# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements the **`ai-summary`** recording playback format for BigBlueButton (BBB). It plugs into the standard BBB recording pipeline and adds AI-powered features: audio transcription (cloud providers or local whisper.cpp fallback), speaker-labeled WebVTT output, LLM-generated meeting summaries, and action item extraction.

Detailed docs live alongside this file — prefer updating them over duplicating content here:
- **ARCHITECTURE.md** — pipeline diagram, component-by-component walkthrough, data formats
- **DEVELOPMENT.md** — package build, source deployment table, advanced provider configuration
- **OPERATIONS.md** — runtime config, reprocessing, logs, status checks
- **INSTALLATION.md** — first-time server setup

## Commands

```bash
# Run the full pipeline (transcription → process → publish) on a test recording
./dev/run_pipeline.sh test-recordings/<meeting_id>.tar.gz --skip-llm
./dev/run_pipeline.sh <tarball> --skip-transcription --skip-llm   # reuse bundled transcription.json
./dev/run_pipeline.sh <tarball> --force-retranscribe --skip-llm   # wipe workspace + re-transcribe
./dev/run_pipeline.sh --setup-only    # non-BBB machine: install shim BBB tree (sudo)

# Run individual stages manually
ruby src/ai-summary/process/ai-summary.rb -m <meeting_id>
ruby src/ai-summary/publish/ai-summary.rb -m <meeting_id>-ai-summary
ruby src/scripts/post_archive/transcribe_audio.rb -m <meeting_id>
ruby src/scripts/transcription/openai_whisper.rb <audio.webm> <out.json> <events.xml>

# Build / deploy
./build.sh                    # dpkg-buildpackage; outputs ../bbb-record-ai-summary_*.deb
./dch_version.sh              # prints Debian version derived from git tags
./deploy.sh [--dry-run]       # deploy source to a BBB server (auto-elevates with sudo)
./deploy.sh --install-whisper # additionally build/install local whisper.cpp fallback
```

There is no test suite or linter. The dev harness (`dev/run_pipeline.sh` + `dev/README.md`) is the way to verify changes end-to-end: it unpacks a raw-recording tarball into `recording/raw/`, runs all three stages, and (on a BBB server with HTTPS) publishes a web preview. On a BBB server it runs the source scripts in dev mode via `bundle exec`; on a non-BBB machine `--setup-only` creates `/usr/local/bigbluebutton/core/` with a shim library (`dev/lib/recordandplayback.rb`) and symlinks the scripts into it.

GitHub Actions builds the .deb on pushes/PRs to the `ai-summary-new-format` branch and attaches it to releases; `publish-tag.yml` is a manual workflow that bumps the version and cuts a tag.

## BBB Recording Pipeline Integration

BBB processes recordings through **Archive → Sanity → Process → Publish**. This project adds:

- **post_archive hook** `src/scripts/post_archive/transcribe_audio.rb` — transcribes all audio tracks into `recording/raw/<meeting_id>/transcription/`
- **process stage** `src/ai-summary/process/ai-summary.rb` — extracts meeting data, renders ERB templates, writes to `recording/process/ai-summary/<meeting_id>/`
- **publish stage** `src/ai-summary/publish/ai-summary.rb` — converts to PDF, finalizes metadata, copies to `/var/bigbluebutton/published/ai-summary/<meeting_id>/`
- **post_publish hook** (optional) `src/scripts/post_publish/publish_to_docs.rb` — publishes to La Suite Numérique Docs

See ARCHITECTURE.md for the wiring into `/etc/bigbluebutton/recording/recording.yml`.

## Configuration

There are exactly **two** config files, both tracked in git with safe defaults, both supporting **deep-merged** operator overrides in `/etc/bigbluebutton/` (only keys present in the override change; nested sections not mentioned are preserved):

| Config | Override | Contents |
|---|---|---|
| `src/ai-summary/ai-summary.yml` (deployed to `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`) | `/etc/bigbluebutton/ai-summary.yml` | Root format keys (`publish_dir`, `playback_dir`, `format`, `locale`, `include_chat_in_discussion`, `transcript_group_gap_seconds`), `llm:` section (provider, API keys, per-provider model config, system prompt, `language`), `docs:` section |
| `src/scripts/transcription/transcription.yml` (deployed to `/usr/local/bigbluebutton/core/lib/transcription/transcription.yml`) | `/etc/bigbluebutton/post-archive-transcription.yml` | `transcriber_path` (string or array), per-provider `openai:` / `albert:` sections |

Environment variables take priority over config file values for API keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `ALBERT_API_KEY`.

Scripts read BBB core properties via `BigBlueButton.read_props` (the standard BBB mechanism), and the process script loads `ai-summary.yml` relative to its working directory — the dev harness generates the dev-mode copies (`src/bigbluebutton.yml`, `src/config/bigbluebutton.yml`, `src/ai-summary.yml`) automatically on first run.

## Process Stage (`src/ai-summary/process/ai-summary.rb`)

All extractors are defined **inline in this file** under the `Extractors` module — there are no separate extractor files:

| Extractor | Description |
|---|---|
| `AttendeesExtractor` | Unique participant names from `ParticipantJoinEvent` |
| `NotesExtractor` | Shared notes from `notes/notes.html`; returns `{plain_text:, html:}` with sanitized CSS |
| `PollsExtractor` | Published polls from `PollPublishedRecordEvent`, plus reconstruction of started-but-never-published polls from `PollStartedRecordEvent` + `UserRespondedToPollRecordEvent` |
| `EventsExtractor` | Recording-on intervals from `RecordStatusEvent` pairs |
| `TranscriptExtractor` | Reads pre-computed `transcription.json`; generates WebVTT and plain text |
| `SummaryExtractor` | LLM summary from notes + transcript; accepts `prompt_addition:` |
| `ActionItemsExtractor` | LLM-extracted action items `[{owner:, label:, status:}]`; `prompt_addition:` plus a hard JSON-only override at the end of the prompt |
| `ChatExtractor` | Chat messages from `GroupChatMessageBroadcastEvent`/`PublicChatEvent` |

`TranscriptExtractor` maps audio tracks to speakers via `AudioTrackPublishedEvent` (falls back to `"Unknown Speaker"`), uses `BigBlueButton::Events.first_event_timestamp` as recording start, and merges segments into cues split on speaker change, `MAX_CUE_CHARS = 200`, or `MAX_CUE_DURATION_MS = 15_000`. `diarize_provider_transcriptions` applies the same pipeline to every `transcription_<name>.json` and writes `transcript_diarized_<name>.json`.

**Templates** (`src/ai-summary/templates/`): `ai-summary.md.erb`, `ai-summary.html.erb`, `ai-summary.json.erb`. All UI strings come from `templates/locales/<locale>.json` (`en`, `fr`, `pt`), selected by the `locale:` config key (falls back to `en`) and exposed to templates as `@strings`. The template path resolves from `playback_dir` (production: `/usr/local/bigbluebutton/core/playback/ai-summary/`).

**Process dir output:** `ai-summary.md`, `ai-summary.html`, `transcript.txt`, `transcript_diarized.vtt`, `transcript_diarized.json`, `summary.txt`, `action_items.json`, `metadata.xml` (state="processed"), plus per-provider `transcript_diarized_<name>.json`.

## Publish Stage (`src/ai-summary/publish/ai-summary.rb`)

1. Strips the format suffix via `delete_suffix("-ai-summary")` — **not** a last-hyphen split, because the format name itself contains a hyphen
2. Converts `ai-summary.md` to PDF with `pandoc --pdf-engine=xelatex`
3. **Renames on publish**: `transcript_diarized.vtt` → `transcription.vtt`, `transcript_diarized.json` → `transcription.json`; per-provider `transcript_diarized_<name>.json` → `transcription_<name>.json`
4. Updates `metadata.xml` with `state="published"`, playback link, duration, and a `<url>` entry per published transcription file
5. Cleans up process/publish staging dirs; writes `.done`/`.fail` to `recording/status/published/`

## Transcription System

`transcribe_audio.rb` exits early if `transcription.json` already exists (delete it to re-run). `transcriber_path` accepts a string or array; each provider runs over all audio tracks and writes `transcription_<name>.json`. The **first** provider's merged output is also written as the canonical `transcription.json` consumed by the process stage. When no provider is configured or available, it falls back to the bundled `whisper_cpp.rb` (binary/model auto-located; override with `WHISPER_BINARY`/`WHISPER_MODEL`).

Every provider script implements the same CLI contract:
```
<provider_script> <audio_file> <output_json_file> <events_xml_file>
```

Providers in `src/scripts/transcription/`:
- `openai_whisper.rb` — OpenAI Whisper API; 25 MB chunk limit; segment quality filter from `no_speech_prob`/`compression_ratio`
- `albert_whisper.rb` — Albert (French gov) API; language from `meta_recording-transcription-language` metadata → config → env; optional VAD via `node-vad`, with forced VAD re-check on suspiciously short transcriptions
- `whisper_cpp.rb` — local whisper.cpp fallback
- `openai_whisper_{main,precise,inclusive,contextual,multilingual}.rb` — **scenario wrappers**: each sets `WHISPER_*`/`OPENAI_*` env-var presets tuned for a use case (already-set env vars win), then `load`s `openai_whisper.rb`
- `transcription_utils.rb` — shared chunking: ffmpeg → 16 kHz mono WAV, speech intervals from `ParticipantTalkingEvent` cues (fallback: audio-track floor intervals), merges cues with gap ≤ 2000 ms, cuts one WAV chunk per merged cue

## LLM Client (`src/ai-summary/lib/llm_client.rb`)

Factory: `LLMClient::Base.create(logger, language: nil, prompt_addition: nil)` returns `ClaudeClient`, `OpenAIClient`, `AlbertClient`, or `DisabledClient` (no-op) based on `llm.provider`. `prompt_addition` is appended to the system prompt and is sourced from the `bbb-ai-summary-prompt-addition` meeting metadata key. `llm.language` forces the summary output language; unset means auto-detect.

**Production-only**: the client raises when `__dir__` is outside `/usr/local/bigbluebutton/core` — the dev harness satisfies this by symlinking `llm_client.rb` under the BBB core tree.

## Key Implementation Details

- Process script receives `<meeting_id>`; publish script receives `<meeting_id>-ai-summary`
- Status files: `recording/status/processed/<meeting_id>-ai-summary.done`, `recording/status/published/<meeting_id>-ai-summary.done|.fail`
- Scripts require the BBB core library `/usr/local/bigbluebutton/core/lib/recordandplayback` (real on a BBB server, shim from `dev/lib/` otherwise)
- Dependencies — system: ffmpeg, pandoc, texlive-xetex, optionally whisper.cpp and node + node-vad; gems: `optimist`, `builder`, `nokogiri`, plus optional `anthropic`/`openai`

## Logging

```bash
tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log                  # transcription orchestrator
tail -f /var/log/bigbluebutton/post_archive-transcribe-albert-<meeting_id>.log           # Albert provider
tail -f /var/log/bigbluebutton/post_archive-transcribe-openai_whisper-<meeting_id>.log   # OpenAI Whisper provider
tail -f /var/log/bigbluebutton/post_archive-transcribe-whisper_cpp-<meeting_id>.log       # whisper.cpp fallback
tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log        # process
tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log        # publish
```

Each transcription provider writes its own log file, separate from the orchestrator log — check the provider-specific file for API-level errors (e.g. `"Albert API error <code> ..."`) when a provider fails. All logs rotate daily (`Logger.new(path, 'daily')`).

Dev harness logs go to `logs/ai-summary/` in the project root.

## Pull Request Format

PR descriptions must briefly describe what has been done in two sections:

```
### What does this PR do?
- Bullet list of changes

### Motivation
Prose explanation of the motivation behind each change.
```
