# Architecture

## BBB Recording Pipeline

BigBlueButton processes recordings through a multi-stage pipeline. Each stage is driven by the `bbb-rap-resque-worker` service, which reads the pipeline steps from `bigbluebutton.yml`.

```
Meeting ends
    │
    ▼
┌──────────┐
│ Archive  │  Saves raw media, events.xml, notes, audio tracks
└────┬─────┘
     │
     ├──▶ post_archive hooks run here  ← transcribe_audio.rb lives here
     │
     ▼
┌──────────┐
│  Sanity  │  Validates the archive is complete
└────┬─────┘
     │
     ▼
┌──────────┐
│ Captions │  (optional) Generates caption files
└────┬─────┘
     │
     ├──▶ process:presentation
     └──▶ process:ai-summary          ← process/ai-summary.rb
              │
              ▼
         publish:ai-summary           ← publish/ai-summary.rb
              │
              ▼
    /var/bigbluebutton/published/ai-summary/<meeting_id>/
```

The pipeline config that wires `ai-summary` in — `/etc/bigbluebutton/recording/recording.yml`,
an operator-created file that `BigBlueButton.read_props` shallow-merges over
`/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`:

```yaml
steps:
  archive: "sanity"
  sanity: "captions"
  captions:
    - "process:presentation"
    - "process:ai-summary"
  "process:presentation": "publish:presentation"
  "process:ai-summary": "publish:ai-summary"
```

---

## Components

### 1. Post-Archive Hook — `transcribe_audio.rb`

**Location (deployed):** `/usr/local/bigbluebutton/core/scripts/post_archive/transcribe_audio.rb`
**Trigger:** Runs after the Archive stage, before Sanity
**Invocation:** `cd /usr/local/bigbluebutton/core && bundle exec ruby scripts/post_archive/transcribe_audio.rb -m <meeting_id>`

Discovers all audio files in `recording/raw/<meeting_id>/audio/` (extensions: `webm opus mp3 wav ogg m4a flac`) and transcribes each one using each configured provider.

**Transcription back-end (priority order):**

1. **Provider script(s)** — `transcriber_path` in `transcription.yml` accepts a single path string or an array. Each entry is resolved via `normalize_transcriber_paths` (strips `.rb`, deduplicates by name). Available providers are probed with `resolve_active_backends`; unavailable ones are skipped with a warning. Each active provider is run via `run_provider_transcription`, which calls the script as:
   ```
   <transcriber_path> <audio_file> <output_json_file> <events_xml_file>
   ```
   The script must produce a JSON file with this structure:
   ```json
   { "transcription": [{ "offsets": { "from": <ms>, "to": <ms> }, "text": "..." }] }
   ```

2. **whisper.cpp fallback** — used when `transcriber_path` is absent, `"disabled"`, or no configured providers are available. Audio is converted to 16 kHz mono WAV via ffmpeg before passing to `whisper-cli`.

**Output:** `recording/raw/<meeting_id>/transcription/`

Each provider writes `transcription_<name>.json`. The first provider's output is also written as the canonical `transcription.json` (read by the process stage). All files share the same structure with an added `"provider"` field:

```json
{
  "meeting_id": "1b30d714...-1760738236204",
  "generated_at": "2025-01-15T10:23:00Z",
  "provider": "openai_whisper",
  "tracks": [
    {
      "file": "audio-track-name.webm",
      "segments": [
        { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello everyone." }
      ]
    }
  ]
}
```

If `transcription.json` already exists, the script exits immediately without re-transcribing (delete it to force a re-run).

---

### 2. Process Stage — `process/ai-summary.rb`

**Location (deployed):** `/usr/local/bigbluebutton/core/scripts/process/ai-summary.rb`
**Invocation:** `ruby ai-summary.rb -m <meeting_id>`

**Input directory:** `recording/raw/<meeting_id>/`
```
raw/<meeting_id>/
├── events.xml                      # Meeting event log
├── notes/notes.pdf                 # Shared notes (PDF)
├── notes/notes.html                # Shared notes (HTML, from Etherpad)
├── audio/                          # Per-speaker audio tracks
│   ├── <user_id>.webm
│   └── ...
└── transcription/
    ├── transcription.json              # Canonical (first provider) — read by process stage
    ├── transcription_<provider>.json   # Per-provider raw output (one file per provider)
    └── ...
```

**Output directory:** `recording/process/ai-summary/<meeting_id>/`
```
process/ai-summary/<meeting_id>/
├── ai-summary.pdf                      # Original notes PDF
├── ai-summary.md                       # Rendered markdown report
├── ai-summary.html                     # Rendered HTML report
├── transcript.txt                      # Plain text, speaker-grouped
├── transcript_diarized.vtt             # WebVTT with speaker labels (first provider)
├── transcript_diarized.json            # Diarized JSON (first provider)
├── transcript_diarized_<provider>.json # Diarized JSON for each additional provider
├── summary.txt                         # LLM summary (if enabled)
├── action_items.json                   # LLM action items (if enabled)
└── metadata.xml                        # state="processed"
```

#### Extractor Module

All extractors live inline in `process/ai-summary.rb` under `module Extractors`.

**`AttendeesExtractor`**
- XPath: `//event[@eventname='ParticipantJoinEvent']/name`
- Returns sorted unique array of participant names

**`NotesExtractor`**
- Reads `notes/notes.html`, strips HTML tags, counts words
- Returns plain text content and word count

**`PollsExtractor`**
- XPath: `//event[@eventname='PollPublishedRecordEvent']`
- Returns array of `{ id:, question:, answers: [{text:, votes:}] }`

**`TranscriptExtractor`**
- Reads `transcription.json` (canonical first-provider output); logs the `"provider"` field if present
- Builds speaker-to-audio-file mapping from `AudioTrackPublishedEvent` in `events.xml`
- Uses `BigBlueButton::Events.first_event_timestamp(events_doc)` for the recording start time
- Converts absolute UTC timestamps to recording-relative offsets for WebVTT
- Segment-to-cue merging is handled by `build_segments_from_tracks` (private) and `create_transcription_cues`, splitting when:
  - Speaker changes
  - Cue text exceeds `MAX_CUE_CHARS = 200`
  - Cue duration exceeds `MAX_CUE_DURATION_MS = 15_000`
- Long cues are further split at sentence boundaries (`.!?`) with proportional timestamp interpolation
- Returns `{ plain: String, diarized: String }` (WebVTT)
- **`diarize_provider_transcriptions`** (public, called after `extract`) — finds all `transcription_<name>.json` files in the raw transcription dir, applies the same diarization pipeline to each, and writes `transcript_diarized_<name>.json` to the process dir

**`SummaryExtractor`**
- Combines notes content, plain transcript, polls, and chat messages
- Calls `LLMClient::Base.create(logger, language:, prompt_addition:).summarize(text)`
- `prompt_addition` is appended to the LLM system prompt (see Per-Meeting Prompt Customization below)
- Returns nil when LLM is disabled or unavailable
- Saves result to `summary.txt`

**`ActionItemsExtractor`**
- Combines summary and transcript; sends to LLM with a structured JSON prompt
- Also receives `prompt_addition`, appended to the system prompt
- Parses JSON response (handles markdown code fences)
- Returns `[{ owner: String, label: String, status: :ok|:warn|:pending }]`
- Saves raw JSON to `action_items.json`

#### Helper Modules

**`WebVTTParser`** — Parses a WebVTT string into `[{start:, end:, speaker:, text:}]` hashes for template use.

**`MarkdownConverter`** — Converts markdown text to HTML (inline implementation, no gem dependency).

---

### 3. Publish Stage — `publish/ai-summary.rb`

**Location (deployed):** `/usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb`
**Invocation:** `ruby ai-summary.rb -m <meeting_id>-ai-summary`

The BBB framework appends `-<format>` to the meeting ID when invoking publish scripts. The script strips this suffix with `delete_suffix("-ai-summary")`.

**Steps:**
1. Early exit if not invoked with the `-ai-summary` suffix
2. Early exit if `$publish_dir/<meeting_id>/` already exists (idempotent)
3. Convert `ai-summary.md` → `ai-summary.pdf` via `pandoc --pdf-engine=pdflatex`; fall back to original PDF on failure
4. Copy all `transcript_diarized_<provider>.json` files from process dir as `transcription_<provider>.json`
5. Copy `metadata.xml` from process dir; update with `state="published"`, playback link, duration, and a `<url>` entry for each provider transcription file
6. Add raw/playback size metadata
7. Copy staging dir to `$publish_dir/<meeting_id>/`
8. Remove process and staging dirs
9. Write `.done` or `.fail` status file

**Playback link format:**
```
https://<playback_host>/ai-summary/<meeting_id>/ai-summary.pdf
```

---

### 4. LLM Client — `lib/llm_client.rb`

**Location (deployed):** `/usr/local/bigbluebutton/core/lib/ai-summary/llm_client.rb`

Factory: `LLMClient::Base.create(logger, language: nil, prompt_addition: nil)` — reads config and returns the appropriate client.

```
LLMClient::Base
├── ClaudeClient   — POST https://api.anthropic.com/v1/messages
├── OpenAIClient   — POST https://api.openai.com/v1/chat/completions
├── AlbertClient   — POST https://albert.api.etalab.gouv.fr/v1/chat/completions
└── DisabledClient — returns nil
```

`prompt_addition` is stored as `@prompt_addition` on the base class and appended to the system prompt by `system_prompt`. It is sourced from the `bbb-ai-summary-prompt-addition` meeting metadata key (see Per-Meeting Prompt Customization below).

Config is read from the `llm:` section of `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`. The client raises an error if called from outside that directory, preventing accidental LLM calls in development.

Environment variable override (takes priority over config):
- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `ALBERT_API_KEY`

---

### 5. Templates

**Location (deployed):** `/usr/local/bigbluebutton/core/playback/ai-summary/`

Both templates are ERB. The process script resolves the path from `playback_dir` in `ai-summary.yml`.

**`ai-summary.md.erb`** — Sections: Shared Notes, Attendees, Poll Results, Audio Transcription (speaker-labeled with timestamps), Meeting Summary, Word Count footer.

**`ai-summary.html.erb`** — A standalone HTML5 page with:
- Dark/light mode via CSS `prefers-color-scheme`
- KPI header (attendee count, word count, transcript format)
- Collapsible transcript via `<details>`
- Color-coded action item pills (`ok` = green, `warn` = orange)
- Print-optimized CSS
- JavaScript for print, transcript toggle, smooth scroll

---

## Configuration Files

### `ai-summary.yml`

Deployed to `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`.

```yaml
publish_dir: /var/bigbluebutton/published/ai-summary
playback_dir: /usr/local/bigbluebutton/core/playback/ai-summary
format: pdf
whisper_threads: 4
```

### `ai-summary-playback.nginx`

Deployed to `/usr/share/bigbluebutton/nginx/ai-summary.nginx`. Serves the published format directory:

```nginx
location /ai-summary {
    root /var/bigbluebutton/published;
    index index.html index.htm;
}
```

---

## Data Flow Diagram

```
events.xml ─────────────────────────┐
notes/notes.html ────────────────┐  │
notes/notes.pdf ──────────────┐  │  │  ┌── AttendeesExtractor
audio/*.webm ──┐               │  │  │  ├── NotesExtractor
               ▼               │  │  ├──┤  PollsExtractor
         transcribe_audio.rb   │  │  │  ├── TranscriptExtractor
               │               │  │  │  ├── SummaryExtractor (LLM)
               ▼               │  │  │  └── ActionItemsExtractor (LLM)
   transcription.json ─────────┴──┴──┘
                                        │
                                        ▼
                               process/ai-summary.rb
                                        │
                      ┌─────────────────┼────────────────────┐
                      ▼                 ▼                     ▼
               ai-summary.md    ai-summary.html        metadata.xml
               transcript.txt   transcript_diarized.vtt summary.txt
                      │
                      ▼
               publish/ai-summary.rb
                      │
              pandoc (md → pdf)
                      │
                      ▼
  /var/bigbluebutton/published/ai-summary/<meeting_id>/
  ├── ai-summary.pdf
  ├── ai-summary.md
  ├── ai-summary.html
  ├── transcription.vtt
  ├── transcription.json              (diarized, first provider)
  ├── transcription_<provider>.json   (diarized, one per additional provider)
  └── metadata.xml  (state=published, playback link, duration, per-provider URLs)
```

---

## Deployment Paths Summary

| File | Source | Deployed To |
|---|---|---|
| `transcribe_audio.rb` | `src/scripts/post_archive/` | `.../scripts/post_archive/` |
| `transcription_utils.rb` | `src/scripts/transcription/` | `.../lib/transcription/` |
| `openai_whisper.rb` | `src/scripts/transcription/` | `.../lib/transcription/` |
| `albert_whisper.rb` | `src/scripts/transcription/` | `.../lib/transcription/` |
| `process/ai-summary.rb` | `src/ai-summary/process/` | `.../scripts/process/` |
| `publish/ai-summary.rb` | `src/ai-summary/publish/` | `.../scripts/publish/` |
| `llm_client.rb` | `src/ai-summary/lib/` | `.../lib/ai-summary/` |
| `ai-summary.md.erb` | `src/ai-summary/templates/` | `.../playback/ai-summary/` |
| `ai-summary.html.erb` | `src/ai-summary/templates/` | `.../playback/ai-summary/` |
| `ai-summary.yml` | `src/ai-summary/` | `.../scripts/ai-summary.yml` |
| `ai-summary-playback.nginx` | project root | `/usr/share/bigbluebutton/nginx/ai-summary.nginx` |

All paths under `.../` are relative to `/usr/local/bigbluebutton/core`.
