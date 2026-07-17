# Operations

This document collects the recurring server-side tasks for running and troubleshooting the `ai-summary` recording format after it has been installed.

For initial setup, see [INSTALLATION.md](INSTALLATION.md). For packaging, source deployment, and implementation details, see [DEVELOPMENT.md](DEVELOPMENT.md).


## Configuration

### Enable multiple transcription providers

Set `transcriber_path` to a list in `/etc/bigbluebutton/post-archive-transcription.yml`:

```yaml
transcriber_path:
  - "/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb"
  - "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"

openai:
  api_key: "..."

albert:
  api_key: "..."
```

Each provider runs independently over all audio tracks. The **first provider** is used for LLM summarization and the HTML/PDF/Markdown report. All providers' diarized transcripts are published as separate JSON files (`transcription_<provider>.json`).

To revert to a single provider or the local whisper.cpp fallback, set `transcriber_path: "disabled"` or remove the key.

### Per-meeting prompt customization

Append a custom instruction to the LLM system prompt via the BBB `/create` API:

```
meta_bbb-ai-summary-prompt-addition=Focus especially on technical decisions
```

The phrase is appended for both summary and action items generation. If empty or absent, the default prompt is used unchanged.

## Reprocessing

### Reprocess a recording

```bash
cd /usr/local/bigbluebutton/core

# Re-run transcription
sudo bundle exec ruby scripts/post_archive/transcribe_audio.rb -m <meeting_id>

# Re-run process stage
sudo ruby scripts/process/ai-summary.rb -m <meeting_id>

# Re-run publish stage
sudo ruby scripts/publish/ai-summary.rb -m <meeting_id>-ai-summary
```

### Force a fresh transcription

```bash
sudo rm /var/bigbluebutton/recording/raw/<meeting_id>/transcription/transcription.json
```

### Force a full rebuild

```bash
MEETING_ID=<meeting_id>
sudo rm -f /var/bigbluebutton/recording/status/processed/${MEETING_ID}-ai-summary.done
sudo rm -f /var/bigbluebutton/recording/status/published/${MEETING_ID}-ai-summary.done
sudo rm -rf /var/bigbluebutton/recording/process/ai-summary/${MEETING_ID}
sudo rm -rf /var/bigbluebutton/published/ai-summary/${MEETING_ID}
```

### Test a provider against a single audio file

```bash
sudo ruby /usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb \
  /var/bigbluebutton/recording/raw/<meeting_id>/audio/<track>.webm \
  /tmp/test_transcription.json \
  /var/bigbluebutton/recording/raw/<meeting_id>/events.xml
```

## Logs and Status

### Watch logs

```bash
sudo tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/bbb-rap-worker.log
```

### Log files

All rotate daily. Each transcription provider writes its own log file, separate from the orchestrator log — check the provider-specific file first when narrowing down whether a transcription failure came from the provider's API or from the orchestrator/pipeline.

| Log file | Stage | Contains |
|---|---|---|
| `/var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log` | Post-archive (orchestrator) | Provider selection, retries, per-file pass/fail, elapsed time |
| `/var/log/bigbluebutton/post_archive-transcribe-albert-<meeting_id>.log` | Post-archive (Albert provider) | Per-chunk Albert API calls and errors (`"Albert API error <code> ..."`) |
| `/var/log/bigbluebutton/post_archive-transcribe-openai_whisper-<meeting_id>.log` | Post-archive (OpenAI Whisper provider) | Per-chunk OpenAI API calls and errors |
| `/var/log/bigbluebutton/post_archive-transcribe-whisper_cpp-<meeting_id>.log` | Post-archive (whisper.cpp fallback) | Local transcription output per chunk |
| `/var/log/bigbluebutton/ai-summary/process-<meeting_id>.log` | Process | Extractors, LLM summary/action-items generation (incl. provider API errors surfaced as `"Albert API HTTP ..."` etc.), LLM timing |
| `/var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log` | Publish | PDF conversion, metadata updates, final copy to publish dir |
| `/var/log/bigbluebutton/bbb-rap-worker.log` | BBB recording pipeline | Not part of this project; the worker that invokes each stage |

### Check pipeline status

```bash
ls /var/bigbluebutton/recording/status/processed/ | grep ai-summary
ls /var/bigbluebutton/recording/status/published/ | grep ai-summary
ls /var/bigbluebutton/published/ai-summary/<meeting_id>/
```

## Common Paths

| Purpose | Path |
|---|---|
| LLM override config | `/etc/bigbluebutton/ai-summary.yml` |
| Transcription override config | `/etc/bigbluebutton/post-archive-transcription.yml` |
| BBB recording pipeline config | `/etc/bigbluebutton/recording/recording.yml` |
| Post-archive script | `/usr/local/bigbluebutton/core/scripts/post_archive/transcribe_audio.rb` |
| Process script | `/usr/local/bigbluebutton/core/scripts/process/ai-summary.rb` |
| Publish script | `/usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb` |
| Published output | `/var/bigbluebutton/published/ai-summary/<meeting_id>/` |
| Raw recording | `/var/bigbluebutton/recording/raw/<meeting_id>/` |

## Notes

- LLM generation runs in production only.
- This integration depends on LiveKit support in BigBlueButton.
- For custom providers and source-level deployment details, use [DEVELOPMENT.md](DEVELOPMENT.md).
