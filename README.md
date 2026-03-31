# bbb-record-ai-summary

`bbb-record-ai-summary` adds an `ai-summary` playback format to [BigBlueButton Recordings](https://docs.bigbluebutton.org/development/recording/). It generates meeting transcripts, optional LLM summaries, action items, and a standalone report that can be published alongside the standard recording outputs.

## Overview

This project supports these LLM providers for summary and action item generation:

- `claude`
- `openai`
- `albert`
- `disabled`

Before starting the installation, decide whether you want LLM generation enabled and have the corresponding API key available. If you do not want AI-generated summaries, set the provider to `disabled`.

## Features

- Speaker-aware transcription from meeting audio tracks
- WebVTT and JSON transcript outputs
- Optional LLM-generated summary and action items
- Shared notes and poll extraction
- Standalone HTML, Markdown, and PDF report generation
- Optional publishing integration with La Suite Numerique Docs

## Requirements

- BigBlueButton with LiveKit enabled
- A BigBlueButton recording pipeline where custom formats can be added
- Optional provider credentials for LLM summarization or cloud transcription

See the [BigBlueButton LiveKit documentation](https://docs.bigbluebutton.org/new-features/#integration-with-livekit) if LiveKit is not already configured.

## Recording Flow

The `ai-summary` format runs as part of the BBB recording pipeline after a meeting ends:

```text
Meeting ends
   |
   v
BBB archive step
   |
   |  BBB stores the raw recording assets, including audio tracks,
   |  metadata, events, notes, and poll data.
   v
Post-archive transcription
   |
   |  `transcribe_audio.rb` processes the recorded audio tracks.
   |  It uses the configured provider script or falls back to local
   |  `whisper.cpp`, then writes `transcription.json`.
   v
Process stage: `process:ai-summary`
   |
   |  The format reads the transcript, shared notes, polls, and
   |  meeting metadata. If an LLM provider is enabled, it generates
   |  `summary.txt` and `action_items.json`.
   v
Publish stage: `publish:ai-summary`
   |
   |  The final playback assets are rendered and published:
   |  HTML, Markdown, PDF, WebVTT, plain transcript, and JSON outputs.
   v
Published recording
   |
   |  Users can open the `ai-summary` playback format alongside the
   |  other BBB recording formats.
```

## Install

Install the Debian package on the BBB server:

```bash
sudo apt install ./bbb-record-ai-summary_x.x.x_all.deb
```

Then:

1. Add `ai-summary` to the BBB recording pipeline.
2. Configure optional LLM or transcription providers if needed.
3. Restart the recording worker.

The installation steps are documented in [INSTALLATION.md](INSTALLATION.md). Day-to-day runbook tasks are documented in [OPERATIONS.md](OPERATIONS.md).

## Generated Files

Each processed recording can produce:

| File | Description |
|---|---|
| `ai-summary.html` | Standalone HTML report |
| `ai-summary.md` | Markdown report |
| `ai-summary.pdf` | PDF report |
| `transcript.txt` | Plain text transcript |
| `transcription.vtt` | Speaker-labeled WebVTT transcript |
| `transcription.json` | Structured transcript output |
| `summary.txt` | LLM summary, when enabled |
| `action_items.json` | Extracted action items, when enabled |

## Documentation

- [INSTALLATION.md](INSTALLATION.md): first-time server setup and enablement
- [OPERATIONS.md](OPERATIONS.md): runtime configuration, reprocessing, logs, status checks, and common paths
- [DEVELOPMENT.md](DEVELOPMENT.md): package build, source deployment, architecture-level operational details, and advanced transcription/provider configuration
- [ARCHITECTURE.md](ARCHITECTURE.md): recording pipeline and component layout
