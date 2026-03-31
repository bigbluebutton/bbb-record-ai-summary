# Development

This document covers package building, deployment from source, and advanced implementation details that do not belong in the main project overview.

For first-time server setup, see [INSTALLATION.md](INSTALLATION.md). For day-to-day commands and troubleshooting, see [OPERATIONS.md](OPERATIONS.md).

## Build the Debian Package

Install the build dependency:

```bash
sudo apt install debhelper
```

Build the package:

```bash
./build.sh
```

The output package is created as `../bbb-record-ai-summary_*.deb`.

## Deploy From Source

This integration only works with LiveKit-enabled BigBlueButton deployments. See the [BigBlueButton LiveKit documentation](https://docs.bigbluebutton.org/new-features/#integration-with-livekit) before deploying.

### Deploy files

`deploy.sh` copies project files into the expected BBB locations and installs the local `whisper.cpp` fallback.

```bash
./deploy.sh
./deploy.sh --dry-run
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

### Runtime configuration model

Project defaults are deployed into BBB-managed locations. Operator-specific configuration should be stored in override files under `/etc/bigbluebutton/`.

Use [OPERATIONS.md](OPERATIONS.md) for the standard runtime configuration files and common server-side commands. This document only covers the advanced behavior behind those settings.

## LLM and Docs Publishing

### LLM providers

Supported `llm.provider` values:

- `claude`
- `openai`
- `albert`
- `disabled`

LLM summarization is production-only.

### Per-meeting prompt customization

You can append custom prompt text through the BBB `/create` API:

```text
meta_bbb-ai-summary-prompt-addition=Focus especially on technical decisions
```

### Docs publishing

If Docs publishing is enabled, the BBB `/create` API must also include the parent document identifier:

```text
meta_bbb-docs-document-id=<parent-document-uuid>
```

If the `docs` section is absent or `enabled: false`, the post-publish upload is skipped.

Typical Docs-related settings live under the `docs:` section of `/etc/bigbluebutton/ai-summary.yml`.

## Transcription Internals

Audio transcription runs as a post-archive hook after BBB archives the meeting. It processes audio tracks in:

```text
recording/raw/<meeting_id>/audio/
```

and writes:

```text
recording/raw/<meeting_id>/transcription/transcription.json
```

If `transcription.json` already exists, the transcription step exits early.

### Backend selection

`transcribe_audio.rb` uses this order:

| Priority | Backend | Active when |
|---|---|---|
| 1 | Provider script | `transcriber_path` points to a valid executable |
| 2 | `whisper.cpp` | No valid provider script is configured |

### Bundled providers

| File | Provider | Notes |
|---|---|---|
| `openai_whisper.rb` | OpenAI Whisper API | Requires OpenAI audio access |
| `albert_whisper.rb` | Albert API | Supports optional VAD via `node-vad` |

Both providers use `transcription_utils.rb` for chunking audio based on `events.xml` talking cues.

### API key resolution

Provider scripts resolve keys in this order:

1. Environment variable
2. `/etc/bigbluebutton/post-archive-transcription.yml`
3. Base config in BBB-managed paths

Recommended practice is to keep secrets in `/etc/bigbluebutton/` overrides.

### Test a provider directly

```bash
sudo ruby /usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb \
  /var/bigbluebutton/recording/raw/<meeting_id>/audio/<track>.webm \
  /tmp/test_transcription.json \
  /var/bigbluebutton/recording/raw/<meeting_id>/events.xml
```

### Write a custom provider

A provider script must:

1. Accept `<audio_file>`, `<output_json_file>`, and `<events_xml_file>` as positional arguments.
2. Write JSON to `<output_json_file>` in this shape:

```json
{
  "transcription": [
    { "offsets": { "from": 1200, "to": 4800 }, "text": "Hello everyone." }
  ]
}
```

Timestamps are in milliseconds.

You can reuse the bundled helper:

```ruby
require_relative 'transcription_utils'

result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml)
result[:chunks].each { |chunk| ... }
TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
```

## Local Development Workflow

There is no dedicated local test harness for the full BBB pipeline. The usual workflow is:

1. Edit files under `src/`.
2. Deploy to a BBB server with `./deploy.sh`.
3. Trigger or reprocess a recording.
4. Inspect logs and generated outputs with the commands in [OPERATIONS.md](OPERATIONS.md).

### Update templates without a full redeploy

```bash
sudo cp src/ai-summary/templates/ai-summary.md.erb \
  /usr/local/bigbluebutton/core/playback/ai-summary/ai-summary.md.erb

sudo cp src/ai-summary/templates/ai-summary.html.erb \
  /usr/local/bigbluebutton/core/playback/ai-summary/ai-summary.html.erb
```

## Reference Paths

| Purpose | Path |
|---|---|
| Transcription shared utils | `/usr/local/bigbluebutton/core/lib/transcription/transcription_utils.rb` |
| OpenAI provider | `/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb` |
| Albert provider | `/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb` |
| Base transcription config | `/usr/local/bigbluebutton/core/lib/transcription/transcription.yml` |
| LLM client | `/usr/local/bigbluebutton/core/lib/ai-summary/llm_client.rb` |
| Templates | `/usr/local/bigbluebutton/core/playback/ai-summary/` |
| Base format config | `/usr/local/bigbluebutton/core/scripts/ai-summary.yml` |
| Nginx config | `/usr/share/bigbluebutton/nginx/ai-summary.nginx` |
