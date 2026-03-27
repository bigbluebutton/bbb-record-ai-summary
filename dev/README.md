# Test Harness

Run the full ai-summary pipeline (transcription, process, publish) against recorded meetings without needing a live BigBlueButton session. Works on both BBB servers and standalone machines.

## Prerequisites

**On a BBB server** (has `/usr/local/bigbluebutton/core/lib/recordandplayback.rb`):
- No extra setup needed — the harness uses the existing BBB libraries via `bundle exec`.

**On a non-BBB machine:**
- Ruby with gems: `nokogiri`, `optimist`, `builder`
- `ffmpeg` (audio conversion)
- `pandoc` + `texlive-xetex` (PDF generation)
- `node` + `npm install -g node-vad` (optional, for VAD filtering)
- Run `./test/run_pipeline.sh --setup-only` once to install the BBB library shim (requires sudo).

**For transcription** (calls OpenAI Whisper API):
- Create `/etc/bigbluebutton/post-archive-transcription.yml` with your API key:
  ```yaml
  transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb"
  openai:
    api_key: "sk-..."
  ```

## Test recordings

Place `.tar.gz` archives of raw BBB recordings in `test-recordings/`. Each archive should contain a directory named by the meeting ID with this structure:

```
<meeting_id>/
├── audio/           # .webm audio tracks (one per speaker)
├── events.xml       # BBB event log
├── notes/           # notes.html, notes.pdf (optional)
├── presentation/    # slides (optional)
└── transcription/   # transcription.json (optional, pre-computed)
```

## Usage

```bash
# Full pipeline (transcription + process + publish, no LLM)
./test/run_pipeline.sh test-recordings/<meeting_id>.tar.gz --skip-llm

# Skip transcription (use pre-existing transcription.json from tarball)
./test/run_pipeline.sh test-recordings/<meeting_id>.tar.gz --skip-transcription --skip-llm

# Force re-transcription (clean + delete bundled transcription.json)
./test/run_pipeline.sh test-recordings/<meeting_id>.tar.gz --force-retranscribe --skip-llm

# Clean workspace and re-run
./test/run_pipeline.sh test-recordings/<meeting_id>.tar.gz --clean --skip-llm
```

### Options

| Flag | Description |
|------|-------------|
| `--skip-transcription` | Skip the transcription step, use existing `transcription.json` |
| `--skip-llm` | Disable LLM summarization (sets `provider: disabled`) |
| `--clean` | Wipe workspace before running (re-unpacks tarball) |
| `--force-retranscribe` | Like `--clean` but also deletes `transcription.json` to force full reprocessing |
| `--setup-only` | Create the BBB directory tree with shim library (non-BBB machines only) |
| `--teardown` | Remove the shim BBB directory tree |

## Output

Processed files are written to `published/ai-summary/<meeting_id>/`:

| File | Description |
|------|-------------|
| `ai-summary.html` | Standalone HTML report with transcript viewer |
| `ai-summary.json` | JSON output with all extracted data |
| `ai-summary.md` | Markdown report |
| `ai-summary.pdf` | PDF report (generated via pandoc) |
| `transcription.vtt` | WebVTT transcript with speaker labels |
| `transcription.json` | Diarized transcript as JSON |
| `metadata.xml` | BBB recording metadata |

Logs are written to `logs/ai-summary/`.

### Web preview

On a BBB server with HTTPS configured, the harness automatically copies output to `/var/www/bigbluebutton-default/assets/<meeting_id>/` and prints a preview URL. Open it in a browser to review the HTML report and view text files inline.

## How it works

The pipeline scripts (`process/ai-summary.rb`, `publish/ai-summary.rb`, `transcribe_audio.rb`) detect whether they're running from the BBB scripts directory or from the source tree, and adjust config paths accordingly:

- **BBB server**: runs via `bundle exec` using the real BBB `recordandplayback` library. Scripts see the dev `__dir__` path and read configs from `src/`.
- **Non-BBB machine**: `--setup-only` creates `/usr/local/bigbluebutton/core/` with a shim library (`test/lib/recordandplayback.rb`) that implements the subset of BBB methods the scripts use. Scripts are symlinked into the BBB tree so `__dir__` resolves to production paths.

### Directory layout during a test run

```
recording/                    # workspace (gitignored)
├── raw/<meeting_id>/         # unpacked from tarball
├── process/ai-summary/       # process stage output (cleaned up after publish)
├── publish/ai-summary/       # publish staging area (cleaned up after publish)
└── status/                   # .done / .fail status files

published/ai-summary/         # final output (gitignored)
└── <meeting_id>/

logs/ai-summary/              # process and publish logs (gitignored)
```

## Shim library

`test/lib/recordandplayback.rb` is a standalone replacement for BBB's recording library. It implements only the methods the ai-summary scripts actually call:

- `BigBlueButton.logger` — logger get/set (defaults to stdout)
- `BigBlueButton.add_tag_to_xml` — XML manipulation via Nokogiri
- `BigBlueButton.add_raw_size_to_metadata` / `add_playback_size_to_metadata`
- `BigBlueButton.execute` / `exec_ret` — shell command execution
- `BigBlueButton::Events.get_meeting_metadata` — parse events.xml metadata
- `BigBlueButton::Events.get_num_participants` — count unique participants
- `BigBlueButton::Events.first_event_timestamp` / `get_recording_length`

No external gem dependencies beyond `nokogiri` (already required by the scripts).
