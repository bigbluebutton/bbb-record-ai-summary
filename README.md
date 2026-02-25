# bbb-playback-ai — `ai-summary` Recording Format

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

## Project Structure

```
bbb-playback-ai/
├── src/
│   ├── ai-summary/
│   │   ├── process/
│   │   │   └── ai-summary.rb          # BBB process stage script
│   │   ├── publish/
│   │   │   └── ai-summary.rb          # BBB publish stage script
│   │   ├── lib/
│   │   │   └── llm_client.rb          # Multi-provider LLM abstraction
│   │   ├── templates/
│   │   │   ├── ai-summary.md.erb      # Markdown output template
│   │   │   └── ai-summary.html.erb    # HTML output template
│   │   ├── ai-summary.yml             # Format configuration
│   │   ├── llm.yml.example            # LLM config template (copy → llm.yml)
│   │   └── ai-summary-playback.nginx  # Nginx location block
│   └── scripts/
│       └── post_archive/
│           └── transcribe_audio.rb    # Post-archive audio transcription hook
│   └── scripts/
│       ├── post_archive/
│       │   └── transcribe_audio.rb    # Post-archive audio transcription hook
│       └── transcription/             # Provider scripts (deploy one as transcribe.rb)
│           └── openai_whisper.rb      # OpenAI Whisper API provider
├── recording/                         # Test workspace (gitignored)
│   ├── raw/                           # Raw recordings input
│   ├── process/ai-summary/            # Process stage output
│   ├── publish/ai-summary/            # Publish stage output
│   └── status/                        # .done / .fail marker files
├── logs/                              # Processing logs (gitignored)
├── deploy.sh                          # Deploy to production BBB server
└── deploy_transcription.sh            # Deploy a transcription provider
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

**Deploying a provider:**

```bash
./deploy_transcription.sh openai_whisper   # deploy the OpenAI Whisper provider
./deploy_transcription.sh openai_whisper --dry-run  # preview without writing
```

This copies `src/scripts/transcription/openai_whisper.rb` to:

```
/usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
```

and makes it executable. To revert to the whisper.cpp fallback, remove that file:

```bash
sudo rm /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
```

**Testing a provider directly against a single audio file:**

```bash
sudo ruby /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb \
  /var/bigbluebutton/recording/raw/<meeting_id>/audio/<track>.webm \
  /tmp/test_transcription.json
```

### Writing a custom provider

A provider script must:

1. Accept two positional arguments: `<audio_file>` and `<output_json_file>`
2. Write a JSON file at `<output_json_file>` with this structure:

```json
{
  "transcription": [
    { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello everyone." }
  ]
}
```

Timestamps (`from` / `to`) are in **milliseconds**. Place the script in `src/scripts/transcription/<name>.rb` and deploy it with `deploy_transcription.sh <name>`.

### API key configuration

Provider scripts read the OpenAI API key from (in priority order):

1. `OPENAI_API_KEY` environment variable
2. `openai_api_key` field in `/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml`

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

## Deployment

`deploy.sh` copies all files to the correct locations on a BBB server and installs whisper.cpp. Requires root.

```bash
./deploy.sh           # deploy everything
./deploy.sh --dry-run # preview without writing
```

What it deploys:

| Source | Destination |
|---|---|
| `src/scripts/post_archive/` | `/usr/local/bigbluebutton/core/scripts/post_archive/` |
| `src/ai-summary/process/ai-summary.rb` | `/usr/local/bigbluebutton/core/scripts/process/` |
| `src/ai-summary/publish/ai-summary.rb` | `/usr/local/bigbluebutton/core/scripts/publish/` |
| `src/ai-summary/lib/llm_client.rb` | `/usr/local/bigbluebutton/core/lib/ai-summary/` |
| `src/ai-summary/llm.yml` | `/usr/local/bigbluebutton/core/lib/ai-summary/` |
| `src/ai-summary/templates/` | `/usr/local/bigbluebutton/core/playback/ai-summary/` |
| `src/ai-summary/ai-summary.yml` | `/usr/local/bigbluebutton/core/scripts/ai-summary.yml` |
| `src/ai-summary/ai-summary-playback.nginx` | `/usr/share/bigbluebutton/nginx/ai-summary.nginx` |

After deployment, wire the format into the BBB recording pipeline by editing `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`:

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

Then restart the recording worker:

```bash
systemctl restart bbb-rap-resque-worker
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

- **whisper.cpp** — installed by `deploy.sh` to `/usr/local/bin/whisper.cpp`
- **ffmpeg** — audio format conversion (for whisper.cpp)
- **pandoc + texlive-xetex** — Markdown to PDF conversion
- **Ruby gems**: `optimist`, `builder`, `nokogiri`, `anthropic` (optional), `openai` (optional)

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — BBB recording pipeline and component details
- [QUICK-GUIDE.md](QUICK-GUIDE.md) — Development workflow and quick reference
- [BigBlueButton Recording Docs](https://docs.bigbluebutton.org/development/recording/)
