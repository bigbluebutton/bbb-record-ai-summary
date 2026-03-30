# Quick Guide

## Deploy to Production

```bash
# Deploy everything (requires root, auto-elevates with sudo)
./deploy.sh

# Preview what would be deployed without writing files
./deploy.sh --dry-run
```

After the first deploy, add `ai-summary` to the BBB pipeline (one-time step):

```bash
sudo vi /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml
```

Add under `steps`:
```yaml
captions:
  - "process:presentation"
  - "process:ai-summary"
"process:ai-summary": "publish:ai-summary"
```

Restart the worker:
```bash
sudo systemctl restart bbb-rap-resque-worker
```

---

## Development Workflow

There is no local test harness. To develop and test changes:

1. **Edit** source files in `src/`
2. **Deploy** to your BBB server with `./deploy.sh`
3. **Trigger** a recording on BBB (or reprocess an existing one — see below)
4. **Check logs** to verify behavior

### Reprocess an existing recording

```bash
# Re-run post_archive (transcription)
cd /usr/local/bigbluebutton/core
sudo bundle exec ruby scripts/post_archive/transcribe_audio.rb -m <meeting_id>

# Remove transcription.json if you need to re-transcribe
sudo rm /var/bigbluebutton/recording/raw/<meeting_id>/transcription/transcription.json

# Re-run process stage
sudo ruby /usr/local/bigbluebutton/core/scripts/process/ai-summary.rb \
  -m <meeting_id>

# Re-run publish stage
sudo ruby /usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb \
  -m <meeting_id>-ai-summary
```

To force a full reprocess, remove the status and output files first:
```bash
MEETING_ID=<your_meeting_id>
sudo rm -f /var/bigbluebutton/recording/status/processed/${MEETING_ID}-ai-summary.done
sudo rm -f /var/bigbluebutton/recording/status/published/${MEETING_ID}-ai-summary.done
sudo rm -rf /var/bigbluebutton/recording/process/ai-summary/${MEETING_ID}
sudo rm -rf /var/bigbluebutton/published/ai-summary/${MEETING_ID}
```

---

## Logs

```bash
# Post-archive transcription
sudo tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log

# Process stage
sudo tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log

# Publish stage
sudo tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log

# BBB recording worker (overall pipeline)
sudo tail -f /var/log/bigbluebutton/bbb-rap-worker.log
```

---

## Configure LLM Summarization

Edit the operator override on the server:

```bash
sudo vi /etc/bigbluebutton/ai-summary.yml
```

Minimal config for Claude:
```yaml
llm:
  provider: 'claude'
  anthropic_api_key: 'sk-ant-...'
```

Minimal config for OpenAI:
```yaml
llm:
  provider: 'openai'
  openai_api_key: 'sk-...'
```

To disable:
```yaml
llm:
  provider: 'disabled'
```

> LLM calls only run in production — the client raises an error when invoked from a dev checkout.

---

## Configure Transcription Back-ends

`transcriber_path` accepts a single path string or an array. Each entry is a separate provider run independently; the first provider drives LLM summarization and the report.

**Single provider:**
```yaml
# /etc/bigbluebutton/post-archive-transcription.yml
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb"
```

**Multiple providers:**
```yaml
# /etc/bigbluebutton/post-archive-transcription.yml
transcriber_path:
  - "/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb"
  - "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"
```

Each provider produces its own published `transcription_<name>.json` in the same diarized format.

## Write a Custom Transcription Back-end

A provider script must accept three positional arguments and produce a JSON file:

```ruby
#!/usr/bin/env ruby
audio_file  = ARGV[0]  # path to the audio track
output_json = ARGV[1]  # path to write output JSON
events_xml  = ARGV[2]  # path to events.xml (for talking cues / timestamps)

# Call your transcription service and write output to output_json.
# Output must be valid JSON:
# { "transcription": [{ "offsets": { "from": <ms>, "to": <ms> }, "text": "..." }] }
```

Make it executable, then add it to `transcriber_path` in `/etc/bigbluebutton/post-archive-transcription.yml`.

---

## File Locations (Production)

| Purpose | Path |
|---|---|
| Post-archive script | `/usr/local/bigbluebutton/core/scripts/post_archive/transcribe_audio.rb` |
| Transcription shared utils | `/usr/local/bigbluebutton/core/lib/transcription/transcription_utils.rb` |
| OpenAI Whisper provider | `/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb` |
| Albert Whisper provider | `/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb` |
| Transcription config | `/usr/local/bigbluebutton/core/lib/transcription/transcription.yml` |
| Transcription config override | `/etc/bigbluebutton/post-archive-transcription.yml` |
| Process script | `/usr/local/bigbluebutton/core/scripts/process/ai-summary.rb` |
| Publish script | `/usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb` |
| LLM client | `/usr/local/bigbluebutton/core/lib/ai-summary/llm_client.rb` |
| Templates | `/usr/local/bigbluebutton/core/playback/ai-summary/` |
| Format config | `/usr/local/bigbluebutton/core/scripts/ai-summary.yml` |
| Format config override | `/etc/bigbluebutton/ai-summary.yml` |
| Nginx config | `/usr/share/bigbluebutton/nginx/ai-summary.nginx` |
| Published recordings | `/var/bigbluebutton/published/ai-summary/<meeting_id>/` |
| Raw recordings | `/var/bigbluebutton/recording/raw/<meeting_id>/` |
| whisper.cpp binary | `/usr/local/bin/whisper.cpp/build/bin/whisper-cli` |
| whisper.cpp model | `/usr/local/bin/whisper.cpp/models/ggml-base.en.bin` |

---

## Edit Templates Without Full Redeploy

Templates can be copied individually:

```bash
# Markdown template
sudo cp src/ai-summary/templates/ai-summary.md.erb \
  /usr/local/bigbluebutton/core/playback/ai-summary/ai-summary.md.erb

# HTML template
sudo cp src/ai-summary/templates/ai-summary.html.erb \
  /usr/local/bigbluebutton/core/playback/ai-summary/ai-summary.html.erb
```

Then reprocess a recording to see the changes.

---

## Check Pipeline Status

```bash
# List processed status files
ls /var/bigbluebutton/recording/status/processed/ | grep ai-summary

# List published status files
ls /var/bigbluebutton/recording/status/published/ | grep ai-summary

# Check a specific meeting's published output
ls /var/bigbluebutton/published/ai-summary/<meeting_id>/
```
