# BigBlueButton Record & Playback Architecture

## Overview

BigBlueButton processes recordings through a **6-stage pipeline**:

```
Capture → Archive → Sanity → Process → Publish → Playback
```

Each stage is executed by worker processes that monitor status directories and execute Ruby scripts.

---

## Stage Descriptions

### 1. Capture
- **What happens**: During a live session, components emit events over an event bus while media streams are stored on the server
- **Storage locations**:
  - Events: Redis (whiteboard, cursor, chat, etc.)
  - Audio: `/var/freeswitch/meetings/` (Opus format)
  - Webcam: `/var/lib/bbb-webrtc-recorder/recordings/<meetingid>`
  - Screen sharing: `/var/lib/bbb-webrtc-recorder/screenshare/<meetingid>`
  - Slides: `/var/bigbluebutton/<meetingid>`
  - Shared notes: Stored via Etherpad

### 2. Archive
- **What happens**: Consolidates all captured media and events into a single raw directory
- **Output location**: `/var/bigbluebutton/recording/raw/<meeting_id>/`
- **Structure**:
  ```
  /var/bigbluebutton/recording/raw/<meeting_id>/
  ├── events.xml          # All meeting events with timestamps
  ├── audio/              # Audio files (e.g., .opus)
  ├── video/              # Webcam recordings
  ├── deskshare/          # Screen sharing videos
  ├── presentation/       # Slides and presentation assets
  └── notes/              # Shared notes (notes.etherpad, notes.html, notes.pdf)
  ```

### 3. Sanity
- **What happens**: Validates that archived files are complete and usable
- **Checks**: Media files have content, events were properly captured

### 4. Process
- **What happens**: Format-specific processing scripts parse events and convert media
- **Location**: `/usr/local/bigbluebutton/core/scripts/process/<format>.rb`
- **Output**: `/var/bigbluebutton/recording/process/<format>/<meeting_id>/`
- **Key tasks**:
  - Parse events.xml
  - Extract and transform media
  - Create metadata.xml with meeting information
  - Mark processing complete with `.done` file

### 5. Publish
- **What happens**: Organize processed files into publicly accessible directories
- **Location**: `/usr/local/bigbluebutton/core/scripts/publish/<format>.rb`
- **Output**: `/var/bigbluebutton/published/<format>/<meeting_id>/`
- **Key tasks**:
  - Copy processed files to public directory
  - Update metadata.xml with playback links
  - Mark publishing complete with `.done` file
  - Clean up process directory

### 6. Playback
- **What happens**: Published files are served via nginx and rendered in browsers
- **Access**: `https://<server>/playback/<format>/<meeting_id>/`

---

## Configuration System

### Main Configuration
- **File**: `/usr/local/bigbluebutton/core/scripts/bigbluebutton.yml`
- **Contains**: Directory paths, logging config, playback host/protocol

### Recording Workflow
- **File**: `/etc/bigbluebutton/recording/recording.yml`
- **Purpose**: Defines processing pipeline and dependencies

Example:
```yaml
steps:
  archive: "sanity"
  sanity: "captions"
  captions:
    - 'process:presentation'
    - 'process:notes'
    - 'process:video'
  'process:presentation': 'publish:presentation'
  'process:notes': 'publish:notes'
  'process:video': 'publish:video'
```

### Format-Specific Configuration
- **File**: `/usr/local/bigbluebutton/core/scripts/<format>.yml`
- **Purpose**: Format-specific settings

Example (notes.yml):
```yaml
publish_dir: /var/bigbluebutton/published/notes
format: pdf
```

---

## How the Notes Playback Works

The `bbb-playback-notes` package provides a simple example of the process/publish pattern.

### Package Structure
```
/usr/local/bigbluebutton/core/scripts/
├── notes.yml                    # Configuration
├── process/notes.rb             # Processing script
└── publish/notes.rb             # Publishing script

/usr/share/bigbluebutton/nginx/
└── notes-playback.nginx         # Nginx configuration
```

### Process Stage (process/notes.rb)

**Location**: `/usr/local/bigbluebutton/core/scripts/process/notes.rb`

**Key Operations**:

1. **Load configuration**:
   ```ruby
   props = YAML::load(File.open('../../core/scripts/bigbluebutton.yml'))
   notes_props = YAML::load(File.open('notes.yml'))
   format = notes_props['format']  # "pdf"
   ```

2. **Check for notes file**:
   ```ruby
   note_file = "#{raw_archive_dir}/notes/notes.#{format}"
   # Early exit if no notes exist
   ```

3. **Create initial metadata.xml**:
   ```ruby
   target_dir = "#{recording_dir}/process/notes/#{meeting_id}"
   # Build XML structure with Builder::XmlMarkup
   ```

4. **Copy notes file**:
   ```ruby
   FileUtils.cp(note_file, "#{target_dir}/notes.#{format}")
   ```

5. **Extract timing information from events.xml**:
   ```ruby
   @doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))
   meeting_start = @doc.xpath("//event")[0][:timestamp]
   meeting_end = @doc.xpath("//event").last()[:timestamp]
   ```

6. **Update metadata.xml**:
   - Add start_time and end_time
   - Copy breakout room info from events.xml
   - Extract participant count
   - Add meeting metadata

7. **Mark complete**:
   ```ruby
   process_done = File.new("#{recording_dir}/status/processed/#{meeting_id}-notes.done", "w")
   state.content = "processed"
   ```

**Output**: `/var/bigbluebutton/recording/process/notes/<meeting_id>/`
- `notes.pdf`
- `metadata.xml` (with state="processed")

### Publish Stage (publish/notes.rb)

**Location**: `/usr/local/bigbluebutton/core/scripts/publish/notes.rb`

**Key Operations**:

1. **Parse meeting ID format**:
   ```ruby
   # Input: "<meeting_id>-<playback_format>"
   match = /(.*)-(.*)/.match meeting_id
   meeting_id = match[1]
   playback = match[2]
   ```

2. **Copy processed files**:
   ```ruby
   target_dir = "#{recording_dir}/publish/notes/#{meeting_id}"
   FileUtils.cp(note_file, target_dir)
   FileUtils.cp("#{process_dir}/metadata.xml", target_dir)
   ```

3. **Update metadata.xml with playback info**:
   ```ruby
   xml.playback {
     xml.format("notes")
     xml.link("#{playback_protocol}://#{playback_host}/notes/#{meeting_id}/notes.#{format}")
     xml.duration("#{recording_time}")
   }
   state.content = "published"
   published.content = "true"
   ```

4. **Add file sizes**:
   ```ruby
   BigBlueButton.add_raw_size_to_metadata(target_dir, raw_dir)
   BigBlueButton.add_playback_size_to_metadata(target_dir)
   ```

5. **Copy to public directory**:
   ```ruby
   publish_dir = notes_props['publish_dir']  # /var/bigbluebutton/published/notes
   FileUtils.cp_r(target_dir, publish_dir)
   ```

6. **Cleanup and mark complete**:
   ```ruby
   FileUtils.rm_r(process_dir)  # Remove processed files
   FileUtils.rm_r(target_dir)   # Remove temporary publish files
   publish_done = File.new("#{recording_dir}/status/published/#{meeting_id}-notes.done", "w")
   ```

**Output**: `/var/bigbluebutton/published/notes/<meeting_id>/`
- `notes.pdf`
- `metadata.xml` (with playback link and state="published")

---

## Key Patterns

### Script Structure
All process/publish scripts follow this pattern:

```ruby
# 1. Load dependencies
require File.expand_path('../../../lib/recordandplayback', __FILE__)
require 'optimist'
require 'yaml'

# 2. Parse command-line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", type: String
end

# 3. Load configuration
props = YAML::load(File.open('bigbluebutton.yml'))
format_props = YAML::load(File.open('format.yml'))

# 4. Set up directories and logging
target_dir = "#{recording_dir}/process/format/#{meeting_id}"
logger = Logger.new("#{log_dir}/format/process-#{meeting_id}.log")
BigBlueButton.logger = logger

# 5. Check if already processed (idempotency)
if not FileTest.directory?(target_dir)
  # Do processing
end

# 6. Error handling
rescue Exception => e
  BigBlueButton.logger.error(e.message)
  exit 1
end
```

### Metadata.xml Evolution
- **Process stage**: Creates initial metadata.xml with state="processing"
- **Process completion**: Updates state="processed", adds timing/metadata
- **Publish stage**: Copies and updates with state="published", adds playback links

### Status Files
- `.done` files signal completion: `<meeting_id>-<format>.done`
- `.fail` files signal errors: `<meeting_id>-<format>.fail`
- Location: `/var/bigbluebutton/recording/status/{processed,published}/`

### Events.xml Structure
```xml
<recording meeting_id="..." bbb_version="...">
  <meeting id="..." name="..." />
  <metadata meetingId="..." meetingName="..." />
  <event timestamp="..." module="..." eventname="...">
    <!-- Event-specific data -->
  </event>
  ...
</recording>
```

Key event types:
- `StartRecordingEvent`: Audio recording start with filename
- `ParticipantJoinEvent`: User joins meeting
- `PadCreatedEvent`: Shared notes pad created
- `RecordStatusEvent`: Recording status changes

---

## Worker Architecture

Workers monitor status directories and execute scripts:

```
rap-process-worker.rb  → Monitors /status/sanity/*.done
                        → Executes /scripts/process/<format>.rb
                        → Creates /status/processed/*.done

rap-publish-worker.rb  → Monitors /status/processed/*.done
                        → Executes /scripts/publish/<format>.rb
                        → Creates /status/published/*.done
```

Each worker:
1. Polls status directory for `.done` files
2. Reads recording.yml to determine next step
3. Executes appropriate Ruby script
4. Monitors for completion or failure
