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
├── recording/                         # Test workspace (gitignored)
│   ├── raw/                           # Raw recordings input
│   ├── process/ai-summary/            # Process stage output
│   ├── publish/ai-summary/            # Publish stage output
│   └── status/                        # .done / .fail marker files
├── logs/                              # Processing logs (gitignored)
└── deploy.sh                          # Deploy to production BBB server
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

## Custom Transcription Back-end

To replace whisper.cpp with your own transcription service, drop a `transcribe.sh` script next to `transcribe_audio.rb`:

```
/usr/local/bigbluebutton/core/scripts/post_archive/transcribe.sh
```

It is called as:
```bash
transcribe.sh <audio_file> <output_json_file>
```

The output JSON must contain a `"transcription"` array of segment objects:
```json
[
  { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello everyone." }
]
```

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
- **pandoc + texlive-latex** — Markdown to PDF conversion
- **Ruby gems**: `optimist`, `builder`, `nokogiri`, `anthropic` (optional), `openai` (optional)

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — BBB recording pipeline and component details
- [QUICK-GUIDE.md](QUICK-GUIDE.md) — Development workflow and quick reference
- [BigBlueButton Recording Docs](https://docs.bigbluebutton.org/development/recording/)
