# Operations

This document collects the recurring server-side tasks for running and troubleshooting the `ai-summary` recording format after it has been installed.

For initial setup, see [INSTALLATION.md](INSTALLATION.md). For packaging, source deployment, and implementation details, see [DEVELOPMENT.md](DEVELOPMENT.md).


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

## Logs and Status

### Watch logs

```bash
sudo tail -f /var/log/bigbluebutton/post_archive-transcribe-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/ai-summary/process-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/ai-summary/publish-<meeting_id>.log
sudo tail -f /var/log/bigbluebutton/bbb-rap-worker.log
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
| BBB recording pipeline config | `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml` |
| Post-archive script | `/usr/local/bigbluebutton/core/scripts/post_archive/transcribe_audio.rb` |
| Process script | `/usr/local/bigbluebutton/core/scripts/process/ai-summary.rb` |
| Publish script | `/usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb` |
| Published output | `/var/bigbluebutton/published/ai-summary/<meeting_id>/` |
| Raw recording | `/var/bigbluebutton/recording/raw/<meeting_id>/` |

## Notes

- LLM generation runs in production only.
- This integration depends on LiveKit support in BigBlueButton.
- For custom providers and source-level deployment details, use [DEVELOPMENT.md](DEVELOPMENT.md).
