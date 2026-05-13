# Installation

This guide is for operators who want the shortest path to install and enable the `ai-summary` format on a BBB server.

For day-to-day commands after installation, see [OPERATIONS.md](OPERATIONS.md). For package build details, source deployment internals, and advanced transcription/provider topics, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Production Setup

### 1. Install the package

```bash
sudo apt install ./bbb-record-ai-summary_x.x.x_all.deb
```

### 2. LLM configuration

Edit the server override file:

```bash
sudo vi /etc/bigbluebutton/ai-summary.yml
```

Set the provider:

- OpenAI
```yaml
llm:
  provider: openai
  openai_api_key: "sk-..."
```

- Claude
```yaml
llm:
  provider: claude
  anthropic_api_key: "sk-ant-..."
```

- Albert
```yaml
llm:
  provider: albert
  openai_api_key: "sk-..."
```

- Disable summarization entirely:

```yaml
llm:
  provider: disabled
```

---

- Language (optional)

    If the meeting will be conducted in a specific language, you can explicitly set it instead of relying on automatic detection.
Provide the value using an ISO 639-1 language code:

```yaml
llm:
  language: en
```

### 3. Transcription backend

Edit:

```bash
sudo vi /etc/bigbluebutton/post-archive-transcription.yml
```

Example using a bundled provider:

- OpenAI
```yaml
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/openai_whisper.rb"

openai:
  api_key: "..."
```

- Claude
```yaml
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/claude_whisper.rb"

claude:
  api_key: "..."
```

- Albert
```yaml
transcriber_path: "/usr/local/bigbluebutton/core/lib/transcription/albert_whisper.rb"

albert:
  api_key: "..."
```

- If `transcriber_path` is omitted or set to `"disabled"`, the local `whisper.cpp` fallback is used.

--- 

- Language (optional)

    If the meeting will be conducted in a specific language, you can explicitly set it instead of relying on automatic detection.
Provide the value using an ISO 639-1 language code:

```yaml
language: en
```


### 4. Add the format to the recording pipeline

Edit:

```bash
sudo vi /etc/bigbluebutton/recording/recording.yml
```

Use:

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

### 5. Restart the worker

```bash
sudo systemctl restart bbb-rap-resque-worker
```

## Notes

- LLM generation runs in production only.
- This integration depends on LiveKit support in BigBlueButton.
- For reprocessing, logs, and path references, use [OPERATIONS.md](OPERATIONS.md).
- For custom providers, packaging, or direct source deployment, use [DEVELOPMENT.md](DEVELOPMENT.md).
