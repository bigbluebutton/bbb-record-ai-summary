# bbb-record-ai-summary — `ai-summary` Recording Format

An `ai-summary` playback format for [BigBlueButton](https://bigbluebutton.org/) that enriches meeting recordings with AI-powered features: automatic audio transcription, speaker diarization, LLM-generated summaries, and action item extraction.

## What it does

After a BBB meeting is recorded, this format adds:

- **Audio transcription** — per-speaker audio tracks are transcribed via whisper.cpp (or a custom back-end)
- **Speaker-labeled WebVTT** — transcripts are formatted as WebVTT cues with speaker attribution and timestamps relative to recording start
- **Shared notes** — the meeting's Etherpad notes are extracted and included
- **Poll results** — any polls run during the meeting are captured
- **LLM summary** — optional AI-generated meeting summary (requires API key configuration)
- **Action items** — optional structured action item extraction via LLM
- **HTML report** — a standalone, print-ready HTML page with dark/light mode and an embedded transcript viewer
- **Markdown + PDF** — the report is also available as Markdown and converted to PDF via pandoc

## Building the Debian package

Install the build dependencies first:

```bash
sudo apt install debhelper
```

Then build:

```bash
./build.sh
```

This produces `../bbb-record-ai-summary_*.deb`.

## Installation (Debian package)

> This is the recommended installation method. The `deploy.sh` approach (described further below) is intended for development and testing.

Before installing, keep in mind that this integration only works with LiveKit. See the [documentation](https://docs.bigbluebutton.org/new-features/#integration-with-livekit) for setup details.

### Step 1 — Install the package

```bash
sudo apt install ./bbb-record-ai-summary_0.1.0_all.deb
```

`apt` will pull in all required dependencies (`pandoc`, `texlive-xetex`, etc.) automatically.

### Step 2 — Configure the LLM provider

Create an operator override file at:

```
/etc/bigbluebutton/ai-summary.yml
```

Add only the keys you want to set — they will be deep-merged over the package defaults:

```yaml
llm:
  # Provider selection: 'claude', 'openai', 'albert', or 'disabled'
  provider: albert

  anthropic_api_key: '...'
  openai_api_key: '...'
  albert_api_key: '...'

  language: 'en'
```

Set `provider: 'disabled'` to skip LLM summarization entirely.

### Step 3 — Configure the transcription backend

Create an operator override file at:

```
/etc/bigbluebutton/post-archive-transcription.yml
```

Add the API keys you want to set. Use `transcriber_path` to select the active backend like so:

```yaml
# Path to the active transcription provider script.
# Both providers are installed — point to the one you want to use:
# Set to "disabled" (or omit) to fall back to the local whisper.cpp binary.
# transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"

language: "en"

albert:
  api_key: "..."

openai:
  api_key: "..."
```

### Step 4 — (Optional) Configure Docs publishing

To automatically publish AI summaries to [La Suite Numérique Docs](https://lasuite.numerique.gouv.fr/) after each meeting, add a `docs:` section to `/etc/bigbluebutton/ai-summary.yml`:

```yaml
docs:
  enabled: true
  docs_host: https://docs.example.com
  keycloak_host: id.example.com
  realm: docs
  client_id: docs
  client_secret: 'your-client-secret'
```

If the `docs:` section is absent or `enabled: false`, the post-publish hook skips the upload silently. At meeting creation, also pass the parent document UUID via the BBB `/create` API:

```
meta_bbb-docs-document-id=<parent-document-uuid>
```

### Step 5 — (Optional) Install whisper.cpp for local fallback transcription

If you prefer not to use a cloud API, you can install whisper.cpp locally. The transcription hook will use it automatically when no `transcribe.rb` provider is active.

```bash
# Install build dependencies
sudo apt install build-essential git cmake ffmpeg

# Clone and build
sudo git clone https://github.com/ggerganov/whisper.cpp.git /usr/local/bin/whisper.cpp
sudo make -C /usr/local/bin/whisper.cpp -j$(nproc)

# Download the base model (~150 MB)
sudo bash /usr/local/bin/whisper.cpp/models/download-ggml-model.sh base
```

To switch back to the local whisper.cpp fallback, set `transcriber_path: "disabled"` (or remove the key) in `/etc/bigbluebutton/post-archive-transcription.yml`.

### Step 6 — Wire the recording pipeline

Edit `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`:

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

### Step 7 — Restart the recording worker

```bash
sudo systemctl restart bbb-rap-resque-worker
```

---

## Deployment from source (deploy.sh)

Previous to all deployment and configuration, keep in mind that this integration will only work with Livekit. See [documentation](https://docs.bigbluebutton.org/new-features/#integration-with-livekit) to better understand how to configure it.

### Step 1 — Configure credentials

All LLM and Docs settings live in the unified `ai-summary.yml` config. `deploy.sh` copies `src/ai-summary/ai-summary.yml` (safe defaults) to the server. To apply credentials without editing that tracked file, create an operator override on the server after deployment:

```bash
sudo vi /etc/bigbluebutton/ai-summary.yml
```

Add only the keys you want to override. For example, to enable Claude summarization and Docs publishing:

```yaml
llm:
  provider: 'claude'            # 'claude', 'openai', 'albert', or 'disabled'
  anthropic_api_key: 'sk-...'  # or set ANTHROPIC_API_KEY env var

docs:
  enabled: true
  docs_host: https://docs.example.com
  keycloak_host: id.example.com
  realm: docs
  client_id: docs
  client_secret: 'your-client-secret'
```

Set `llm.provider: 'disabled'` to skip LLM summarization entirely. If the `docs:` section is absent or `enabled: false`, the post-publish hook skips the upload silently. At meeting creation, also pass the parent document UUID via the BBB `/create` API:

```
meta_bbb-docs-document-id=<parent-document-uuid>
```

### Step 2 — Deploy

`deploy.sh` copies all files to the correct locations on a BBB server and installs whisper.cpp. Requires root.

```bash
./deploy.sh           # deploy everything
./deploy.sh --dry-run # preview without writing
```

| Source | Destination |
|---|---|
| `src/scripts/post_archive/` | `/usr/local/bigbluebutton/core/scripts/post_archive/` |
| `src/ai-summary/process/ai-summary.rb` | `/usr/local/bigbluebutton/core/scripts/process/` |
| `src/ai-summary/publish/ai-summary.rb` | `/usr/local/bigbluebutton/core/scripts/publish/` |
| `src/ai-summary/lib/llm_client.rb` | `/usr/local/bigbluebutton/core/lib/ai-summary/` |
| `src/ai-summary/templates/` | `/usr/local/bigbluebutton/core/playback/ai-summary/` |
| `src/ai-summary/ai-summary.yml` | `/usr/local/bigbluebutton/core/scripts/ai-summary.yml` |
| `ai-summary-playback.nginx` | `/usr/share/bigbluebutton/nginx/ai-summary.nginx` |

### Step 3 — Wire the recording pipeline

Edit `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`:

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

### Step 4 — Restart the recording worker

```bash
sudo systemctl restart bbb-rap-resque-worker
```

### Step 5 — (Recommended) Configure a cloud transcription provider

By default the fallback is a local `whisper.cpp` instance, which works but consumes server CPU. For production use, configure a cloud transcription provider on the server:

```bash
sudo vi /etc/bigbluebutton/post-archive-transcription.yml
```

```yaml
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"

albert:
  api_key: "..."
```

To revert to the local whisper.cpp fallback, set `transcriber_path: "disabled"` or remove the key.

## Transcription

Audio transcription runs as a **post-archive hook** immediately after BBB archives a meeting. It processes every audio track found in `recording/raw/<meeting_id>/audio/` and writes a single merged output file:

```
recording/raw/<meeting_id>/transcription/transcription.json
```

If `transcription.json` already exists the script exits immediately — delete it to force a re-run.

### Back-ends

`transcribe_audio.rb` selects a back-end in this order:

| Priority | Back-end | Active when |
|---|---|---|
| 1 | **Provider script** | `transcriber_path` in `transcription.yml` points to a valid executable |
| 2 | **whisper.cpp** | Built-in fallback, used when no valid `transcriber_path` is set |

### Built-in whisper.cpp fallback

`deploy.sh` installs whisper.cpp to `/usr/local/bin/whisper.cpp` and downloads the `base.en` model. No extra configuration is needed — it is used automatically when no provider script is deployed.

### Provider scripts

Both providers are installed by the Debian package to `/usr/local/bigbluebutton/core/lib/transcription/`. The active one is selected via `transcriber_path` in the transcription config.

**Available providers:**

| File | Provider | Notes |
|---|---|---|
| `openai_whisper.rb` | OpenAI Whisper API (`whisper-1`) | Requires an OpenAI project with audio access |
| `albert_whisper.rb` | Albert API (French gov, `openai/whisper-large-v3`) | Supports optional VAD via `node-vad` |

Both providers use `transcription_utils.rb` to split audio into per-speech chunks derived from `events.xml` talking cues before sending to the API.

**Activating a provider:**

Set `transcriber_path` in `/etc/bigbluebutton/post-archive-transcription.yml`:

```yaml
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"
```

To revert to the whisper.cpp fallback, set `transcriber_path: "disabled"` or remove the key.

**Testing a provider directly against a single audio file:**

```bash
sudo ruby /usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb \
  /var/bigbluebutton/recording/raw/<meeting_id>/audio/<track>.webm \
  /tmp/test_transcription.json \
  /var/bigbluebutton/recording/raw/<meeting_id>/events.xml
```

### Writing a custom provider

A provider script must:

1. Accept three positional arguments: `<audio_file>`, `<output_json_file>`, and `<events_xml_file>`
2. Write a JSON file at `<output_json_file>` with this structure:

```json
{
  "transcription": [
    { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello everyone." }
  ]
}
```

Timestamps (`from` / `to`) are in **milliseconds**. Place the script anywhere accessible, then point `transcriber_path` to it in `/etc/bigbluebutton/post-archive-transcription.yml`.

You can use `transcription_utils.rb` in your own script to get the same audio chunking logic as the bundled providers:

```ruby
require_relative 'transcription_utils'

result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml)
result[:chunks].each { |chunk| ... }  # chunk[:path], chunk[:from_ms], chunk[:to_ms]
TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
```

### API key configuration

Provider scripts read their API key from (in priority order):

1. Environment variable — `OPENAI_API_KEY` (openai_whisper) or `ALBERT_API_KEY` (albert_whisper)
2. `transcription.yml` at `/usr/local/bigbluebutton/core/lib/transcription/transcription.yml`

```yaml
# /usr/local/bigbluebutton/core/lib/transcription/transcription.yml

# For openai_whisper:
openai:
  api_key: 'sk-...'

# For albert_whisper:
albert:
  api_key: '...'
```

### Output format

`transcription.json` merges all tracks into one file:

```json
{
  "meeting_id": "...",
  "generated_at": "2025-01-01T12:00:00Z",
  "tracks": [
    {
      "file": "microphone-<user>-<track>.webm",
      "segments": [
        { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello everyone." }
      ]
    }
  ]
}
```

## LLM Configuration

LLM summarization is **production-only** (the client raises an error when run outside the BBB scripts directory).

Configure the provider via the operator override file on the server:

```bash
sudo vi /etc/bigbluebutton/ai-summary.yml
```

```yaml
llm:
  provider: 'claude'          # 'claude', 'openai', 'albert', or 'disabled'
  anthropic_api_key: 'sk-...' # or set ANTHROPIC_API_KEY env var
```

The base config (with safe defaults) is at `/usr/local/bigbluebutton/core/scripts/ai-summary.yml`. Keys set in `/etc/bigbluebutton/ai-summary.yml` are deep-merged over it at runtime.

### Per-meeting prompt customization

You can append a custom instruction to the LLM system prompt on a per-meeting basis via the BBB `/create` API:

```
meta_bbb-ai-summary-prompt-addition=Focus especially on technical decisions
```

The phrase is appended to the system prompt for both the summary and action items generation. If empty or absent, no change is made.

## Output Files

Each processed recording produces:

| File | Description |
|---|---|
| `ai-summary.pdf` | Original notes PDF (or pandoc-converted from markdown) |
| `ai-summary.md` | Markdown report with notes, transcript, and summary |
| `ai-summary.html` | Standalone HTML report (dark/light mode, print-ready) |
| `transcript.txt` | Plain text transcript, speaker-grouped |
| `transcript_diarized.vtt` | WebVTT transcript with speaker labels and timestamps |
| `summary.txt` | LLM-generated meeting summary (if LLM enabled) |
| `action_items.json` | Structured action items extracted by LLM (if LLM enabled) |
| `metadata.xml` | BBB recording metadata |

## Logs

```bash
# Post-archive transcription (production)
tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log

# Process stage
tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log

# Publish stage
tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log
```

## Dependencies

The following system dependencies are installed automatically by `deploy.sh`:

- **whisper.cpp** — installed to `/usr/local/bin/whisper.cpp`
- **ffmpeg** — audio format conversion (required by whisper.cpp)
- **pandoc** — Markdown to PDF conversion
- **texlive-xetex** — XeLaTeX PDF engine used by pandoc (`--pdf-engine=xelatex`)
- **texlive-fonts-recommended**, **texlive-plain-generic** — font and macro support for XeLaTeX

Ruby gems (install manually or via Bundler):

- `optimist`, `builder`, `nokogiri`, `anthropic` (optional), `openai` (optional)

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — BBB recording pipeline and component details
- [QUICK-GUIDE.md](QUICK-GUIDE.md) — Development workflow and quick reference
- [BigBlueButton Recording Docs](https://docs.bigbluebutton.org/development/recording/)
