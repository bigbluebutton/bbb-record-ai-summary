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

Run these from `scripts/` as the `bigbluebutton` user: the stages need the bundled
gems (`bundle exec`), the process stage loads `ai-summary.yml` relative to the
working directory, and running as root leaves root-owned files the worker can't
rewrite later.

```bash
cd /usr/local/bigbluebutton/core/scripts

# Re-run transcription
sudo -u bigbluebutton bundle exec ruby post_archive/transcribe_audio.rb -m <meeting_id>

# Re-run process stage
sudo -u bigbluebutton bundle exec ruby process/ai-summary.rb -m <meeting_id>

# Re-run publish stage
sudo -u bigbluebutton bundle exec ruby publish/ai-summary.rb -m <meeting_id>-ai-summary
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
cd /usr/local/bigbluebutton/core/scripts
sudo -u bigbluebutton bundle exec ruby ../lib/transcription/albert_whisper.rb \
  /var/bigbluebutton/recording/raw/<meeting_id>/audio/<track>.webm \
  /tmp/test_transcription.json \
  /var/bigbluebutton/recording/raw/<meeting_id>/events.xml
```

Without `bundle exec` this fails with `cannot load such file -- nokogiri`.

## Logs and Status

### Which log holds what

Everything is under `/var/log/bigbluebutton/`, one file per meeting except where noted.

| Question | Log | Grep for |
|---|---|---|
| Did transcription run, and how long did it take? | `post_archive-transcribe-<meeting_id>.log` | `AI_SUMMARY_METRICS`, `Elapsed time` |
| Did the ASR provider misbehave? | `post_archive-transcribe-albert-<meeting_id>.log`, `post_archive-transcribe-openai_whisper-<meeting_id>.log` | `PROVIDER_ERROR`, `[ERROR]` |
| Did the summary fail, and whose fault was it? | `ai-summary/process-<meeting_id>.log` | `AI_SUMMARY_ERROR`, `kind=` |
| How long did each LLM call take? | `ai-summary/process-<meeting_id>.log` | `LLM call op=` |
| Did publishing or PDF conversion fail? | `ai-summary/publish-<meeting_id>.log` | `AI_SUMMARY_ERROR`, `pandoc` |
| Was the recording queued and did the worker succeed? | `journalctl -u bbb-rap-resque-worker` (global) | the meeting ID |

> Per-meeting logs are **appended** on every reprocess and are **not** rotated —
> `/etc/logrotate.d/bbb-record-core.logrotate` covers only `bbb-rap-worker.log`
> and `sanity.log`. Each run is delimited by an `AI_SUMMARY_RUN_START` line, and
> every metrics line carries a `run_id`, so never derive a duration by
> differencing the first and last timestamps in one of these files.

### Is it the provider or the module?

Every failure in the LLM path emits one classified line. The `kind=` field is the answer:

```bash
grep AI_SUMMARY_ERROR /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log
```

| `kind=` | Meaning | What to do |
|---|---|---|
| `PROVIDER_ERROR` | The provider returned a non-2xx, a non-JSON body, an empty completion, or the connection timed out. The line carries `provider=`, `http_status=` and the first 300 bytes of the provider's response. | Raise it with the provider, quoting `http_status` and `msg`. |
| `CONFIG_ERROR` | Missing API key, unknown provider, unreadable config. | Fix `/etc/bigbluebutton/ai-summary.yml` on this server. |
| `MODULE_ERROR` | A defect in this module. The line is followed by the first 10 backtrace frames. | File a bug with the backtrace. |

ASR providers use the same vocabulary in their own logs, e.g.
`PROVIDER_ERROR Albert API HTTP 502 for microphone-….webm: …`.
When at least half the audio chunks fail with API errors, the provider script
exits non-zero so the pipeline retries — rather than publishing an empty
transcript as an apparent success.

### Processing time

Each stage emits one self-contained [logfmt](https://brandur.org/logfmt) line, so
no timestamp arithmetic is needed:

```bash
grep 'stage=pipeline' /var/log/bigbluebutton/ai-summary/publish-*.log
```

```
AI_SUMMARY_METRICS v=1 stage=pipeline meeting_id=… run_id=1786670563-31415 outcome=ok status=ok
  asr_provider=openai_whisper llm_provider=claude llm_model=claude-opus-5
  transcription_ms=3637 process_ms=10412 llm_summary_ms=8294 llm_action_items_ms=2005
  publish_ms=2466 pdf_ms=2459 total_ms=16515 complete=true
```

| Field | Meaning |
|---|---|
| `outcome` | Did the stage produce what it exists to produce — see the table below. On the `stage=pipeline` line it is the worst of the three stages |
| `status` | What the recording ended up with: `ok`, `no-summary` (the LLM failed), or `disabled` (`llm.provider: disabled`, so no summary was ever meant to exist). Absent when the process stage's timings could not be read |
| `transcription_ms` | Whole post_archive stage, all providers (they run concurrently, so this is wall time, not the sum) |
| `process_ms` | The process stage — extraction, LLM calls, rendering |
| `llm_summary_ms`, `llm_action_items_ms` | The individual LLM calls, retries included. Usually ~99 % of `process_ms` |
| `publish_ms`, `pdf_ms` | Publish stage, and the pandoc PDF conversion within it |
| `total_ms` | Sum of the three stage durations. **Excludes** queue waits between workers, so it is processing cost, not user-perceived latency |
| `complete` | `false` when a stage duration was unavailable (e.g. a cached transcript) — treat the total as partial |

### Sweeping for bad runs

`outcome` answers one question per stage: did it produce what it exists to produce?

| `outcome` | Meaning | Exit code |
|---|---|---|
| `ok` | Produced everything | 0 |
| `degraded` | Ran to completion and the recording published, but something inside was lost — an LLM call failed, the PDF did not convert, or some audio tracks did not transcribe. The neighbouring fields (`llm_failed_calls`, `pdf_ms`, `tracks_failed`) say which | 0 |
| `failed` | Produced nothing; the script raised and the pipeline should retry | 1 |

So one grep finds every run worth looking at:

```bash
grep -h AI_SUMMARY_METRICS /var/log/bigbluebutton/ai-summary/*.log \
  /var/log/bigbluebutton/post_archive-transcribe-*.log | grep -v 'outcome=ok'
```

Note that `outcome` is per **stage**. The `LLM call op=… outcome=` lines in the process
log are a different, per-call signal — one failed call among several is what makes the
stage `degraded`.

Two caveats when reading the `stage=pipeline` rollup:

- It reports the worst stage it has data for, so a stage that emitted nothing (see the
  skip conditions below) cannot drag it down.
- Transcription is skipped outright when `transcription.json` already exists, and that
  skip does not rewrite the stage's timings file. Compare the rollup's
  `transcription_run_id` against the transcription log's own `AI_SUMMARY_RUN_START`
  before trusting the transcription half of a reprocessed recording.

Mean processing time across all recordings on the server:

```bash
grep -h 'stage=pipeline' /var/log/bigbluebutton/ai-summary/publish-*.log \
  | grep -o 'total_ms=[0-9]*' | cut -d= -f2 \
  | awk '{ sum += $1; n++ } END { printf "n=%d mean=%.1fs\n", n, sum/n/1000 }'
```

The same numbers are on the recording itself, so monitoring can read them from
the API instead of the logs — `getRecordings` returns per-format
`<processingTime>` (the process step, in ms, directly comparable with the
`presentation` format) and the whole-pipeline figures as `<metadata>` keys:

```
<bbb-ai-summary-status>ok</bbb-ai-summary-status>
<bbb-ai-summary-total-ms>16515</bbb-ai-summary-total-ms>
<bbb-ai-summary-transcription-ms>3637</bbb-ai-summary-transcription-ms>
<bbb-ai-summary-process-ms>10412</bbb-ai-summary-process-ms>
<bbb-ai-summary-publish-ms>2466</bbb-ai-summary-publish-ms>
<bbb-ai-summary-llm-ms>10299</bbb-ai-summary-llm-ms>
<bbb-ai-summary-llm-provider>claude</bbb-ai-summary-llm-provider>
<bbb-ai-summary-asr-provider>openai_whisper</bbb-ai-summary-asr-provider>
```

`bbb-ai-summary-status` is `ok` when a summary was produced, `no-summary` when the
LLM failed but the recording still published — the case that used to be invisible
without reading the logs — and `disabled` when `llm.provider` is `disabled`, so a
server that deliberately runs without an LLM does not look like a server whose LLM
is broken.

### Watch logs

```bash
sudo tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log
sudo journalctl -fu bbb-rap-resque-worker
```

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
| BBB recording pipeline config | `/etc/bigbluebutton/recording/recording.yml` (operator override; create it — shallow-merged over `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`) |
| Post-archive script | `/usr/local/bigbluebutton/core/scripts/post_archive/transcribe_audio.rb` |
| Process script | `/usr/local/bigbluebutton/core/scripts/process/ai-summary.rb` |
| Publish script | `/usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb` |
| Published output | `/var/bigbluebutton/published/ai-summary/<meeting_id>/` |
| Raw recording | `/var/bigbluebutton/recording/raw/<meeting_id>/` |

## Notes

- LLM generation runs in production only.
- This integration depends on LiveKit support in BigBlueButton.
- For custom providers and source-level deployment details, use [DEVELOPMENT.md](DEVELOPMENT.md).
