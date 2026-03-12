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

## Installation (Debian package)

> This is the recommended installation method. The `deploy.sh` approach (described further below) is intended for development and testing.

Before installing, keep in mind that this integration only works with LiveKit. See the [documentation](https://docs.bigbluebutton.org/new-features/#integration-with-livekit) for setup details.

### Step 1 — Install the package

```bash
sudo apt install ./bbb-record-ai-summary_0.1.0_all.deb
```

`apt` will pull in all required dependencies (`pandoc`, `texlive-xetex`, etc.) automatically. During installation you will be prompted to choose a transcription backend (`openai_whisper` or `albert_whisper`). This selection can be changed later:

```bash
sudo dpkg-reconfigure bbb-record-ai-summary
```

To pre-seed the answer for automated/scripted installs:

```bash
echo "bbb-record-ai-summary bbb-record-ai-summary/transcription-backend select albert_whisper" \
  | sudo debconf-set-selections
sudo apt install ./bbb-record-ai-summary_0.1.0_all.deb
```

### Step 2 — Configure the LLM provider

The package installs a starter config at:

```
/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml
```

Edit it and set your provider and API key:

```yaml
provider: 'claude'            # 'claude', 'openai', 'albert', or 'disabled'
anthropic_api_key: 'sk-...'  # or set ANTHROPIC_API_KEY env var
```

Set `provider: 'disabled'` to skip LLM summarization entirely.

### Step 3 — Configure the transcription backend

The package creates a starter config at:

```
/usr/local/bigbluebutton/core/lib/transcription/transcription.yml
```

Edit it and fill in the API key for your chosen backend:

```yaml
# For openai_whisper:
openai:
  api_key: 'sk-...'

# For albert_whisper:
albert:
  api_key: '...'
```

### Step 4 — (Optional) Configure Docs publishing

To automatically publish AI summaries to [La Suite Numérique Docs](https://lasuite.numerique.gouv.fr/) after each meeting, edit:

```
/usr/local/bigbluebutton/core/lib/ai-summary/docs.yml
```

Fill in your Keycloak OIDC client credentials. If this file is absent or unconfigured, the post-publish hook skips the upload silently. At meeting creation, also pass the parent document UUID via the BBB `/create` API:

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

To switch back to the local fallback after having used a cloud provider:

```bash
sudo rm /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
```

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

### Step 6 — Restart the recording worker

```bash
sudo systemctl restart bbb-rap-resque-worker
```

---

## Deployment from source (deploy.sh)

Previous to all deployment and configuration, keep in mind that this integration will only work with Livekit. See [documentation](https://docs.bigbluebutton.org/new-features/#integration-with-livekit) to better understand how to configure it.

### Step 1 — Copy and configure the credential files

Both files below are read by `deploy.sh` and copied to the server. Configure them before running the deploy script.

**LLM provider** (`src/ai-summary/llm.yml`):

```bash
cp src/ai-summary/llm.yml.example src/ai-summary/llm.yml
```

Edit `src/ai-summary/llm.yml` and properly configure the provider. It will be one of the following:

- disabled;
- openai;
- claude;
- albert;

Set `provider: 'disabled'` to skip LLM summarization entirely. After deployment this file lives at `/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml`.

**Docs publishing** (`src/ai-summary/docs.yml`, optional):

```bash
cp src/ai-summary/docs.yml.example src/ai-summary/docs.yml
```

Edit `src/ai-summary/docs.yml` with your [La Suite Numérique Docs](https://lasuite.numerique.gouv.fr/) Keycloak OIDC client credentials.

If this file is absent, the post-publish hook skips the upload silently. At meeting creation, also pass the parent document UUID via the BBB `/create` API:

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
| `src/ai-summary/llm.yml` | `/usr/local/bigbluebutton/core/lib/ai-summary/` |
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

### Step 5 — (Recommended) Deploy a back-end transcription provider

By default the fallback is a local `whisper.cpp` instance, which works but consumes server CPU. For production use, configure a cloud transcription provider:

```bash
cp src/scripts/transcription/transcription.yml.example src/scripts/transcription/transcription.yml
```

Edit `src/scripts/transcription/transcription.yml` and fill in your API key:

```yaml
openai_api_key: "sk-..."       # for openai_whisper
# albert_api_key: "your-key"  # for albert_whisper
```

Then deploy the provider of your choice (this also copies `transcription.yml` to the server):

```bash
./deploy_transcription.sh openai_whisper   # OpenAI Whisper API
# or
./deploy_transcription.sh albert_whisper   # Albert (French gov API)
```

To revert to the local whisper.cpp fallback at any time:

```bash
sudo rm /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
```

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
| 1 | **Provider script** | `transcribe.rb` exists in the transcription lib dir (see below) |
| 2 | **whisper.cpp** | Built-in fallback, installed by `deploy.sh` |

### Built-in whisper.cpp fallback

`deploy.sh` installs whisper.cpp to `/usr/local/bin/whisper.cpp` and downloads the `base.en` model. No extra configuration is needed — it is used automatically when no provider script is deployed.

### Provider scripts

Provider scripts live in `src/scripts/transcription/`. Each script is a self-contained Ruby file that is deployed as `transcribe.rb` in the transcription lib dir on the server. Only one provider is active at a time.

**Available providers:**

| File | Provider | Notes |
|---|---|---|
| `openai_whisper.rb` | OpenAI Whisper API (`whisper-1`) | Requires an OpenAI project with audio access |
| `albert_whisper.rb` | Albert API (French gov, `openai/whisper-large-v3`) | Supports optional VAD via `node-vad` |

Both providers use `transcription_utils.rb` to split audio into per-speech chunks derived from `events.xml` talking cues before sending to the API.

**Deploying a provider:**

```bash
./deploy_transcription.sh openai_whisper   # deploy the OpenAI Whisper provider
./deploy_transcription.sh albert_whisper   # deploy the Albert provider
./deploy_transcription.sh openai_whisper --dry-run  # preview without writing
```

This copies `src/scripts/transcription/<provider>.rb` to:

```
/usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
```

and also copies `transcription_utils.rb` to the same directory, then makes `transcribe.rb` executable. To revert to the whisper.cpp fallback, remove that file:

```bash
sudo rm /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
```

**Testing a provider directly against a single audio file:**

```bash
sudo ruby /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb \
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

Timestamps (`from` / `to`) are in **milliseconds**. Place the script in `src/scripts/transcription/<name>.rb` and deploy it with `deploy_transcription.sh <name>`.

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

Copy the example config and set your provider:

```bash
cp src/ai-summary/llm.yml.example src/ai-summary/llm.yml
```

```yaml
# src/ai-summary/llm.yml
provider: 'claude'          # 'claude', 'openai', or 'disabled'
anthropic_api_key: 'sk-...' # or set ANTHROPIC_API_KEY env var
```

After deployment, the config lives at `/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml`.

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
